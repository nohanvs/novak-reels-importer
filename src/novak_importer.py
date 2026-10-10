from __future__ import annotations

import http.client
import json
import logging
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen

MAX_VIDEO_BYTES = 95 * 1024 * 1024
VIDEO_SUFFIXES = {".mp4": "video/mp4", ".mov": "video/quicktime"}
TIKTOK_HOST_RE = re.compile(r"(^|\.)tiktok\.com$", re.IGNORECASE)
TWITCH_HOST_RE = re.compile(r"(^|\.)twitch\.tv$", re.IGNORECASE)
SAFE_JOB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
WATERMARK_TEXT = "twitch.tv/facada"
HASHTAG = "#facadarp"

LOGGER = logging.getLogger("novak_importer")


class ImporterError(RuntimeError):
    """Expected failure that can be recorded against a queue item."""


@dataclass(frozen=True)
class Config:
    api_base_url: str
    importer_token: str
    sites_authorization: str | None = None
    max_batches: int = 0
    request_timeout_seconds: int = 45
    download_timeout_seconds: int = 300

    @classmethod
    def from_env(cls) -> "Config":
        base_url = os.environ.get("NOVAK_API_BASE_URL", "").strip().rstrip("/")
        token = os.environ.get("NOVAK_IMPORTER_TOKEN", "").strip()
        sites_auth = os.environ.get("NOVAK_SITES_AUTHORIZATION", "").strip() or None
        if not base_url:
            raise ImporterError("NOVAK_API_BASE_URL is required")
        parsed = urlparse(base_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            raise ImporterError("NOVAK_API_BASE_URL must be an HTTPS origin")
        if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
            raise ImporterError("NOVAK_API_BASE_URL must not include a path, query, or fragment")
        if len(token) < 32:
            raise ImporterError("NOVAK_IMPORTER_TOKEN must contain at least 32 characters")
        return cls(
            api_base_url=base_url,
            importer_token=token,
            sites_authorization=sites_auth,
            max_batches=_bounded_int("NOVAK_MAX_BATCHES", default=0, minimum=0, maximum=0),
            request_timeout_seconds=_bounded_int("NOVAK_REQUEST_TIMEOUT", default=45, minimum=5, maximum=120),
            download_timeout_seconds=_bounded_int("NOVAK_DOWNLOAD_TIMEOUT", default=300, minimum=30, maximum=600),
        )


@dataclass(frozen=True)
class Job:
    id: str
    source_url: str


class ApiClient:
    def __init__(self, config: Config):
        self.config = config

    def claim_jobs(self) -> list[Job]:
        payload = self._json_request("GET", "/api/worker/importer/jobs")
        raw_jobs = payload.get("jobs")
        if not isinstance(raw_jobs, list):
            raise ImporterError("API returned an invalid jobs payload")
        jobs: list[Job] = []
        for raw_job in raw_jobs:
            if not isinstance(raw_job, dict):
                raise ImporterError("API returned an invalid job")
            job_id = raw_job.get("id")
            source_url = raw_job.get("sourceUrl")
            if not isinstance(job_id, str) or not SAFE_JOB_ID_RE.fullmatch(job_id):
                raise ImporterError("API returned an invalid job id")
            if not isinstance(source_url, str):
                raise ImporterError("API returned an invalid source URL")
            validate_source_url(source_url)
            jobs.append(Job(id=job_id, source_url=source_url))
        return jobs

    def upload(self, job_id: str, video_path: Path) -> dict[str, Any]:
        if not SAFE_JOB_ID_RE.fullmatch(job_id):
            raise ImporterError("Invalid job id")
        file_size = video_path.stat().st_size
        if file_size < 1 or file_size > MAX_VIDEO_BYTES:
            raise ImporterError("Processed video must be between 1 byte and 95 MB")
        if video_path.suffix.lower() not in VIDEO_SUFFIXES:
            raise ImporterError("Processed file is not MP4 or MOV")
        if not os.environ.get("BLOB_READ_WRITE_TOKEN", "").strip():
            raise ImporterError("BLOB_READ_WRITE_TOKEN is required to upload the processed video")

        upload_script = Path(os.environ.get("GITHUB_WORKSPACE", str(Path.cwd()))).resolve() / "scripts" / "upload-blob.mjs"
        if not upload_script.exists():
            raise ImporterError("Vercel Blob uploader script is missing")
        try:
            uploaded = subprocess.run(
                ["node", str(upload_script), str(video_path)],
                capture_output=True,
                text=True,
                timeout=240,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ImporterError(f"Blob upload failed: {type(error).__name__}") from error
        if uploaded.returncode != 0:
            raise ImporterError("Processed video could not be uploaded to public storage")

        try:
            upload_result = json.loads(uploaded.stdout.strip())
        except (json.JSONDecodeError, AttributeError) as error:
            raise ImporterError("Blob uploader returned invalid JSON") from error
        video_url = upload_result.get("url") if isinstance(upload_result, dict) else None
        if not isinstance(video_url, str) or not video_url.startswith("https://"):
            raise ImporterError("Blob uploader did not return a public HTTPS URL")

        result = self._json_request(
            "PATCH",
            f"/api/worker/importer/jobs/{job_id}",
            {"status": "processed", "videoUrl": video_url, "caption": HASHTAG},
        )
        if result.get("accepted") is not True:
            raise ImporterError("API did not accept the processed video")
        return result

    def record_failure(self, job_id: str, error: str) -> None:
        if not SAFE_JOB_ID_RE.fullmatch(job_id):
            return
        safe_error = sanitize_error(error)
        try:
            self._json_request(
                "PATCH",
                f"/api/worker/importer/jobs/{job_id}",
                {"error": safe_error, "watermarked": "watermark" in safe_error.lower()},
            )
        except ImporterError as report_error:
            LOGGER.error("Could not report failure for job %s: %s", job_id, sanitize_error(str(report_error)))

    def _headers(self) -> dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self.config.importer_token}",
            "Accept": "application/json",
            "User-Agent": "NovaK-Reels-Importer/0.2",
        }
        if self.config.sites_authorization:
            headers["OAI-Sites-Authorization"] = f"Bearer {self.config.sites_authorization}"
        return headers

    def _json_request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers = self._headers()
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(urljoin(f"{self.config.api_base_url}/", path.lstrip("/")), data=body, headers=headers, method=method)
        try:
            with urlopen(request, timeout=self.config.request_timeout_seconds) as response:
                raw = response.read(1024 * 1024)
        except HTTPError as error:
            raw = error.read(1024 * 1024)
            details = _decode_json(raw).get("error") or f"HTTP {error.code}"
            raise ImporterError(f"API request failed: {details}") from error
        except (URLError, OSError, socket.timeout) as error:
            raise ImporterError(f"API request failed: {type(error).__name__}") from error
        return _decode_json(raw)


class VideoDownloader:
    def __init__(self, timeout_seconds: int):
        self.timeout_seconds = timeout_seconds

    def download(self, source_url: str, destination: Path) -> Path:
        validate_source_url(source_url)
        try:
            from yt_dlp import YoutubeDL
            from yt_dlp.utils import DownloadError
        except ImportError as error:
            raise ImporterError("yt-dlp is not installed") from error

        options = {
            "format": "best[ext=mp4]/best",
            "outtmpl": str(destination / "%(id)s.%(ext)s"),
            "noplaylist": True,
            "playlistend": 1,
            "restrictfilenames": True,
            "max_filesize": MAX_VIDEO_BYTES,
            "socket_timeout": min(self.timeout_seconds, 60),
            "retries": 3,
            "fragment_retries": 3,
            "quiet": True,
            "no_warnings": True,
        }
        try:
            with YoutubeDL(options) as downloader:
                downloader.extract_info(source_url, download=True)
        except DownloadError as error:
            raise ImporterError(f"Download failed: {sanitize_error(str(error))}") from error

        candidates = [path for path in destination.iterdir() if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES]
        if len(candidates) != 1:
            raise ImporterError("Download did not produce exactly one supported video")
        video_path = candidates[0]
        if video_path.stat().st_size < 1 or video_path.stat().st_size > MAX_VIDEO_BYTES:
            raise ImporterError("Downloaded video must be between 1 byte and 95 MB")
        return video_path


class VideoEditor:
    def edit(self, source: Path, destination: Path) -> Path:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise ImporterError("ffmpeg is not installed")
        filter_graph = (
            "drawtext="
            "text='twitch.tv/facada':" 
            "x=(w-text_w)/2:" 
            "y=h-text_h-48:" 
            "fontsize=28:" 
            "fontcolor=white:" 
            "borderw=3:" 
            "bordercolor=black"
        )
        command = [
            ffmpeg, "-y", "-i", str(source),
            "-vf", filter_graph,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-c:a", "aac", "-movflags", "+faststart",
            str(destination),
        ]
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=600, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ImporterError(f"Video editing failed: {type(error).__name__}") from error
        if completed.returncode != 0:
            raise ImporterError("Video editing failed")
        if not destination.exists() or destination.stat().st_size < 1 or destination.stat().st_size > MAX_VIDEO_BYTES:
            raise ImporterError("Edited video must be between 1 byte and 95 MB")
        return destination


class Worker:
    def __init__(self, config: Config, client: ApiClient, downloader: VideoDownloader, editor: VideoEditor | None = None):
        self.config = config
        self.client = client
        self.downloader = downloader
        self.editor = editor or VideoEditor()

    def run(self) -> tuple[int, int]:
        succeeded = 0
        failed = 0
        while True:
            jobs = self.client.claim_jobs()
            if not jobs:
                break
            for job in jobs:
                LOGGER.info("Processing job %s", job.id)
                try:
                    with tempfile.TemporaryDirectory(prefix="novak-import-") as directory:
                        workdir = Path(directory)
                        video_path = self.downloader.download(job.source_url, workdir)
                        edited_path = workdir / "edited.mp4"
                        self.editor.edit(video_path, edited_path)
                        result = self.client.upload(job.id, edited_path)
                        if result.get("accepted") is not True:
                            raise ImporterError("API did not accept the video")
                    succeeded += 1
                    LOGGER.info("Job %s accepted with watermark and %s", job.id, HASHTAG)
                except Exception as error:  # keep one bad item from blocking the remaining queue
                    failed += 1
                    safe_error = sanitize_error(str(error) or type(error).__name__)
                    LOGGER.error("Job %s failed: %s", job.id, safe_error)
                    self.client.record_failure(job.id, safe_error)
        return succeeded, failed


def validate_source_url(value: str) -> None:
    if len(value) > 2048:
        raise ImporterError("Source URL is too long")
    parsed = urlparse(value)
    hostname = (parsed.hostname or "").rstrip(".")
    if parsed.scheme != "https" or parsed.username or parsed.password:
        raise ImporterError("Only HTTPS source URLs without credentials are allowed")
    if TIKTOK_HOST_RE.search(hostname):
        validate_tiktok_url(value)
        return
    if TWITCH_HOST_RE.search(hostname):
        validate_twitch_clip_url(value)
        return
    raise ImporterError("Only HTTPS TikTok and Twitch clip URLs are allowed")


def validate_tiktok_url(value: str) -> None:
    parsed = urlparse(value)
    hostname = (parsed.hostname or "").rstrip(".")
    if parsed.scheme != "https" or not TIKTOK_HOST_RE.search(hostname) or parsed.username or parsed.password:
        raise ImporterError("Only HTTPS TikTok URLs are allowed")
    if not parsed.path or parsed.path == "/":
        raise ImporterError("TikTok URL must point to a video")


def validate_twitch_clip_url(value: str) -> None:
    parsed = urlparse(value)
    hostname = (parsed.hostname or "").rstrip(".")
    if parsed.scheme != "https" or not TWITCH_HOST_RE.search(hostname) or parsed.username or parsed.password:
        raise ImporterError("Only HTTPS Twitch URLs are allowed")
    path = parsed.path.rstrip("/")
    is_short_clip_url = hostname.lower() == "clips.twitch.tv" and path.strip("/") != ""
    is_channel_clip_url = bool(re.search(r"(?:^|/)clip/[^/]+$", path, re.IGNORECASE))
    if not path or not (is_short_clip_url or is_channel_clip_url):
        raise ImporterError("Twitch URL must point to a clip")


def sanitize_error(value: str) -> str:
    compact = " ".join(value.replace("\x00", "").split())
    compact = re.sub(r"(?i)\bauthorization\s*[:=]?\s*bearer\s+[^\s,;]+", "Authorization=[redacted]", compact)
    compact = re.sub(r"(?i)\bbearer\s+[^\s,;]+", "Bearer=[redacted]", compact)
    compact = re.sub(r"(?i)\b(token|cookie)\s*[:=]\s*[^\s,;]+", r"\1=[redacted]", compact)
    return compact[:300] or "import_failed"


def _decode_json(raw: bytes) -> dict[str, Any]:
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ImporterError("API returned invalid JSON") from error
    if not isinstance(decoded, dict):
        raise ImporterError("API returned invalid JSON")
    return decoded


def _bounded_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise ImporterError(f"{name} must be an integer") from error
    if value < minimum or value > maximum:
        raise ImporterError(f"{name} must be between {minimum} and {maximum}")
    return value


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = Config.from_env()
        worker = Worker(config, ApiClient(config), VideoDownloader(config.download_timeout_seconds), VideoEditor())
        succeeded, failed = worker.run()
        LOGGER.info("Finished: %s accepted, %s failed", succeeded, failed)
        return 1 if failed else 0
    except ImporterError as error:
        LOGGER.error("Importer configuration failed: %s", sanitize_error(str(error)))
        return 2


if __name__ == "__main__":
    sys.exit(main())
