#!/usr/bin/env python3
"""Check the store screenshot rig's pure parts: what it cleans, and what it refuses to touch."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "store-shots.py"
spec = importlib.util.spec_from_file_location("store_shots", SCRIPT)
store_shots = importlib.util.module_from_spec(spec)
sys.modules["store_shots"] = store_shots
spec.loader.exec_module(store_shots)


class CleanupTests(unittest.TestCase):
    repos = [Path("/Users/me/workspace/storefront")]

    def test_claude_project_name_matches_claude_code(self) -> None:
        self.assertEqual(store_shots.encode_claude_project(Path("/Users/me/work.space/a_b")),
                         "-Users-me-work-space-a-b")

    def test_claude_trust_keeps_every_other_project(self) -> None:
        config = {"projects": {"/Users/me/workspace/storefront": {}, "/Users/me/workspace/storefront-2": {},
                               "/Users/me/real": {}}, "other": 1}
        self.assertEqual(store_shots.strip_claude_trust(config, self.repos),
                         {"projects": {"/Users/me/workspace/storefront-2": {}, "/Users/me/real": {}}, "other": 1})

    def test_codex_trust_removes_only_the_named_table(self) -> None:
        text = ('model = "x"\n\n[projects."/Users/me/workspace/storefront"]\ntrust_level = "trusted"\n\n'
                '[projects."/Users/me/workspace/storefront-2"]\ntrust_level = "trusted"\n')
        self.assertEqual(store_shots.strip_codex_trust(text, self.repos),
                         'model = "x"\n\n[projects."/Users/me/workspace/storefront-2"]\ntrust_level = "trusted"\n')

    def test_rollout_cwd_tolerates_other_first_lines(self) -> None:
        self.assertEqual(store_shots.rollout_cwd(json.dumps({"payload": {"cwd": "/a"}})), "/a")
        self.assertIsNone(store_shots.rollout_cwd("not json"))
        self.assertIsNone(store_shots.rollout_cwd(json.dumps({"payload": "text"})))


class WorkspaceTests(unittest.TestCase):
    def test_refuses_a_directory_it_did_not_create(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            rig = store_shots.Rig("/tmp/unused", directory)
            with self.assertRaises(SystemExit):
                rig.make_repos()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_builds_every_repository_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "demo"
            rig = store_shots.Rig("/tmp/unused", str(workspace))
            rig.make_repos()
            rig.make_repos()
            for name in store_shots.load_repos():
                self.assertTrue((workspace / name / ".git").is_dir(), name)
            agents = {agent.repo for agent in store_shots.AGENTS}
            self.assertLessEqual(agents, set(store_shots.load_repos()))


class SeedTests(unittest.TestCase):
    def test_hosts_keep_each_session_under_its_screenshot_name(self) -> None:
        host = {"id": "1", "address": "127.0.0.1", "port": 22}
        status = {"hosts": [{**host, "sessionName": ""}, {**host, "id": "2", "sessionName": "build"}]}
        catalog = json.loads(store_shots.seeded_hosts(status))
        self.assertEqual([(h["name"], h["sessionName"]) for h in catalog["hosts"]],
                         [("Studio Mac", ""), ("Build Server", "build")])
        self.assertEqual(catalog["hosts"][1]["routes"][0]["id"], "2")


if __name__ == "__main__":
    unittest.main()
