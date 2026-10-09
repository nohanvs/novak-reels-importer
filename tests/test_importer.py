from __future__ import annotations

import os
import unittest
from pathlib import Path
from unittest.mock import patch

from novak_importer import Config, ImporterError, Job, Worker, sanitize_error, validate_source_url, validate_tiktok_url, validate_twitch_clip_url


class UrlValidationTests(unittest.TestCase):
    def test_accepts_tiktok_video_urls(self) -> None:
        for value in (
            "https://www.tiktok.com/@novak/video/123456789",
            "https://vm.tiktok.com/ABC123/",
            "https://m.tiktok.com/v/123.html",
        ):
            validate_tiktok_url(value)

    def test_accepts_twitch_clip_urls(self) -> None:
        for value in (
            "https://www.twitch.tv/facada/clip/FunnyClip123",
            "https://twitch.tv/somechannel/clip/ABC-def_123",
        ):
            validate_twitch_clip_url(value)
            validate_source_url(value)

    def test_rejects_lookalike_hosts_and_credentials(self) -> None:
        for value in (
            "https://tiktok.com.evil.example/@x/video/1",
            "http://www.tiktok.com/@x/video/1",
            "https://user:pass@www.tiktok.com/@x/video/1",
            "https://www.tiktok.com/",
            "https://www.twitch.tv.evil.example/x/clip/ABC",
            "https://www.twitch.tv/channel/not-a-clip",
        ):
            with self.subTest(value=value), self.assertRaises(ImporterError):
                validate_source_url(value)


class ConfigTests(unittest.TestCase):
    def test_unlimited_batches_are_default(self) -> None:
        env = {
            "NOVAK_API_BASE_URL": "https://novak.example",
            "NOVAK_IMPORTER_TOKEN": "x" * 32,
        }
        with patch.dict(os.environ, env, clear=True):
            config = Config.from_env()
        self.assertEqual(config.api_base_url, "https://novak.example")
        self.assertEqual(config.max_batches, 0)

    def test_rejects_path_in_base_url(self) -> None:
        env = {
            "NOVAK_API_BASE_URL": "https://novak.example/api",
            "NOVAK_IMPORTER_TOKEN": "x" * 32,
        }
        with patch.dict(os.environ, env, clear=True), self.assertRaises(ImporterError):
            Config.from_env()


class FakeClient:
    def __init__(self, batches: list[list[Job]]):
        self.batches = iter(batches)
        self.uploaded: list[str] = []
        self.failures: list[tuple[str, str]] = []

    def claim_jobs(self) -> list[Job]:
        return next(self.batches, [])

    def upload(self, job_id: str, video_path: Path) -> dict[str, object]:
        self.uploaded.append(job_id)
        return {"accepted": True, "reviewRequired": True}

    def record_failure(self, job_id: str, error: str) -> None:
        self.failures.append((job_id, error))


class FakeDownloader:
    def download(self, source_url: str, destination: Path) -> Path:
        if "fail" in source_url:
            raise ImporterError("simulated failure")
        path = destination / "video.mp4"
        path.write_bytes(b"video")
        return path


class FakeEditor:
    def edit(self, source: Path, destination: Path) -> Path:
        destination.write_bytes(source.read_bytes())
        return destination


class WorkerTests(unittest.TestCase):
    def test_processes_remaining_jobs_after_one_failure(self) -> None:
        jobs = [
            Job("one", "https://www.tiktok.com/@x/video/1"),
            Job("two", "https://www.tiktok.com/@x/video/fail"),
            Job("three", "https://www.twitch.tv/x/clip/three"),
        ]
        client = FakeClient([jobs, []])
        config = Config("https://novak.example", "x" * 32)
        result = Worker(config, client, FakeDownloader(), FakeEditor()).run()
        self.assertEqual(result, (2, 1))
        self.assertEqual(client.uploaded, ["one", "three"])
        self.assertEqual(client.failures[0][0], "two")

    def test_stops_when_queue_is_empty(self) -> None:
        client = FakeClient([[]])
        config = Config("https://novak.example", "x" * 32)
        self.assertEqual(Worker(config, client, FakeDownloader(), FakeEditor()).run(), (0, 0))


class SanitizationTests(unittest.TestCase):
    def test_redacts_token_like_values_and_limits_length(self) -> None:
        value = sanitize_error("Authorization Bearer secret-value " + ("a" * 500))
        self.assertNotIn("secret-value", value)
        self.assertLessEqual(len(value), 300)


if __name__ == "__main__":
    unittest.main()
