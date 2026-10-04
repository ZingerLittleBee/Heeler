#!/usr/bin/env python3
"""Exercise the test target membership check against mutated project copies."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-test-target-membership.py")
SPEC = importlib.util.spec_from_file_location("check_test_target_membership", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
membership = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = membership
SPEC.loader.exec_module(membership)

PROJECT = "Heeler.xcodeproj/project.pbxproj"
SCHEME = "Heeler.xcodeproj/xcshareddata/xcschemes/Heeler.xcscheme"


class MembershipTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="heeler-membership-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in (PROJECT, SCHEME):
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text((membership.ROOT / name).read_text())
        tests = membership.ROOT / "Tests" / "HeelerTests"
        for source in tests.rglob("*.swift"):
            copy = self.root / "Tests" / "HeelerTests" / source.relative_to(tests)
            copy.parent.mkdir(parents=True, exist_ok=True)
            copy.touch()

    def edit(self, name: str, old: str, new: str) -> None:
        path = self.root / name
        text = path.read_text()
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new))

    def test_committed_project_compiles_every_test_source(self):
        self.assertEqual(membership.check(self.root),
                         len(list((self.root / "Tests" / "HeelerTests").rglob("*.swift"))))

    def test_a_source_missing_from_the_test_sources_phase_fails_by_name(self):
        project = (self.root / PROJECT).read_text()
        entry = next(line for line in project.splitlines()
                     if "/* WeakNetworkProxy.swift in Sources */," in line)
        self.edit(PROJECT, entry + "\n", "")
        with self.assertRaisesRegex(ValueError, "WeakNetworkProxy.swift is not compiled into HeelerTests"):
            membership.check(self.root)

    def test_a_new_source_without_a_regenerated_project_fails(self):
        (self.root / "Tests/HeelerTests/Support/UnregisteredTests.swift").touch()
        with self.assertRaisesRegex(ValueError, "UnregisteredTests.swift is not compiled.*make generate"):
            membership.check(self.root)

    def test_scheme_cannot_skip_or_narrow_the_test_target(self):
        testable = 'skipped = "NO"\n            parallelizable = "NO">'
        for problem, replacement in [
            ("HeelerTests is skipped", testable.replace('"NO"\n', '"YES"\n', 1)),
            ("HeelerTests runs only selected tests",
             testable.replace(">", '\n            useTestSelectionWhitelist = "YES">')),
            ("HeelerTests skips tests",
             testable + "\n            <SkippedTests>\n               <Test Identifier = \"Suite\">\n"
             "               </Test>\n            </SkippedTests>"),
        ]:
            with self.subTest(problem=problem):
                original = (self.root / SCHEME).read_text()
                try:
                    self.edit(SCHEME, testable, replacement)
                    with self.assertRaisesRegex(ValueError, problem):
                        membership.check(self.root)
                finally:
                    (self.root / SCHEME).write_text(original)


if __name__ == "__main__":
    unittest.main()
