from __future__ import annotations

import json
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

LOGGER = logging.getLogger("luanz7_publisher")
HASHTAG = "#luanz7"


class PublisherError(RuntimeError):
    pass


class RateLimitError(PublisherError):
    pass


@dataclass(frozen=True)
class InstagramAccount:
    user_id: str
    access_token: str


@dataclass(frozen=True)
class Config:
    api_base_url: str
    importer_token: str
    accounts: tuple[InstagramAccount, ...]
    graph_api_version: str = "v23.0"
    timeout: int = 45
    poll_seconds: int = 2
    max_poll_seconds: int = 300
    publish_interval_seconds: int = 120

    @classmethod
    def from_env(cls) -> "Config":
        base_url = os.environ.get("NOVAK_API_BASE_URL", "").strip().rstrip("/")
        token = os.environ.get("NOVAK_IMPORTER_TOKEN", "").strip()
        if not base_url or not token:
            raise PublisherError("NOVAK_API_BASE_URL and NOVAK_IMPORTER_TOKEN are required")
        accounts = _accounts_from_env()
        if not accounts:
            raise PublisherError("No Instagram account is configured")
        return cls(
            api_base_url=base_url,
            importer_token=token,
            accounts=tuple(accounts),
            graph_api_version=os.environ.get("META_GRAPH_API_VERSION", "v23.0").strip(),
            timeout=_bounded_int("NOVAK_PUBLISH_TIMEOUT", 45, 10, 120),
            poll_seconds=_bounded_int("NOVAK_PUBLISH_POLL_SECONDS", 2, 1, 30),
            max_poll_seconds=_bounded_int("NOVAK_PUBLISH_MAX_POLL_SECONDS", 300, 30, 900),
            publish_interval_seconds=_bounded_int("NOVAK_PUBLISH_INTERVAL_SECONDS", 120, 30, 1800),
        )


class HttpJson:
    def __init__(self, timeout: int):
        self.timeout = timeout

    def request(self, method: str, url: str, fields: dict[str, str] | None = None, headers: dict[str, str] | None = None) -> dict:
        body = None
        request_headers = {"Accept": "application/json", "User-Agent": "Luanz7-Reels-Publisher/1.0"}
        if headers:
            request_headers.update(headers)
        if fields is not None:
            body = urlencode(fields).encode("utf-8")
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
        try:
            with urlopen(Request(url, data=body, headers=request_headers, method=method), timeout=self.timeout) as response:
                raw = response.read(2 * 1024 * 1024)
        except HTTPError as error:
            detail = _api_error(error.read(2 * 1024 * 1024), error.code)
            if "request limit" in detail.lower() or "rate limit" in detail.lower():
                raise RateLimitError(detail) from error
            raise PublisherError(detail) from error
        except (URLError, OSError) as error:
            raise PublisherError(f"HTTP request failed: {type(error).__name__}") from error
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PublisherError("API returned invalid JSON") from error
        if not isinstance(payload, dict):
            raise PublisherError("API returned invalid JSON")
        return payload


class NovakQueue:
    def __init__(self, config: Config, http: HttpJson):
        self.config, self.http = config, http

    def jobs(self) -> list[dict]:
        payload = self.http.request("GET", f"{self.config.api_base_url}/api/worker/publisher/jobs", headers=self._headers())
        jobs = payload.get("jobs", [])
        if not isinstance(jobs, list):
            raise PublisherError("Publisher API returned an invalid jobs list")
        return [job for job in jobs if isinstance(job, dict)]

    def complete(self, job_id: str, media_ids: dict[str, str]) -> None:
        self._update(job_id, {"status": "published", "mediaIds": media_ids, "publishedAccounts": list(media_ids)})

    def fail(self, job_id: str, error: str, published_accounts: list[str]) -> None:
        self._update(job_id, {"status": "failed", "error": _safe_error(error), "publishedAccounts": published_accounts})

    def rate_limited(self, job_id: str, error: str, published_accounts: list[str]) -> None:
        self._update(job_id, {"status": "rate_limited", "error": _safe_error(error), "publishedAccounts": published_accounts})

    def _update(self, job_id: str, body: dict) -> None:
        self.http.request("PATCH", f"{self.config.api_base_url}/api/worker/publisher/jobs/{job_id}", body, self._headers())

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.config.importer_token}"}


class InstagramPublisher:
    def __init__(self, config: Config, http: HttpJson, account: InstagramAccount):
        self.config, self.http, self.account = config, http, account
        host = "graph.instagram.com" if account.access_token.startswith("IGAA") else "graph.facebook.com"
        self.base = f"https://{host}/{config.graph_api_version}"
        self.effective_user_id: str | None = None

    def _url(self, path: str) -> str:
        return f"{self.base}/{path.lstrip('/')}"

    def _user_id(self) -> str:
        if self.effective_user_id:
            return self.effective_user_id
        if self.account.access_token.startswith("IGAA"):
            profile = self.http.request("GET", self._url("me") + "?" + urlencode({"fields": "id", "access_token": self.account.access_token}))
            self.effective_user_id = profile.get("id") if isinstance(profile.get("id"), str) else None
        else:
            self.effective_user_id = self.account.user_id
        if not self.effective_user_id:
            raise PublisherError("Instagram token did not return an account id")
        return self.effective_user_id

    def publish_reel(self, video_url: str, caption: str) -> str:
        if not video_url.startswith("https://"):
            raise PublisherError("Published media URL must use HTTPS")
        if HASHTAG not in caption.lower():
            caption = f"{caption.rstrip()}\n\n{HASHTAG}"
        user_id = self._user_id()
        container = self.http.request("POST", self._url(f"{user_id}/media"), {"media_type": "REELS", "video_url": video_url, "caption": caption, "access_token": self.account.access_token})
        container_id = container.get("id")
        if not isinstance(container_id, str) or not container_id:
            raise PublisherError("Instagram did not return a media container id")
        deadline = time.monotonic() + self.config.max_poll_seconds
        while time.monotonic() < deadline:
            status = self.http.request("GET", self._url(container_id) + "?" + urlencode({"fields": "status_code,status", "access_token": self.account.access_token}))
            code = str(status.get("status_code", "")).upper()
            if code == "FINISHED":
                break
            if code in {"ERROR", "EXPIRED"}:
                raise PublisherError(f"Instagram media container status: {code}")
            time.sleep(self.config.poll_seconds)
        else:
            raise PublisherError("Instagram media container timed out")
        published = self.http.request("POST", self._url(f"{user_id}/media_publish"), {"creation_id": container_id, "access_token": self.account.access_token})
        media_id = published.get("id")
        if not isinstance(media_id, str) or not media_id:
            raise PublisherError("Instagram did not return a published media id")
        return media_id


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config, http = Config.from_env(), None
        http = HttpJson(config.timeout)
        queue = NovakQueue(config, http)
        published = failed = 0
        while True:
            jobs = queue.jobs()
            if not jobs:
                break
            for job in jobs:
                job_id, video_url = job.get("id"), job.get("videoUrl")
                caption = str(job.get("caption") or HASHTAG)
                done = {value for value in job.get("publishedAccounts", []) if isinstance(value, str)}
                if not isinstance(job_id, str) or not isinstance(video_url, str):
                    failed += 1
                    continue
                remaining = [account for account in config.accounts if account.user_id not in done]
                if not remaining:
                    queue.complete(job_id, {account.user_id: "already-published" for account in config.accounts})
                    continue
                media_ids: dict[str, str] = {}
                try:
                    with ThreadPoolExecutor(max_workers=len(remaining)) as executor:
                        futures = {executor.submit(InstagramPublisher(config, http, account).publish_reel, video_url, caption): account for account in remaining}
                        for future in as_completed(futures):
                            account = futures[future]
                            media_ids[account.user_id] = future.result()
                    queue.complete(job_id, media_ids)
                    published += 1
                    LOGGER.info("Published job %s to %s account(s)", job_id, len(media_ids))
                    time.sleep(config.publish_interval_seconds)
                except RateLimitError as error:
                    queue.rate_limited(job_id, str(error), list(done | set(media_ids)))
                    LOGGER.error("Publish rate-limited for job %s: %s", job_id, _safe_error(str(error)))
                    return 4
                except Exception as error:
                    queue.fail(job_id, str(error), list(done | set(media_ids)))
                    failed += 1
                    LOGGER.error("Publish failed for job %s: %s", job_id, _safe_error(str(error)))
        LOGGER.info("Publishing finished: %s published, %s failed", published, failed)
        return 1 if failed and not published else 0
    except Exception as error:
        LOGGER.error("Publisher stopped: %s", _safe_error(str(error)))
        return 1


def _accounts_from_env() -> list[InstagramAccount]:
    raw, accounts = os.environ.get("INSTAGRAM_ACCOUNTS_JSON", "").strip(), []
    if raw:
        try:
            values = json.loads(raw)
        except json.JSONDecodeError as error:
            raise PublisherError("INSTAGRAM_ACCOUNTS_JSON must be valid JSON") from error
        if not isinstance(values, list):
            raise PublisherError("INSTAGRAM_ACCOUNTS_JSON must be a list")
        for value in values[:2]:
            if isinstance(value, dict):
                user_id, token = str(value.get("userId", "")).strip(), str(value.get("accessToken", "")).strip()
                if user_id and token:
                    accounts.append(InstagramAccount(user_id, token))
    if not accounts:
        user_id, token = os.environ.get("INSTAGRAM_USER_ID", "").strip(), os.environ.get("INSTAGRAM_ACCESS_TOKEN", "").strip()
        if user_id and token:
            accounts.append(InstagramAccount(user_id, token))
    return accounts


def _api_error(raw: bytes, fallback: int) -> str:
    try:
        payload = json.loads(raw.decode("utf-8"))
        error = payload.get("error") if isinstance(payload, dict) else None
        return _safe_error(str(error.get("message") if isinstance(error, dict) else error or f"HTTP {fallback}"))
    except Exception:
        return f"HTTP {fallback}"


def _safe_error(value: str) -> str:
    return " ".join(value.replace("\x00", "").split())[:300] or "publish_failed"


def _bounded_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as error:
        raise PublisherError(f"{name} must be an integer") from error
    if not minimum <= value <= maximum:
        raise PublisherError(f"{name} must be between {minimum} and {maximum}")
    return value


if __name__ == "__main__":
    raise SystemExit(main())
