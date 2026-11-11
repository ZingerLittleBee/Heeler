#!/usr/bin/env python3
"""Exercise the String Catalog check and sync against small catalogs."""

from __future__ import annotations

import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-localizations.py")
SPEC = importlib.util.spec_from_file_location("check_localizations", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
localizations = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = localizations
SPEC.loader.exec_module(localizations)


def translated(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


PROMPT = "NSCameraUsageDescription"


class CatalogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="heeler-catalogs-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / localizations.RESOURCES).mkdir(parents=True)
        self.write(localizations.INFO_PLIST, {PROMPT: {
            "extractionState": "extracted_with_value",
            "localizations": {"en": {"stringUnit": {"state": "new", "value": "Heeler scans codes."}},
                              "ja": translated("コードを読み取ります。"),
                              "fr": translated("Heeler lit les codes.")}}})

    def write(self, name: Path, strings: dict, newline: bool = True) -> None:
        catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.1"}
        (self.root / name).write_text(localizations.dump(catalog, newline), encoding="utf-8")

    def read(self, name: Path = localizations.LOCALIZABLE) -> dict:
        return json.loads((self.root / name).read_text(encoding="utf-8"))["strings"]

    def check(self, list_language: str | None = None) -> tuple[int, str]:
        out = io.StringIO()
        failures = localizations.check(self.root, list_language=list_language, out=out)
        return failures, out.getvalue()

    def test_committed_catalogs_pass(self):
        self.assertEqual(localizations.check(localizations.ROOT, out=io.StringIO()), 0)

    def test_committed_catalogs_round_trip_byte_for_byte(self):
        for name in (localizations.LOCALIZABLE, localizations.INFO_PLIST):
            path = localizations.ROOT / name
            self.assertEqual(localizations.dump(*localizations.load(path)), path.read_text(encoding="utf-8"))

    def test_an_untranslated_key_is_reported_without_failing(self):
        self.write(localizations.LOCALIZABLE, {
            "Hosts": {"localizations": {"ja": translated("ホスト")}},
            "New text": {},
            "%@": {"shouldTranslate": False},
        })
        failures, out = self.check(list_language="ja")
        self.assertEqual(failures, 0, out)
        self.assertIn("2 keys to translate", out)
        self.assertIn("ja       1 translated, 1 in English until translated", out)
        self.assertIn("'New text'", out)

    def test_a_key_needing_review_counts_as_untranslated(self):
        self.write(localizations.LOCALIZABLE, {
            "Hosts": {"localizations": {"ja": {"stringUnit": {"state": "needs_review", "value": "ホスト"}}}}})
        self.assertIn("ja       0 translated, 1 in English", self.check()[1])

    def test_changed_specifiers_fail(self):
        self.write(localizations.LOCALIZABLE, {
            "%lld files on %@": {"localizations": {"ja": translated("%@ のファイル")}}})
        failures, out = self.check()
        self.assertEqual(failures, 1, out)
        self.assertIn("error: Localizable.xcstrings ja: '%lld files on %@'", out)

    def test_positional_specifiers_may_reorder(self):
        self.write(localizations.LOCALIZABLE, {
            "%lld files on %@": {"localizations": {"ja": translated("%2$@ の %1$lld 個のファイル")}},
            "%lld%%": {"localizations": {"ja": translated("%lld%%")}}})
        self.assertEqual(self.check()[0], 0)

    def test_a_default_value_is_the_source_for_specifiers(self):
        self.write(localizations.LOCALIZABLE, {"Host note": {
            "extractionState": "extracted_with_value",
            "localizations": {"en": {"stringUnit": {"state": "new", "value": "%@: %@"}},
                              "ja": translated("%1$@：%2$@"), "fr": translated("%@")}}})
        failures, out = self.check()
        self.assertEqual(failures, 1, out)
        self.assertIn("Localizable.xcstrings fr: 'Host note'", out)

    def test_a_plural_case_may_name_its_count_in_words(self):
        self.write(localizations.LOCALIZABLE, {"Searched the web %lld times": {"localizations": {
            "en": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "Searched the web once"}},
                "other": {"stringUnit": {"state": "translated", "value": "Searched the web %lld times"}}}}},
            "ja": {"variations": {"plural": {
                "other": {"stringUnit": {"state": "translated", "value": "Web を %@ 回検索"}}}}},
            "fr": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "Une recherche"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld recherches"}}}}}}}})
        failures, out = self.check()
        self.assertEqual(failures, 1, out)
        self.assertIn("ja/plural.other", out)
        self.assertIn("fr       1 translated", out)

    def test_every_language_translates_the_permission_prompts(self):
        self.write(localizations.LOCALIZABLE, {"Hosts": {"localizations": {
            "ja": translated("ホスト"), "zh-Hans": translated("主机")}}})
        failures, out = self.check()
        self.assertEqual(failures, 1, out)
        self.assertIn(f"InfoPlist.xcstrings zh-Hans: {PROMPT} is not translated", out)


class SyncTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="heeler-sync-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / localizations.RESOURCES).mkdir(parents=True)
        self.derived = self.root / "DerivedData"
        self.sources = self.root / "Code"
        self.sources.mkdir()
        self.commands: list[list[str]] = []

    def catalog(self, strings: dict, newline: bool = False) -> None:
        catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.1"}
        (self.root / localizations.LOCALIZABLE).write_text(localizations.dump(catalog, newline), encoding="utf-8")

    def build(self, target: str, source: str, items: list[dict], exists: bool = True) -> Path:
        path = self.sources / source
        if exists:
            path.write_text("")
        objects = (self.derived / "Build" / "Intermediates.noindex" / "Heeler.build"
                   / "Debug-iphonesimulator" / f"{target}.build" / "Objects-normal" / "arm64")
        objects.mkdir(parents=True, exist_ok=True)
        data = {"source": str(path), "tables": {"Localizable": items}, "version": 1}
        stringsdata = objects / f"{Path(source).stem}.stringsdata"
        stringsdata.write_text(json.dumps(data))
        return stringsdata

    def fake_xcstringstool(self, strings: dict, returncode: int = 0):
        """Records the command and writes `strings` as Xcode formats a catalog."""
        def run(command, **_):
            self.commands.append(command)
            text = json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.1"},
                              indent=2, separators=(",", " : "), sort_keys=True, ensure_ascii=False)
            Path(command[3]).write_text(text.replace("{}", "{\n\n    }"))
            return subprocess.CompletedProcess(command, returncode, "", "it broke" if returncode else "")
        return run

    def sync(self, run=None) -> tuple[int, str, str]:
        out = io.StringIO()
        status = localizations.sync(self.derived, root=self.root, out=out, **({"run": run} if run else {}))
        return status, out.getvalue(), (self.root / localizations.LOCALIZABLE).read_text()

    def test_sync_passes_the_catalog_targets_strings_whose_source_remains(self):
        self.catalog({"Kept": {}})
        app = self.build("Heeler", "A.swift", [{"key": "Kept", "comment": ""}])
        widget = self.build("HeelerWidgets", "Widget.swift", [])
        self.build("Heeler", "Deleted.swift", [], exists=False)
        self.build("HeelerTests", "Test.swift", [])
        self.sync(self.fake_xcstringstool({"Kept": {}}))
        self.assertEqual(self.commands, [[
            "xcrun", "xcstringstool", "sync", str(self.root / localizations.LOCALIZABLE),
            "--stringsdata", str(app), "--stringsdata", str(widget)]])

    def test_sync_reports_the_change_and_keeps_the_repository_format(self):
        for newline in (False, True):
            self.catalog({"Kept": {}, "Gone": {"localizations": {"ja": translated("削除")}}}, newline=newline)
            self.build("Heeler", "A.swift", [])
            status, out, text = self.sync(self.fake_xcstringstool({
                "Kept": {}, "New %@": {"comment": "A new string"},
                "Gone": {"extractionState": "stale", "localizations": {"ja": translated("削除")}}}))
            self.assertEqual(status, 0)
            self.assertIn("1 added\n  'New %@'", out)
            self.assertIn("1 stale (delete them once no code needs them)\n  'Gone'", out)
            self.assertIn('"Kept" : {}', text)
            self.assertEqual(text.endswith("\n"), newline)

    def test_a_failed_sync_leaves_the_catalog_as_it_was(self):
        self.catalog({"Kept": {}}, newline=True)
        before = (self.root / localizations.LOCALIZABLE).read_text()
        self.build("Heeler", "A.swift", [])
        status, out, text = self.sync(self.fake_xcstringstool({}, returncode=1))
        self.assertEqual(status, 1)
        self.assertIn("xcstringstool sync failed: it broke", out)
        self.assertEqual(text, before)

    def test_sync_without_a_build_changes_nothing(self):
        self.catalog({"Kept": {}})
        before = (self.root / localizations.LOCALIZABLE).read_text()
        status, out, text = self.sync(self.fake_xcstringstool({}))
        self.assertEqual(status, 1)
        self.assertIn("build the app first", out)
        self.assertEqual(self.commands, [])
        self.assertEqual(text, before)

    @unittest.skipUnless(shutil.which("xcrun"), "xcstringstool ships with Xcode")
    def test_xcstringstool_adds_and_retires_keys(self):
        self.catalog({"Gone": {"localizations": {"ja": translated("削除")}}, "Kept": {}}, newline=True)
        self.build("Heeler", "A.swift", [
            {"key": "Kept", "comment": "", "location": {"startingLine": 1, "startingColumn": 1}},
            {"key": "Tab key", "comment": "VoiceOver label", "value": "Tab",
             "location": {"startingLine": 2, "startingColumn": 1}}])
        status, out, text = self.sync()
        self.assertEqual(status, 0, out)
        strings = json.loads(text)["strings"]
        self.assertEqual(strings["Gone"]["extractionState"], "stale")
        self.assertEqual(strings["Tab key"]["localizations"]["en"]["stringUnit"]["value"], "Tab")
        self.assertTrue(text.endswith("\n"))


if __name__ == "__main__":
    unittest.main()
