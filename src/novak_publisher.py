from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

LOGGER = logging.getLogger("novak_publisher")


class PublisherError(RuntimeError):
    pass


@dataclass(frozen=True)
class Config:
    api_base_url: str
    importer_token: str
    instagram_user_id: str
    instagram_access_token: str
    graph_api_version: str = "v23.0"
    timeout: int = 45
    poll_seconds: int = 5
    max_poll_seconds: int = 300

    @classmethod
    def from_env(cls) -> "Config":
        values = {
            "api_base_url": os.environ.get("NOVAK_API_BASE_URL", "").strip().rstrip("/"),
            "importer_token": os.environ.get("NOVAK_IMPORTER_TOKEN", "").strip(),
            "instagram_user_id": os.environ.get("INSTAGRAM_USER_ID", "").strip(),
            "instagram_access_token": os.environ.get("INSTAGRAM_ACCESS_TOKEN", "").strip(),
            "graph_api_version": os.environ.get("META_GRAPH_API_VERSION", "v23.0").strip(),
        }
        missing = [key for key, value in values.items() if not value]
        if missing:
            raise PublisherError("Missing required configuration: " + ", ".join(missing))
        return cls(**values)


class HttpJson:
    def __init__(self, timeout: int):
        self.timeout = timeout

    def request(self, method: str, url: str, fields: dict[str, str] | None = None, headers: dict[str, str] | None = None) -> dict:
        body = None
        request_headers = {"Accept": "application/json", "User-Agent": "NovaK-Reels-Publisher/0.1"}
        if headers:
            request_headers.update(headers)
        if fields is not None:
            body = urlencode(fields).encode("utf-8")
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
        request = Request(url, data=body, headers=request_headers, method=method)
        try:
            with urlopen(request, timeout=self.timeout) as response:
                raw = response.read(2 * 1024 * 1024)
        except HTTPError as error:
            raw = error.read(2 * 1024 * 1024)
            try:
                payload = json.loads(raw.decode("utf-8"))
                detail = payload.get("error", {}).get("message") or payload.get("error") or f"HTTP {error.code}"
            except Exception:
                detail = f"HTTP {error.code}"
            raise PublisherError(str(detail)[:300]) from error
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
        self.config = config
        self.http = http

    def jobs(self) -> list[dict]:
        payload = self.http.request(
            "GET",
            f"{self.config.api_base_url}/api/publisher/jobs",
            headers={"Authorization": f"Bearer {self.config.importer_token}"},
        )
        jobs = payload.get("jobs", [])
        if not isinstance(jobs, list):
            raise PublisherError("Publisher API returned an invalid jobs list")
        return [job for job in jobs if isinstance(job, dict)]

    def complete(self, job_id: str, media_id: str) -> None:
        self.http.request(
            "PATCH",
            f"{self.config.api_base_url}/api/publisher/jobs/{job_id}",
            {"status": "published", "mediaId": media_id},
            {"Authorization": f"Bearer {self.config.importer_token}"},
        )

    def fail(self, job_id: str, error: str) -> None:
        safe = " ".join(error.replace("\x00", "").split())[:300]
        try:
            self.http.request(
                "PATCH",
                f"{self.config.api_base_url}/api/publisher/jobs/{job_id}",
                {"status": "failed", "error": safe},
                {"Authorization": f"Bearer {self.config.importer_token}"},
            )
        except PublisherError as report_error:
            LOGGER.error("Could not report failed publish job %s: %s", job_id, report_error)


class InstagramPublisher:
    def __init__(self, config: Config, http: HttpJson):
        self.config = config
        self.http = http
        self.base = f"https://graph.facebook.com/{config.graph_api_version}"

    def _url(self, path: str) -> str:
        return f"{self.base}/{path.lstrip('/')}"

    def publish_reel(self, video_url: str, caption: str) -> str:
        if not video_url.startswith("https://"):
            raise PublisherError("Published media URL must use HTTPS")
        if "#facadarp" not in caption.lower():
            caption = f"{caption.rstrip()}\n\n#facadarp"
        container = self.http.request(
            "POST",
            self._url(f"{self.config.instagram_user_id}/media"),
            {
                "media_type": "REELS",
                "video_url": video_url,
                "caption": caption,
                "access_token": self.config.instagram_access_token,
            },
        )
        container_id = container.get("id")
        if not isinstance(container_id, str) or not container_id:
            raise PublisherError("Instagram did not return a media container id")

        deadline = time.monotonic() + self.config.max_poll_seconds
        while time.monotonic() < deadline:
            status = self.http.request(
                "GET",
                self._url(container_id) + "?" + urlencode({
                    "fields": "status_code,status",
                    "access_token": self.config.instagram_access_token,
                }),
            )
            code = str(status.get("status_code", "")).upper()
            if code == "FINISHED":
                break
            if code in {"ERROR", "EXPIRED"}:
                raise PublisherError(f"Instagram media container status: {code}")
            time.sleep(self.config.poll_seconds)
        else:
            raise PublisherError("Instagram media container timed out")

        published = self.http.request(
            "POST",
            self._url(f"{self.config.instagram_user_id}/media_publish"),
            {
                "creation_id": container_id,
                "access_token": self.config.instagram_access_token,
            },
        )
        media_id = published.get("id")
        if not isinstance(media_id, str) or not media_id:
            raise PublisherError("Instagram did not return a published media id")
        return media_id


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = Config.from_env()
        http = HttpJson(config.timeout)
        queue = NovakQueue(config, http)
        publisher = InstagramPublisher(config, http)
        published = 0
        failed = 0
        while True:
            jobs = queue.jobs()
            if not jobs:
                break
            for job in jobs:
                job_id = job.get("id")
                video_url = job.get("videoUrl")
                caption = job.get("caption") or "#facadarp"
                if not isinstance(job_id, str) or not isinstance(video_url, str):
                    failed += 1
                    continue
                try:
                    media_id = publisher.publish_reel(video_url, caption)
                    queue.complete(job_id, media_id)
                    published += 1
                    LOGGER.info("Published job %s", job_id)
                except Exception as error:
                    failed += 1
                    LOGGER.error("Publish failed for job %s: %s", job_id, str(error)[:300])
                    queue.fail(job_id, str(error))
        LOGGER.info("Publishing finished: %s published, %s failed", published, failed)
        return 1 if failed and not published else 0
    except Exception as error:
        LOGGER.error("Publisher stopped: %s", str(error)[:300])
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
