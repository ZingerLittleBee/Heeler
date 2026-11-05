#!/usr/bin/env python3
"""Run the Host Helper's manifest generator against scratch plugin trees.

Each test builds a small plugin/ directory, runs
scripts/generate-host-helper-manifest.mjs on it and looks at the files it wrote
and at what --check says. The repository's own tree must also pass --check.
Needs node; uses only Python's standard library.
"""

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "scripts/generate-host-helper-manifest.mjs"


def generate(plugin: Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["node", str(GENERATOR), "--plugin", str(plugin), *arguments],
        capture_output=True,
        text=True,
    )


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.plugin = Path(directory.name) / "plugin"
        self.helper = self.plugin / "helper"
        self.src = self.plugin / "src"
        self.helper.mkdir(parents=True)
        self.src.mkdir()
        self.write("helper/version.json", '{"version": "1.2.3"}\n')
        self.write("helper/main.js", 'import "node:fs";\nexport const main = 1;\n')

    def write(self, path: str, text: str) -> None:
        full = self.plugin / path
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(text)

    def manifest(self) -> dict:
        return json.loads((self.helper / "manifest.json").read_text())

    def test_writes_the_version_and_every_files_hash(self):
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 0, result.stderr)
        main = (self.helper / "main.js").read_bytes()
        self.assertEqual(
            self.manifest(),
            {
                "version": "1.2.3",
                "files": [
                    {"path": "main.js", "sha256": hashlib.sha256(main).hexdigest()},
                    {
                        "path": "version.json",
                        "sha256": hashlib.sha256(b'{"version": "1.2.3"}\n').hexdigest(),
                    },
                ],
            },
        )

    def test_check_passes_on_a_fresh_tree_and_changes_nothing(self):
        generate(self.plugin)
        before = (self.helper / "manifest.json").read_bytes()
        result = generate(self.plugin, "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.helper / "manifest.json").read_bytes(), before)

    def test_check_fails_when_a_file_changed_and_writes_nothing(self):
        generate(self.plugin)
        before = (self.helper / "manifest.json").read_bytes()
        self.write("helper/main.js", "export const main = 2;\n")
        result = generate(self.plugin, "--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("manifest.json is out of date", result.stderr)
        self.assertEqual((self.helper / "manifest.json").read_bytes(), before)

    def test_check_fails_on_a_file_the_manifest_does_not_list(self):
        generate(self.plugin)
        self.write("helper/extra.js", "export const extra = 1;\n")
        self.assertEqual(generate(self.plugin, "--check").returncode, 1)

    def test_check_fails_without_a_manifest(self):
        self.assertEqual(generate(self.plugin, "--check").returncode, 1)

    def test_copies_what_helper_code_reaches_of_the_plugins_source(self):
        self.write("src/delivery/push.js", 'import { seal } from "../seal.js";\nexport { seal };\n')
        self.write("src/seal.js", "export const seal = 1;\n")
        self.write("src/unrelated.js", "export const unrelated = 1;\n")
        self.write("helper/main.js", 'import { seal } from "./shared/delivery/push.js";\nseal;\n')
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.helper / "shared/delivery/push.js").read_bytes(),
            (self.src / "delivery/push.js").read_bytes(),
        )
        self.assertEqual((self.helper / "shared/seal.js").read_text(), "export const seal = 1;\n")
        self.assertFalse((self.helper / "shared/unrelated.js").exists())
        listed = [entry["path"] for entry in self.manifest()["files"]]
        self.assertEqual(
            listed, ["main.js", "shared/delivery/push.js", "shared/seal.js", "version.json"]
        )

    def test_copies_the_data_file_a_shared_module_loads_and_its_license(self):
        self.write(
            "src/usage/pricing.js",
            'const table = new URL("./pricing.json", import.meta.url);\nexport { table };\n',
        )
        self.write("src/usage/pricing.json", "{}\n")
        self.write("src/usage/pricing.LICENSE", "license\n")
        self.write("src/usage/other.json", "{}\n")
        self.write("helper/main.js", 'import { table } from "./shared/usage/pricing.js";\ntable;\n')
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = [entry["path"] for entry in self.manifest()["files"]]
        self.assertEqual(
            listed,
            [
                "main.js",
                "shared/usage/pricing.LICENSE",
                "shared/usage/pricing.js",
                "shared/usage/pricing.json",
                "version.json",
            ],
        )
        self.assertEqual(generate(self.plugin, "--check").returncode, 0)

    def test_refuses_a_data_file_with_no_source(self):
        self.write(
            "src/usage/pricing.js",
            'const table = new URL("./pricing.json", import.meta.url);\nexport { table };\n',
        )
        self.write("helper/main.js", 'import { table } from "./shared/usage/pricing.js";\ntable;\n')
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage/pricing.json has no source", result.stderr)

    def test_a_helper_module_loading_its_own_file_copies_nothing(self):
        self.write(
            "helper/main.js",
            'const version = new URL("./version.json", import.meta.url);\nconst up = new URL("..", import.meta.url);\nversion; up;\n',
        )
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.helper / "shared").exists())

    def test_check_fails_when_a_shared_source_moved_on(self):
        self.write("src/seal.js", "export const seal = 1;\n")
        self.write("helper/main.js", 'import { seal } from "./shared/seal.js";\nseal;\n')
        generate(self.plugin)
        self.write("src/seal.js", "export const seal = 2;\n")
        result = generate(self.plugin, "--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("shared/seal.js differs from plugin/src", result.stderr)

    def test_a_shared_file_nothing_imports_goes(self):
        self.write("src/seal.js", "export const seal = 1;\n")
        self.write("helper/main.js", 'import { seal } from "./shared/seal.js";\nseal;\n')
        generate(self.plugin)
        self.write("helper/main.js", "export const main = 3;\n")
        self.assertIn("no longer imported", generate(self.plugin, "--check").stderr)
        generate(self.plugin)
        self.assertFalse((self.helper / "shared").exists())

    def test_refuses_a_package_import_anywhere_in_the_closure(self):
        self.write("src/seal.js", 'import "qrcode";\nexport const seal = 1;\n')
        self.write("helper/main.js", 'import { seal } from "./shared/seal.js";\nseal;\n')
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 1)
        self.assertIn("imports the package qrcode", result.stderr)
        self.assertFalse((self.helper / "manifest.json").exists())

    def test_refuses_a_herdr_variable_anywhere_in_the_closure(self):
        self.write("src/seal.js", "export const seal = process.env.HERDR_SOCKET_PATH;\n")
        self.write("helper/main.js", 'import { seal } from "./shared/seal.js";\nseal;\n')
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 1)
        self.assertIn("HERDR_", result.stderr)

    def test_refuses_an_import_that_leaves_the_helper(self):
        self.write("src/seal.js", "export const seal = 1;\n")
        self.write("helper/main.js", 'import { seal } from "../src/seal.js";\nseal;\n')
        result = generate(self.plugin)
        self.assertEqual(result.returncode, 1)
        self.assertIn("outside the Helper", result.stderr)

    def test_the_repositorys_own_tree_is_current(self):
        result = subprocess.run(
            ["node", str(GENERATOR), "--check"], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
