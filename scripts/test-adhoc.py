#!/usr/bin/env python3
"""Exercise Ad Hoc packaging with signing/Xcode mocked only at their boundary."""

from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import html
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("adhoc", ROOT / "scripts/adhoc.py")
adhoc = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adhoc
spec.loader.exec_module(adhoc)


def profile(target, devices=None):
    return {
        "TeamIdentifier": [adhoc.signing.TEAM_ID],
        "Entitlements": {
            "application-identifier": f"{adhoc.signing.TEAM_ID}.{target.bundle_id}",
            "get-task-allow": False,
        },
        "ProvisionedDevices": devices if devices is not None else ["DEVICE-A", "DEVICE-B"],
        "ExpirationDate": dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(days=10),
    }


def write_ipa(path: Path, profiles=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        for index, target in enumerate(adhoc.signing.TARGETS):
            prefix = f"Payload/{target.bundle_path}/"
            archive.writestr(prefix + "Info.plist", plistlib.dumps({
                "CFBundleIdentifier": target.bundle_id,
                "CFBundleShortVersionString": "0.1.18", "CFBundleVersion": "42",
            }))
            archive.writestr(prefix + "embedded.mobileprovision", plistlib.dumps(
                profiles[index] if profiles else profile(target)))


class AdHocTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="heeler-adhoc-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.ipa = self.directory / "site/Heeler.ipa"
        self.output = io.StringIO()
        self.enterContext(contextlib.redirect_stdout(self.output))
        # Fixtures contain unsigned XML at this external CMS boundary. A real
        # export uses security cms and codesign, covered by physical acceptance.
        self.enterContext(mock.patch.object(adhoc.signing, "decode_profile", side_effect=plistlib.loads))
        self.verify = self.enterContext(mock.patch.object(adhoc.signing, "verify_ipa"))

    def test_https_directory_validation(self):
        self.assertEqual(adhoc.base_url("https://host.example/nested/build"), "https://host.example/nested/build/")
        self.assertEqual(adhoc.base_url(""), "")
        for invalid in ("http://host/path", "https:///missing", "https://user:pass@host/",
                        "https://host/path?token=value", "https://host/path#fragment",
                        "https://host/a b", "https://host:bad/", "https://host/\\x", "https://host/\nx"):
            with self.subTest(url=invalid), self.assertRaises((adhoc.AdHocError, ValueError)):
                adhoc.base_url(invalid)

    def test_signed_bundle_identity_and_device_intersection(self):
        profiles = [profile(target) for target in adhoc.signing.TARGETS]
        profiles[1]["ProvisionedDevices"] = ["DEVICE-A"]
        write_ipa(self.ipa, profiles)
        package = adhoc.inspect_ipa(self.ipa, "device-a")
        self.assertEqual(package.device_count, 1)
        self.assertEqual(package.sha256, hashlib.sha256(self.ipa.read_bytes()).hexdigest())
        self.verify.assert_called_once_with(self.ipa, "0.1.18", "42")
        with self.assertRaisesRegex(adhoc.AdHocError, "not provisioned"):
            adhoc.inspect_ipa(self.ipa, "device-b")

    def test_missing_profile_rejects_package(self):
        self.ipa.parent.mkdir()
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/Heeler.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}))
        with self.assertRaises(KeyError):
            adhoc.inspect_ipa(self.ipa)

    def test_no_common_device_rejects_package(self):
        write_ipa(self.ipa, [profile(target, [f"DEVICE-{i}"])
                             for i, target in enumerate(adhoc.signing.TARGETS)])
        with self.assertRaisesRegex(adhoc.AdHocError, "no registered device in common"):
            adhoc.inspect_ipa(self.ipa)

    def test_store_enterprise_development_expired_and_wrong_team_profiles_fail(self):
        target = adhoc.signing.TARGETS[0]
        changes = [
            {"ProvisionedDevices": []}, {"ProvisionedDevices": "DEVICE-A"},
            {"ProvisionsAllDevices": True}, {"TeamIdentifier": ["OTHER"]},
            {"ExpirationDate": dt.datetime(2000, 1, 1)}, {"ExpirationDate": "tomorrow"},
            {"Entitlements": {"application-identifier": f"{adhoc.signing.TEAM_ID}.{target.bundle_id}",
                              "get-task-allow": True}},
            {"Entitlements": {"application-identifier": "wrong", "get-task-allow": False}},
        ]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(adhoc.AdHocError):
                adhoc.check_profile(target, {**profile(target), **change})

    def test_unhosted_page_then_configure_and_remove_links_without_changing_ipa(self):
        write_ipa(self.ipa)
        original = self.ipa.read_bytes()
        adhoc.prepare(self.directory, "", "")
        page = self.ipa.with_name("index.html")
        manifest = self.ipa.with_name("manifest.plist")
        self.assertIn("<button disabled>", page.read_text())
        self.assertNotIn("itms-services:", page.read_text())
        self.assertFalse(manifest.exists())
        url = "https://downloads.example/nested/release%20one/"
        adhoc.prepare(self.directory, url, "DEVICE-A")
        document = plistlib.loads(manifest.read_bytes())
        item = document["items"][0]
        self.assertEqual(item["assets"][0]["url"], url + "Heeler.ipa")
        self.assertEqual(item["metadata"]["bundle-version"], "42")
        self.assertEqual(item["metadata"]["bundle-identifier"], "dev.bybee.heeler")
        link = html.unescape(page.read_text().split('href="')[1].split('"')[0])
        self.assertEqual(parse_qs(urlsplit(link).query), {
            "action": ["download-manifest"], "url": [url + "manifest.plist"]})
        summary = json.loads(self.directory.joinpath("package.json").read_text())
        self.assertTrue(summary["requested_device_verified"])
        self.assertNotIn("DEVICE-A", page.read_text() + manifest.read_text() + json.dumps(summary))
        adhoc.prepare(self.directory, "", "")
        self.assertFalse(manifest.exists())
        self.assertEqual(self.ipa.read_bytes(), original)

    def test_signature_failure_leaves_existing_links_intact(self):
        write_ipa(self.ipa)
        adhoc.prepare(self.directory, "https://host.example/old/", "")
        page = self.ipa.with_name("index.html")
        previous = page.read_bytes()
        self.verify.side_effect = adhoc.signing.SigningError("invalid code signature")
        with self.assertRaises(adhoc.signing.SigningError):
            adhoc.prepare(self.directory, "https://host.example/new/", "")
        self.assertEqual(page.read_bytes(), previous)

    def test_html_escapes_metadata(self):
        self.ipa.parent.mkdir()
        package = adhoc.Package('<img src=x onerror="alert(1)">', "1&2", 1, "", "")
        adhoc.write_page(self.ipa.parent, package, "https://example.test/")
        page = self.ipa.with_name("index.html").read_text()
        self.assertNotIn("<img", page)
        self.assertIn("&lt;img", page)
        self.assertIn("1&amp;2", page)

    def mock_build_tools(self, fail="", bad_signature=False):
        self.enterContext(mock.patch.object(adhoc, "ROOT", self.directory))
        self.enterContext(mock.patch.object(adhoc.signing, "check_project"))
        self.signing_run = self.enterContext(mock.patch.object(adhoc.signing, "run", return_value=b""))
        if bad_signature:
            self.verify.side_effect = adhoc.signing.SigningError("invalid code signature")

        def execute(command, **kwargs):
            stage = "export" if "-exportArchive" in command else "archive" if "archive" in command else "generate"
            if stage == fail:
                return subprocess.CompletedProcess(command, 65)
            if stage == "export":
                write_ipa(Path(command[command.index("-exportPath") + 1]) / "Heeler.ipa")
            return subprocess.CompletedProcess(command, 0)

        return self.enterContext(mock.patch.object(adhoc.subprocess, "run", side_effect=execute))

    def test_build_uses_generic_destination_local_export_and_separate_site(self):
        commands = self.mock_build_tools()
        adhoc.build("", "DEVICE-A", False)
        run = next(self.directory.joinpath("build/adhoc").iterdir())
        self.assertEqual({path.name for path in (run / "site").iterdir()}, {"Heeler.ipa", "index.html"})
        options = plistlib.loads((run / "ExportOptions.plist").read_bytes())
        self.assertEqual(options["method"], "release-testing")
        self.assertEqual(options["destination"], "export")
        self.assertFalse(options["manageAppVersionAndBuildNumber"])
        argv = [call.args[0] for call in commands.call_args_list]
        self.assertIn("generic/platform=iOS", argv[1])
        self.assertIn("-allowProvisioningUpdates", argv[1])
        self.assertIn("-allowProvisioningUpdates", argv[2])
        self.assertNotIn("-allowProvisioningDeviceRegistration", sum(argv, []))
        self.assertNotIn("devicectl", sum(argv, []))
        self.assertEqual(self.verify.call_count, 1)
        adhoc.build("", "DEVICE-A", False)
        self.assertEqual(len(list(self.directory.joinpath("build/adhoc").iterdir())), 2)

    def test_failed_export_retains_log_without_site(self):
        self.mock_build_tools(fail="export")
        with self.assertRaisesRegex(adhoc.AdHocError, "export failed"):
            adhoc.build("", "", False)
        run = next(self.directory.joinpath("build/adhoc").iterdir())
        self.assertTrue((run / "export.log").exists())
        self.assertFalse((run / "site").exists())

    def test_invalid_signed_export_is_not_copied_to_site(self):
        self.mock_build_tools(bad_signature=True)
        with self.assertRaises(adhoc.signing.SigningError):
            adhoc.build("", "", False)
        run = next(self.directory.joinpath("build/adhoc").iterdir())
        self.assertFalse((run / "site").exists())

    def test_cloud_signing_is_not_blocked_by_local_identity_inventory(self):
        self.mock_build_tools()
        adhoc.build("", "", False)
        # Only source attribution is read here. Xcode, rather than a local
        # certificate inventory, decides whether signing is available.
        self.assertEqual([call.args[0] for call in self.signing_run.call_args_list], ["sh"])
        run = next(self.directory.joinpath("build/adhoc").iterdir())
        self.assertTrue((run / "site/Heeler.ipa").exists())

    def test_dry_run_does_not_access_signing_or_create_files(self):
        with mock.patch.object(adhoc, "ROOT", self.directory), mock.patch.object(adhoc.signing, "run") as run:
            adhoc.build("", "", True)
            run.assert_not_called()
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_make_dry_run_accepts_environment_values_without_shell_execution(self):
        marker = self.directory / "executed"
        env = {key: value for key, value in os.environ.items()
               if key not in {"MAKEFLAGS", "MFLAGS", "MAKELEVEL", "ADHOC_URL", "ADHOC_UDID", "DRY_RUN"}}
        result = subprocess.run(["make", "adhoc", "DRY_RUN=1",
                                 f"ADHOC_UDID=`touch {marker}`"],
                                cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release-testing", result.stdout)
        self.assertFalse(marker.exists())

    def test_page_requires_explicit_directory(self):
        with mock.patch.dict(os.environ, {"ADHOC_DIR": "", "ADHOC_URL": ""}), mock.patch.object(sys, "argv", ["adhoc.py", "page"]), contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(adhoc.main(), 1)
            self.assertIn("ADHOC_DIR must name", error.getvalue())


if __name__ == "__main__":
    unittest.main()
