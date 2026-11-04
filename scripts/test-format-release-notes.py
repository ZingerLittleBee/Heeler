#!/usr/bin/env python3
"""Release note wrapping regressions; no GitHub writes."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "release_notes", Path(__file__).with_name("format-release-notes.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
format_notes = module.format_notes


class ReleaseNotesTests(unittest.TestCase):
    def test_wrapped_bullets(self):
        source = "### Added\n\n- First line\n  continues here.\n- Plugin\n  0.6.0. (#422)\n"
        expected = "### Added\n\n- First line continues here.\n- Plugin 0.6.0. (#422)\n"
        self.assertEqual(format_notes(source), expected)
        self.assertEqual(format_notes(expected), expected)

    def test_paragraph_boundaries(self):
        source = "- First paragraph.\n\n  Second paragraph.\n\n### Fixed\n"
        self.assertEqual(format_notes(source), source)

    def test_parenthesized_protocol_version(self):
        source = "- Connects (protocol\n  19) again.\n"
        self.assertEqual(format_notes(source), "- Connects (protocol 19) again.\n")

    def test_structural_blocks(self):
        for block in ["  - Nested item", "  1. Ordered item", "  > Quote", "  | Table |", "    code", "  ---"]:
            with self.subTest(block=block):
                source = "- Bullet\n" + block + "\n  continuation\n"
                self.assertEqual(format_notes(source), source)

    def test_fenced_code(self):
        for fence in ["```", "~~~~"]:
            source = fence + "text\n- Literal\n  code\n" + fence + "\n"
            self.assertEqual(format_notes(source), source)

    def test_explicit_breaks(self):
        for ending in ["  ", "\\"]:
            source = "- Intentional" + ending + "\n  break\n"
            self.assertEqual(format_notes(source), source)


if __name__ == "__main__":
    unittest.main()
