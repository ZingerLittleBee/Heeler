#!/usr/bin/env python3
"""Test publishing orchestration with only signing and HTTP boundaries replaced."""

import contextlib
from email.message import Message
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publish", ROOT / "scripts/adhoc-publish.py")
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class Response(io.BytesIO):
    def __init__(self, data, status=200, mime="application/octet-stream"):
        super().__init__(data)
        self.status = status
        self.headers = Message()
        self.headers["Content-Type"] = mime


class HTTP:
    def __init__(self):
        self.files = {}
        self.puts = []

    def open(self, request, timeout):
        if isinstance(request, str):
            data, mime = self.files[request]
            return Response(data, mime=mime)
        assert request.get_method() == "PUT"
        assert request.get_header("Authorization") == "Bearer test-credential"
        self.puts.append(request.full_url)
        self.files[request.full_url] = (request.data, request.get_header("Content-type"))
        return Response(b"", status=201)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.ipa = self.root / "input.ipa"
        self.ipa.write_bytes(b"signed-ipa-fixture")
        self.package = publish.adhoc.Package("1.2.3", "9", 1, "2027-01-01", hashlib.sha256(self.ipa.read_bytes()).hexdigest())
        self.http = HTTP()
        self.enterContext(patch.object(publish.adhoc, "inspect_ipa", return_value=self.package))
        self.enterContext(patch.object(publish, "build_opener", return_value=self.http))
        self.enterContext(patch.dict(os.environ, {"ADHOC_UDID": "phone"}))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def run_publish(self):
        return publish.publish(self.ipa, "https://install.example", "test-credential", self.root / "output")

    def test_complete_package_uses_one_unlisted_url_and_index_is_last(self):
        url = self.run_publish()
        self.assertRegex(url, r"^https://install.example/b/[a-f0-9]{32}/$")
        self.assertEqual(self.http.puts, [url + name for name, _ in publish.FILES])
        self.assertEqual(self.http.addheaders, [("User-Agent", "Heeler-AdHoc/1.0")])
        manifest = plistlib.loads(self.http.files[url + "manifest.plist"][0])
        self.assertEqual(manifest["items"][0]["assets"][0]["url"], url + "Heeler.ipa")
        self.assertNotIn("test-credential", (self.root / "output/deployment.json").read_text())
        self.assertEqual(json.loads((self.root / "output/package.json").read_text())["requested_device_verified"], True)

    def test_retry_reuses_saved_link(self):
        self.assertEqual(self.run_publish(), self.run_publish())

    def test_changed_artifact_cannot_reuse_directory(self):
        self.run_publish()
        other = publish.adhoc.Package("1", "1", 1, "2027", "f" * 64)
        with patch.object(publish.adhoc, "inspect_ipa", return_value=other):
            with self.assertRaisesRegex(publish.adhoc.AdHocError, "different IPA"):
                self.run_publish()

    def test_invalid_signature_never_uploads(self):
        with patch.object(publish.adhoc, "inspect_ipa", side_effect=publish.adhoc.AdHocError("invalid profile")):
            with self.assertRaisesRegex(publish.adhoc.AdHocError, "invalid profile"):
                self.run_publish()
        self.assertEqual(self.http.puts, [])

    def test_remote_corruption_prevents_publishing_the_page(self):
        original = self.http.open
        def corrupt(request, timeout):
            return Response(b"wrong") if isinstance(request, str) else original(request, timeout)
        self.http.open = corrupt
        with self.assertRaisesRegex(publish.adhoc.AdHocError, "Remote bytes differ"):
            self.run_publish()
        self.assertEqual(len(self.http.puts), 1)

    def test_credentials_and_urls_never_appear_in_http_errors(self):
        self.http.open = lambda *args, **kwargs: (_ for _ in ()).throw(HTTPError("https://private-link", 401, "secret", {}, None))
        with self.assertRaises(publish.adhoc.AdHocError) as error:
            self.run_publish()
        self.assertEqual(str(error.exception), "Upload of Heeler.ipa failed (HTTP 401)")

    def test_upload_retries_transient_failures(self):
        original = self.http.open
        attempts = []
        def retry(request, timeout):
            attempts.append(request)
            if len(attempts) == 1:
                raise HTTPError("https://private-link", 503, "temporary", {}, None)
            return original(request, timeout)
        self.http.open = retry
        with patch.object(publish.time, "sleep"):
            self.run_publish()
        self.assertEqual(len(self.http.puts), 3)

    def test_origin_requires_https_without_paths_credentials_or_queries(self):
        for url in ("", "http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com/?key=secret"):
            with self.subTest(url=url), self.assertRaises(publish.adhoc.AdHocError):
                publish.origin(url)

    def test_redirects_are_disabled(self):
        self.assertIsNone(publish.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example"))

    def test_cloud_hook_only_runs_for_successful_opted_in_archives(self):
        executable = self.root / "make"
        marker = self.root / "called"
        executable.write_text('#!/bin/sh\nprintf "%s" "$*" > "$MARKER"\n')
        executable.chmod(0o755)
        environment = {"PATH": str(self.root) + ":" + os.environ["PATH"], "MARKER": str(marker),
                       "CI_PRIMARY_REPOSITORY_PATH": str(self.root), "CI_AD_HOC_SIGNED_APP_PATH": str(self.root)}
        script = str(ROOT / "ci_scripts/ci_post_xcodebuild.sh")
        for action, code, url in (("archive", "0", ""), ("test", "0", "https://host"), ("archive", "65", "https://host")):
            subprocess.run(["sh", script], env={**environment, "CI_XCODEBUILD_ACTION": action, "CI_XCODEBUILD_EXIT_CODE": code, "ADHOC_PUBLISH_URL": url}, check=True)
            self.assertFalse(marker.exists())
        subprocess.run(["sh", script], env={**environment, "CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0", "ADHOC_PUBLISH_URL": "https://host"}, check=True)
        self.assertEqual(marker.read_text(), "adhoc-publish")


if __name__ == "__main__":
    unittest.main()
