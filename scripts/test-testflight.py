#!/usr/bin/env python3
"""Exercise the release CLI with real Git and disposable external boundaries."""

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
import zipfile

from app_store_connect import AppStoreConnect, AppleBuild, Inventory


SCRIPTS = Path(__file__).resolve().parent


class TestFlightCommands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.remote = self.root / "remote.git"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.external = self.root / "external.json"
        self.external.write_text(json.dumps({"releases": {}, "runs": []}))
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        EXTERNAL_STATE=str(self.external), YES="1")
        for key in ("VERSION", "BUILD", "TAG", "DRY_RUN", "GITHUB_OUTPUT"):
            self.env.pop(key, None)
        self.command("git", "init", "--bare", "--quiet", str(self.remote))
        self.command("git", "init", "--quiet", "-b", "main")
        self.command("git", "config", "user.name", "Release test")
        self.command("git", "config", "user.email", "test@invalid")
        self.command("git", "config", "commit.gpgsign", "false")
        self.command("git", "config", "tag.gpgsign", "false")
        (self.repo / ".gitignore").write_text("__pycache__/\n")
        (self.repo / "scripts").mkdir()
        for name in ("testflight.py", "app_store_connect.py", "format-release-notes.py", "check-plugin-published.sh"):
            if (SCRIPTS / name).exists():
                shutil.copy(SCRIPTS / name, self.repo / "scripts" / name)
        (self.repo / "plugin").mkdir()
        (self.repo / "plugin/herdr-plugin.toml").write_text('version = "1.4.0"\n')
        (self.repo / "Heeler.xcodeproj").mkdir()
        (self.repo / "project.yml").write_text(
            'targets:\n' + ''.join(f'  {name}:\n    MARKETING_VERSION: "0.1.16"\n'
                                  '    CURRENT_PROJECT_VERSION: "37"\n'
                                  for name in ("Heeler", "Notification", "Widgets")))
        (self.repo / "Heeler.xcodeproj/project.pbxproj").write_text(
            'MARKETING_VERSION = 0.1.16;\nCURRENT_PROJECT_VERSION = 37;\n' * 6)
        (self.repo / "CHANGELOG.md").write_text(
            '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Repair SSH. (#7)\n\n'
            '## [0.1.16] - 2026-10-01\n\n### Added\n\n- Old feature. (#1)\n')
        self.executable("gh", '''#!/usr/bin/env python3
import base64, hashlib, json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
state = json.loads(Path(os.environ['EXTERNAL_STATE']).read_text())
args = sys.argv[1:]
if args[:2] == ['auth', 'status']: sys.exit(0)
if args[:2] == ['repo', 'view']: print('owner/heeler'); sys.exit(0)
if args[:2] == ['release', 'upload']:
    if state.get('fail_asset'): raise SystemExit('asset storage unavailable')
    file = Path(args[3])
    assets = state['releases'][args[2]].setdefault('assets', [])
    if any(asset['name'] == file.name for asset in assets): raise SystemExit('asset already exists')
    data = file.read_bytes()
    if file.name == 'build-manifest.json': state['manifest'] = json.loads(data)
    assets.append({'id': 17 + len(assets), 'name': file.name, 'state': 'uploaded',
                   'size': len(data), 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})
    state.setdefault('files', {})[file.name] = base64.b64encode(data).decode()
    Path(os.environ['EXTERNAL_STATE']).write_text(json.dumps(state))
    sys.exit(1 if state.get('lose_asset_response') else 0)
path = args[-1]
if '/releases/assets/' in path:
    asset = next(asset for release in state['releases'].values() for asset in release['assets']
                 if str(asset['id']) == path.rsplit('/', 1)[1])
    if asset['name'] == 'build-manifest.json': print(json.dumps(state['manifest']))
    else: sys.stdout.buffer.write(base64.b64decode(state['files'][asset['name']]))
    sys.exit(0)
if '/releases?' in path:
    print(json.dumps(list(state['releases'].values()))); sys.exit(0)
if '/actions/runs/' in path and '/jobs?' in path:
    jobs = state.get('jobs', {}).get(path.split('/actions/runs/', 1)[1].split('/', 1)[0], [])
    print(json.dumps({'total_count': len(jobs), 'jobs': jobs})); sys.exit(0)
if '/actions/runs/' in path:
    print(json.dumps(next(run for run in state['runs'] if str(run['id']) == path.rsplit('/', 1)[1]))); sys.exit(0)
if '/actions/workflows/release.yml/runs' in path:
    query = {key: values[0] for key, values in parse_qs(urlsplit(path).query).items() if key in ('event', 'head_sha')}
    runs = [run for run in state['runs'] if all(str(run.get(key)) == value for key, value in query.items())]
    print(json.dumps({'total_count': len(runs), 'workflow_runs': runs})); sys.exit(0)
if '/releases' in path:
    payload = json.load(sys.stdin)
    payload['id'] = 1
    payload['assets'] = state['releases'].get(payload['tag_name'], {}).get('assets', [])
    state['releases'][payload['tag_name']] = payload
    Path(os.environ['EXTERNAL_STATE']).write_text(json.dumps(state))
    print(json.dumps(payload)); sys.exit(0)
raise SystemExit('unexpected gh call: ' + repr(args))
''')
        self.executable("xcodegen", '''#!/usr/bin/env python3
from pathlib import Path
import re
text = Path('project.yml').read_text()
version = re.search(r'MARKETING_VERSION: "([^"]+)"', text)[1]
build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', text)[1]
Path('Heeler.xcodeproj/project.pbxproj').write_text(
    f'MARKETING_VERSION = {version};\\nCURRENT_PROJECT_VERSION = {build};\\n' * 6)
''')
        self.command("git", "add", ".")
        self.command("git", "commit", "--quiet", "-m", "initial")
        self.command("git", "remote", "add", "origin", str(self.remote))
        self.command("git", "push", "--quiet", "origin", "main")
        tree = self.command("git", "rev-parse", "HEAD:plugin").stdout.strip()
        commit = self.command("git", "commit-tree", tree, "-m", "plugin").stdout.strip()
        self.command("git", "push", "--quiet", "origin", f"{commit}:refs/heads/plugin")

    def command(self, *args, check=True, **env):
        result = subprocess.run(args, cwd=self.repo, env=dict(self.env, **env),
                                text=True, capture_output=True)
        if check and result.returncode:
            self.fail(result.stdout + result.stderr)
        return result

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def cli(self, *args, check=True, **env):
        return self.command(sys.executable, "scripts/testflight.py", *args, check=check, **env)

    def ci(self, command, inventory, **env):
        spec = importlib.util.spec_from_file_location("testflight", self.repo / "scripts/testflight.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        tag = env.get("GITHUB_REF_NAME", "builds/0.2.0/38")
        source = self.command("git", "rev-parse", tag + "^{commit}").stdout.strip()
        environ = dict(self.env, GITHUB_EVENT_NAME="push", GITHUB_REF_NAME="builds/0.2.0/38",
                       GITHUB_SHA=source, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1")
        environ.update(env)
        stdout, stderr = io.StringIO(), io.StringIO()
        cwd = Path.cwd()
        try:
            with patch.dict(os.environ, environ, clear=True), patch.object(sys, "argv", ["testflight", command]), \
                 patch.object(module, "AppStoreConnect") as apple, \
                 contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                apple.return_value.inventory.return_value = inventory
                code = module.main()
        finally:
            os.chdir(cwd)
        return code, stdout.getvalue() + stderr.getvalue()

    def record(self):
        release = json.loads(self.external.read_text())["releases"]["builds/0.2.0/38"]
        return release, json.loads(release["body"].split("```json\n", 1)[1].split("\n```", 1)[0])

    def signed_fixture(self, uuid_offset=0):
        archive = self.root / "Heeler.xcarchive"
        ipa = self.root / "Heeler.ipa"
        self.env["ARCHIVE"] = str(archive)
        self.env["IPA"] = str(ipa)
        # An archive contains signing material too; only dSYM bundles may escape.
        archive.mkdir(exist_ok=True)
        (archive / "signing.p12").write_bytes(b"not for publication")
        with zipfile.ZipFile(ipa, "w") as package:
            for index, name in enumerate(("Heeler", "NotificationService", "HeelerWidgets"), 1):
                bundle = "Payload/Heeler.app" + (f"/PlugIns/{name}.appex" if index > 1 else "")
                info = plistlib.dumps({"CFBundleExecutable": name})
                package.writestr(f"{bundle}/Info.plist", info)
                identity = f"UUID: 00000000-0000-0000-0000-{index + uuid_offset:012d} (arm64) fixture"
                package.writestr(f"{bundle}/{name}", identity)
                dsym = archive / "dSYMs" / f"{name}.dSYM" / "Contents"
                dwarf = dsym / "Resources/DWARF" / name
                dwarf.parent.mkdir(parents=True, exist_ok=True)
                dwarf.write_text(identity)
                (dsym / "Info.plist").write_bytes(info)
        self.executable("xcodebuild", "#!/bin/sh\nprintf 'Xcode 26.1\\nBuild version 17B55\\n'\n")
        self.executable("xcrun", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1] == 'dwarfdump':
    print(Path(sys.argv[-1]).read_text()); sys.exit(0)
path = Path(os.environ['EXTERNAL_STATE'])
state = json.loads(path.read_text())
state['apple_uploads'] = state.get('apple_uploads', 0) + 1
path.write_text(json.dumps(state))
sys.exit(9)
''')
        return archive, ipa

    def test_dry_run_reserves_nothing_and_requires_explicit_first_version(self):
        result = self.cli("cut", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VERSION", result.stderr)
        before = self.command("git", "rev-parse", "HEAD").stdout
        result = self.cli("cut", VERSION="0.2.0", DRY_RUN="1")
        self.assertIn("builds/0.2.0/38", result.stdout)
        self.assertEqual(self.command("git", "rev-parse", "HEAD").stdout, before)
        self.assertEqual(self.command("git", "status", "--porcelain").stdout, "")
        self.assertEqual(self.command("git", "ls-remote", "--tags", "origin").stdout, "")

    def test_candidate_freezes_notes_versions_and_blocks_an_unstarted_reservation(self):
        self.cli("cut", VERSION="0.2.0")
        tag = "builds/0.2.0/38"
        source = self.command("git", "rev-parse", "HEAD").stdout.strip()
        self.assertEqual(self.command("git", "rev-parse", tag + "^{commit}").stdout.strip(), source)
        self.assertIn(source, self.command("git", "ls-remote", "origin", "refs/heads/main").stdout)
        annotation = json.loads(self.command("git", "for-each-ref", "--format=%(contents)", "refs/tags/" + tag).stdout)
        self.assertEqual(annotation["source"], source)
        self.assertEqual(annotation["build"], 38)
        project = (self.repo / "project.yml").read_text()
        self.assertEqual(project.count('MARKETING_VERSION: "0.2.0"'), 3)
        self.assertEqual(project.count('CURRENT_PROJECT_VERSION: "38"'), 3)
        notes = (self.repo / "CHANGELOG.md").read_text()
        self.assertIn('## [Unreleased]\n\n## [0.2.0]\n', notes)
        self.assertIn('- Repair SSH. (#7)', notes)
        self.assertIn('## [0.1.16] - 2026-10-01', notes)
        result = self.cli("cut", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unresolved", result.stderr)
        self.assertEqual(self.command("git", "rev-parse", "HEAD").stdout.strip(), source)

    def test_ci_accepts_the_lightweight_tag_a_tag_push_checkout_leaves(self):
        self.cli("cut", VERSION="0.2.0")
        tag = "builds/0.2.0/38"
        source = self.command("git", "rev-parse", tag + "^{commit}").stdout.strip()
        self.command("git", "tag", "--force", tag, source)
        self.assertEqual(self.command("git", "cat-file", "-t", "refs/tags/" + tag).stdout.strip(), "commit")
        code, output = self.ci("ci-init", Inventory(None, 37, False))
        self.assertEqual(code, 0, output)
        self.assertEqual(self.command("git", "cat-file", "-t", "refs/tags/" + tag).stdout.strip(), "tag")
        self.assertEqual(self.record()[1]["state"], "reserved")

    def test_upload_ambiguity_blocks_reupload_and_valid_build_only_repairs_records(self):
        self.cli("cut", VERSION="0.2.0")
        absent = Inventory(None, 37, False)
        self.assertEqual(self.ci("ci-init", absent)[0], 0)
        self.assertIn("action=archive", self.ci("ci-plan", absent)[1])
        archive, ipa = self.signed_fixture()
        code, output = self.ci("ci-upload", absent, IPA=str(ipa), ASC_API_KEY_ID="key", ASC_API_ISSUER_ID="issuer")
        self.assertNotEqual(code, 0)
        self.assertIn("unknown", output)
        self.assertEqual(self.record()[1]["state"], "upload_started")
        state = json.loads(self.external.read_text())
        symbols_name = self.record()[1]["dsym_asset"]
        with zipfile.ZipFile(io.BytesIO(base64.b64decode(state["files"][symbols_name]))) as symbols:
            self.assertEqual(len(symbols.namelist()), 6)
            self.assertTrue(all(name.startswith("dSYMs/") for name in symbols.namelist()))
            self.assertFalse(any(name.endswith(".p12") for name in symbols.namelist()))
        self.assertEqual(self.record()[1]["dsym_uuids"]["HeelerWidgets.dSYM/Contents/Resources/DWARF/HeelerWidgets"],
                         ["00000000-0000-0000-0000-000000000003 (arm64)"])
        self.assertEqual(state["apple_uploads"], 1)
        # Later jobs/reruns must use the persisted symbols, not the vanished runner.
        shutil.rmtree(archive)
        self.assertIn("action=observe", self.ci("ci-plan", absent)[1])
        # No repeat call to altool, even if Apple has not exposed the build yet.
        code, output = self.ci("ci-upload", absent, IPA=str(ipa))
        self.assertNotEqual(code, 0)
        self.assertIn("observe", output)
        valid = Inventory(AppleBuild("apple-38", "0.2.0", 38, "VALID"), 38, False)
        self.assertEqual(self.ci("ci-observe", valid)[0], 0)
        self.assertEqual(self.record()[1]["apple_build_id"], "apple-38")
        self.assertEqual(self.record()[1]["state"], "valid")
        observed = self.record()[1]["observed_at"]
        self.assertIn("action=observe", self.ci("ci-plan", valid)[1])
        state = json.loads(self.external.read_text())
        state["fail_asset"] = True
        self.external.write_text(json.dumps(state))
        self.assertNotEqual(self.ci("ci-publish", valid)[0], 0)
        self.assertTrue(self.record()[0]["draft"])
        state = json.loads(self.external.read_text())
        state["fail_asset"] = False
        self.external.write_text(json.dumps(state))
        self.assertEqual(self.ci("ci-publish", valid)[0], 0)
        release, record = self.record()
        self.assertFalse(release["draft"])
        self.assertTrue(release["prerelease"])
        self.assertEqual(release["make_latest"], "false")
        manifest = json.loads(self.external.read_text())["manifest"]
        self.assertEqual(manifest["candidate"]["build"], 38)
        self.assertEqual(manifest["apple_build_id"], "apple-38")
        self.assertEqual(manifest["dsym_asset"], symbols_name)
        self.assertEqual(record["observed_at"], observed)
        self.assertEqual(manifest["observed_at"], observed)
        self.assertNotIn("ASC_API", json.dumps(manifest))
        state = json.loads(self.external.read_text())
        state["fail_asset"] = True
        self.external.write_text(json.dumps(state))
        # A lost publication response must not delete/replace the already attached manifest.
        self.assertEqual(self.ci("ci-publish", valid)[0], 0)
        self.assertEqual(json.loads(self.external.read_text())["manifest"], manifest)
        self.assertEqual(self.ci("ci-observe", valid)[0], 0)
        self.assertEqual(self.record()[1]["observed_at"], observed)
        state = json.loads(self.external.read_text())
        self.assertEqual(state["apple_uploads"], 1)
        state["releases"]["builds/0.2.0/38"]["assets"] = [asset for asset in release["assets"]
                                                            if asset["name"] != symbols_name]
        self.external.write_text(json.dumps(state))
        self.assertNotEqual(self.ci("ci-publish", valid)[0], 0)
        state["releases"]["builds/0.2.0/38"]["assets"] = release["assets"]
        self.external.write_text(json.dumps(state))
        source = self.command("git", "rev-parse", "HEAD").stdout.strip()
        state = json.loads(self.external.read_text())
        state["runs"] = [{"id": 123, "head_sha": source, "status": "completed", "conclusion": "success", "event": "push"}]
        state["manifest"]["ipa_sha256"] = "conflicting-content"
        self.external.write_text(json.dumps(state))
        self.assertIn("conflicts", self.ci("ci-publish", valid)[1])
        self.assertNotEqual(self.cli("cut", DRY_RUN="1", check=False).returncode, 0)
        state["releases"]["builds/0.2.0/38"]["assets"] = []
        self.external.write_text(json.dumps(state))
        self.assertIn("unresolved", self.cli("cut", DRY_RUN="1", check=False).stderr)

    def test_symbol_storage_failure_and_lost_response_never_start_apple_upload(self):
        self.cli("cut", VERSION="0.2.0")
        absent = Inventory(None, 37, False)
        self.assertEqual(self.ci("ci-init", absent)[0], 0)
        self.signed_fixture()
        state = json.loads(self.external.read_text())
        state["fail_asset"] = True
        self.external.write_text(json.dumps(state))
        self.assertIn("storage unavailable", self.ci("ci-upload", absent)[1])
        state = json.loads(self.external.read_text())
        self.assertNotIn("apple_uploads", state)
        self.assertEqual(self.record()[1]["state"], "prepared")
        state.update(fail_asset=False, lose_asset_response=True)
        self.external.write_text(json.dumps(state))
        self.assertNotEqual(self.ci("ci-upload", absent)[0], 0)
        state = json.loads(self.external.read_text())
        first = dict(state["files"])
        self.assertEqual(len(first), 1)
        self.assertNotIn("apple_uploads", state)
        # A pre-upload rebuild may produce different symbols under the same tag.
        # Keep both assets; the checkpoint selects the binary's matching bundle.
        self.signed_fixture(uuid_offset=100)
        self.assertNotEqual(self.ci("ci-upload", absent)[0], 0)
        state = json.loads(self.external.read_text())
        self.assertEqual(len(state["files"]), 2)
        self.assertEqual(state["files"][next(iter(first))], next(iter(first.values())))
        self.assertNotIn("apple_uploads", state)
        asset = state["releases"]["builds/0.2.0/38"]["assets"][-1]
        asset["digest"] = "sha256:" + "0" * 64
        self.external.write_text(json.dumps(state))
        self.assertIn("digest conflicts", self.ci("ci-upload", absent)[1])
        self.assertNotIn("apple_uploads", json.loads(self.external.read_text()))
        # Null server digests require downloading and hashing the retained bytes.
        asset["digest"] = None
        state["fail_asset"] = True
        retained = state["files"][asset["name"]]
        state["files"][asset["name"]] = base64.b64encode(b"corrupt ZIP").decode()
        self.external.write_text(json.dumps(state))
        self.assertIn("digest conflicts", self.ci("ci-upload", absent)[1])
        self.assertNotIn("apple_uploads", json.loads(self.external.read_text()))
        state["files"][asset["name"]] = retained
        self.external.write_text(json.dumps(state))
        code, output = self.ci("ci-upload", absent, ASC_API_KEY_ID="key", ASC_API_ISSUER_ID="issuer")
        self.assertNotEqual(code, 0)
        self.assertIn("unknown", output)
        state = json.loads(self.external.read_text())
        self.assertEqual(state["apple_uploads"], 1)
        self.assertEqual(len(state["files"]), 2)
        self.assertEqual(self.record()[1]["dsym_asset"], asset["name"])

    def test_missing_mismatched_or_unexpected_symbols_stop_before_external_uploads(self):
        self.cli("cut", VERSION="0.2.0")
        absent = Inventory(None, 37, False)
        self.assertEqual(self.ci("ci-init", absent)[0], 0)
        for problem in ("missing extension", "wrong UUID", "wrong architecture", "unexpected file", "symlink"):
            with self.subTest(problem=problem):
                archive, _ = self.signed_fixture()
                bundle = archive / "dSYMs/HeelerWidgets.dSYM"
                dwarf = bundle / "Contents/Resources/DWARF/HeelerWidgets"
                if problem == "missing extension":
                    shutil.rmtree(bundle)
                elif problem == "wrong UUID":
                    dwarf.write_text(dwarf.read_text().replace("000000000003", "000000000099"))
                elif problem == "wrong architecture":
                    dwarf.write_text(dwarf.read_text().replace("arm64", "arm64e"))
                elif problem == "unexpected file":
                    (bundle / "certificate.p12").write_bytes(b"not public")
                else:
                    dwarf.unlink()
                    dwarf.symlink_to(archive / "signing.p12")
                code, output = self.ci("ci-upload", absent)
                self.assertNotEqual(code, 0, output)
                self.assertEqual(self.record()[1]["state"], "reserved")
                state = json.loads(self.external.read_text())
                self.assertNotIn("files", state)
                self.assertNotIn("apple_uploads", state)
                shutil.rmtree(archive)

    def test_concurrent_retry_cannot_be_bypassed_by_a_new_reservation(self):
        self.cli("cut", VERSION="0.2.0")
        absent = Inventory(None, 37, False)
        self.assertEqual(self.ci("ci-init", absent)[0], 0)
        source = self.command("git", "rev-parse", "HEAD").stdout.strip()
        state = json.loads(self.external.read_text())
        state["runs"] = [{"id": 123, "head_sha": source, "status": "completed", "conclusion": "failure", "event": "push"}]
        self.external.write_text(json.dumps(state))
        # Another run starts an upload after the cutter's final read, before push.
        # GitHub serializes workflows, but not the local cutter and a workflow.
        git = shutil.which("git")
        self.executable("git", f'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1:3] == ['push', '--atomic']:
    path = Path(os.environ['EXTERNAL_STATE'])
    state = json.loads(path.read_text())
    release = state['releases']['builds/0.2.0/38']
    release['body'] = release['body'].replace('"state": "reserved"', '"state": "upload_started"')
    path.write_text(json.dumps(state))
os.execv({git!r}, [{git!r}, *sys.argv[1:]])
''')
        self.cli("cut")
        tag = "builds/0.2.0/39"
        self.assertIn(tag, self.command("git", "ls-remote", "--tags", "origin").stdout)
        env = dict(GITHUB_REF_NAME=tag, GITHUB_RUN_ID="124")
        self.assertEqual(self.ci("ci-init", absent, **env)[0], 0)
        code, output = self.ci("ci-plan", absent, **env)
        self.assertNotEqual(code, 0)
        self.assertIn("upload_started", output)
        ipa = self.root / "Heeler.ipa"
        ipa.write_bytes(b"new signed fixture")
        self.executable("xcodebuild", "#!/bin/sh\necho 'Xcode fixture'\n")
        code, output = self.ci("ci-upload", absent, IPA=str(ipa), **env)
        self.assertNotEqual(code, 0)
        self.assertIn("upload_started", output)
        state = json.loads(self.external.read_text())
        state["runs"].append({"id": 124, "head_sha": self.command("git", "rev-parse", "HEAD").stdout.strip(),
                              "status": "completed", "conclusion": "failure", "event": "push"})
        self.external.write_text(json.dumps(state))
        result = self.cli("cut", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("upload_started", result.stderr)
        self.assertNotIn("builds/0.2.0/40", self.command("git", "ls-remote", "--tags", "origin").stdout)

    def test_failed_candidate_allows_same_version_empty_notes_and_blocks_stale_retry(self):
        self.cli("cut", VERSION="0.2.0")
        absent = Inventory(None, 37, False)
        self.assertEqual(self.ci("ci-init", absent)[0], 0)
        source = self.command("git", "rev-parse", "HEAD").stdout.strip()
        state = json.loads(self.external.read_text())
        state["runs"] = [{"id": 123, "head_sha": source, "status": "completed", "conclusion": "failure", "event": "push"}]
        self.external.write_text(json.dumps(state))
        frozen = self.command("git", "show", "builds/0.2.0/38:CHANGELOG.md").stdout
        self.cli("cut")
        self.assertIn('CURRENT_PROJECT_VERSION: "39"', (self.repo / "project.yml").read_text())
        self.assertEqual((self.repo / "CHANGELOG.md").read_text(), frozen)
        result = self.cli("retry", TAG="builds/0.2.0/38", DRY_RUN="1", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("newer candidate", result.stderr)
        self.command("git", "checkout", "--quiet", "builds/0.2.0/38")
        code, output = self.ci("ci-plan", absent)
        self.assertNotEqual(code, 0)
        self.assertIn("newer candidate", output)

    def test_a_tag_whose_run_ended_before_reserving_is_void_only_when_proven(self):
        self.cli("cut", VERSION="0.2.0")
        tag = "builds/0.2.0/38"
        source = self.command("git", "rev-parse", "HEAD").stdout.strip()

        def run(run_id, **fields):
            return dict({"id": run_id, "head_sha": source, "head_branch": tag, "event": "push",
                         "status": "completed", "conclusion": "failure"}, **fields)

        def job(name, conclusion, attempt=1):
            return {"name": name, "conclusion": conclusion, "run_attempt": attempt}

        candidate = "Resolve the candidate"
        later = [job("Test gate", "skipped"), job("Upload or observe the candidate", "skipped"),
                 job("Record the processed TestFlight build", "skipped")]

        def dry_run(runs, jobs):
            state = json.loads(self.external.read_text())
            state["runs"], state["jobs"] = runs, jobs
            self.external.write_text(json.dumps(state))
            return self.cli("cut", DRY_RUN="1", check=False)

        for runs, jobs, problem in (
            ([], {}, "no checkpoint or workflow yet"),
            ([run(200, head_branch="main")], {}, "no checkpoint or workflow yet"),
            ([run(200, status="in_progress", conclusion=None)], {}, "workflow still active"),
            ([run(200), run(201)], {}, "several workflow runs"),
            ([run(200)], {"200": [job(candidate, "failure"), job(candidate, "success", 2), *later]},
             "candidate job succeeded"),
            ([run(200)], {"200": [job(candidate, "failure"), job("Test gate / App tests (ordinary)", "success")]},
             "later jobs ran"),
        ):
            with self.subTest(problem=problem, runs=len(runs)):
                result = dry_run(runs, jobs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{tag} is unresolved (", result.stderr)
                self.assertIn(problem, result.stderr)

        result = dry_run([run(200, conclusion="startup_failure")], {})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TestFlight 0.2.0 (39)", result.stdout)

        dry_run([run(200)], {"200": [job(candidate, "failure"), job(candidate, "failure", 2), *later]})
        self.cli("cut")
        tags = self.command("git", "ls-remote", "--tags", "origin").stdout
        self.assertIn("refs/tags/builds/0.2.0/39", tags)
        self.assertIn("refs/tags/" + tag, tags)
        self.assertIn('CURRENT_PROJECT_VERSION: "39"', (self.repo / "project.yml").read_text())
        env = dict(GITHUB_REF_NAME="builds/0.2.0/39", GITHUB_RUN_ID="300")
        absent = Inventory(None, 37, False)
        self.assertEqual(self.ci("ci-init", absent, **env)[0], 0)
        code, output = self.ci("ci-plan", absent, **env)
        self.assertEqual(code, 0, output)
        self.assertIn("action=archive", output)

    def test_every_later_release_job_needs_the_candidate_job(self):
        spec = importlib.util.spec_from_file_location("testflight_jobs", SCRIPTS / "testflight.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        workflow = (SCRIPTS.parent / ".github/workflows/release.yml").read_text()
        parts = re.split(r"(?m)^  ([a-z][a-z0-9_-]*):\n", workflow.split("\njobs:\n", 1)[1])[1:]
        jobs = dict(zip(parts[0::2], parts[1::2]))
        self.assertIn(f"    name: {module.CANDIDATE_JOB}\n", jobs.pop("meta"))
        self.assertTrue(jobs)
        for name, body in jobs.items():
            with self.subTest(job=name):
                needs = re.search(r"(?m)^    needs: (.+)$", body)
                self.assertIsNotNone(needs)
                self.assertIn("meta", needs[1])

    def test_counter_closed_version_and_unproven_existing_build_stop_before_upload(self):
        self.cli("cut", VERSION="0.2.0")
        self.assertEqual(self.ci("ci-init", Inventory(None, 37, False))[0], 0)
        for inventory, message in ((Inventory(None, 73, False), "counter"),
                                   (Inventory(None, 37, True), "closed"),
                                   (Inventory(AppleBuild("unproven", "0.2.0", 38, "VALID"), 38, False), "checkpoint")):
            with self.subTest(message=message):
                code, output = self.ci("ci-plan", inventory)
                self.assertNotEqual(code, 0)
                self.assertIn(message, output)
                self.assertEqual(self.record()[1]["state"], "reserved")

    def test_cumulative_notes_freeze_per_build_and_version_advances_only_explicitly(self):
        self.cli("cut", VERSION="0.2.0")
        first = self.command("git", "show", "builds/0.2.0/38:CHANGELOG.md").stdout
        for run_id, tag, version, note in ((123, "builds/0.2.0/38", "", "Fix notifications."),
                                           (124, "builds/0.2.0/39", "0.3.0", "Add shell tabs.")):
            self.assertEqual(self.ci("ci-init", Inventory(None, 37, False), GITHUB_REF_NAME=tag,
                                     GITHUB_RUN_ID=str(run_id))[0], 0)
            source = self.command("git", "rev-parse", "HEAD").stdout.strip()
            state = json.loads(self.external.read_text())
            state["runs"].append({"id": run_id, "head_sha": source, "status": "completed", "conclusion": "failure", "event": "push"})
            self.external.write_text(json.dumps(state))
            notes = self.repo / "CHANGELOG.md"
            notes.write_text(notes.read_text().replace("## [Unreleased]\n", f"## [Unreleased]\n\n### Fixed\n\n- {note} (#8)\n", 1))
            self.command("git", "commit", "--quiet", "-am", "add notes")
            self.command("git", "push", "--quiet", "origin", "main")
            self.cli("cut", VERSION=version)
        second = self.command("git", "show", "builds/0.2.0/39:CHANGELOG.md").stdout
        self.assertIn("Repair SSH.", second)
        self.assertIn("Fix notifications.", second)
        self.assertNotIn("Add shell tabs.", second)
        self.assertEqual(self.command("git", "show", "builds/0.2.0/38:CHANGELOG.md").stdout, first)
        self.assertIn('MARKETING_VERSION: "0.3.0"', (self.repo / "project.yml").read_text())
        self.assertIn('CURRENT_PROJECT_VERSION: "40"', (self.repo / "project.yml").read_text())
        self.assertEqual(self.command("git", "tag", "--list", "v*").stdout, "")

    def test_rehearsal_cannot_upload_or_create_a_record(self):
        self.cli("cut", VERSION="0.2.0")
        env = dict(GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/main", VERSION="0.2.1", BUILD="39", MODE="rehearsal")
        empty = Inventory(None, 38, False)
        code, output = self.ci("ci-init", empty, **env)
        self.assertEqual(code, 0, output)
        self.assertIn("mode=rehearsal", output)
        self.assertIn("action=archive", self.ci("ci-plan", empty, **env)[1])
        self.signed_fixture()
        symbols = self.root / "rehearsal-dSYMs.zip"
        code, output = self.ci("ci-symbols", empty, DSYM_ZIP=str(symbols), **env)
        self.assertEqual(code, 0, output)
        self.assertTrue(symbols.is_file())
        for command in ("ci-upload", "ci-observe", "ci-publish"):
            code, output = self.ci(command, empty, **env)
            self.assertNotEqual(code, 0)
            self.assertIn("Only a build-tag push", output)
        self.assertEqual(json.loads(self.external.read_text())["releases"], {})
        self.assertEqual(self.command("git", "tag", "--list").stdout.strip(), "builds/0.2.0/38")

    def test_atomic_push_race_preserves_remote_winner_and_local_candidate(self):
        tree = self.command("git", "rev-parse", "HEAD^{tree}").stdout.strip()
        winner = self.command("git", "commit-tree", tree, "-p", "HEAD", "-m", "competing change").stdout.strip()
        generator = (self.bin / "xcodegen").read_text()
        self.executable("xcodegen", generator + f"\nimport subprocess\nsubprocess.run(['git', 'push', 'origin', '{winner}:refs/heads/main'], check=True)\n")
        result = self.cli("cut", VERSION="0.2.0", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Push outcome may be unknown", result.stderr)
        self.assertEqual(self.command("git", "ls-remote", "--tags", "origin").stdout, "")
        self.assertIn(winner, self.command("git", "ls-remote", "origin", "refs/heads/main").stdout)
        self.assertEqual(self.command("git", "cat-file", "-t", "builds/0.2.0/38").stdout.strip(), "tag")

    def test_unaccepted_versions_and_target_mismatch_do_not_reserve(self):
        for version in ("0.1.15", "v0.2.0", "0.2.0-beta.1"):
            result = self.cli("cut", VERSION=version, check=False)
            self.assertNotEqual(result.returncode, 0)
        project = self.repo / "project.yml"
        project.write_text(project.read_text().replace('VERSION: "37"', 'VERSION: "36"', 1))
        self.command("git", "commit", "--quiet", "-am", "mismatched extension")
        self.command("git", "push", "--quiet", "origin", "main")
        result = self.cli("cut", VERSION="0.2.0", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("agree in every target", result.stderr)
        self.assertEqual(self.command("git", "ls-remote", "--tags", "origin").stdout, "")


class AppleInventory(unittest.TestCase):
    def test_paginated_inventory_keeps_version_identity_and_signs_valid_jwt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key, public = root / "key.pem", root / "public.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                            "-out", str(key)], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], check=True, capture_output=True)
            requests = []

            def respond(request, timeout):
                requests.append(request)
                parsed = urlsplit(request.full_url)
                query = parse_qs(parsed.query)
                if parsed.path == "/v1/apps":
                    self.assertEqual(query["filter[bundleId]"], ["dev.bybee.heeler"])
                    data = {"data": [{"id": "app", "attributes": {"bundleId": "dev.bybee.heeler"}}]}
                elif parsed.path.endswith("/appStoreVersions"):
                    data = {"data": [{"attributes": {"versionString": "0.2.0", "appVersionState": "READY_FOR_DISTRIBUTION"}}]}
                else:
                    second = "cursor" in query
                    version, number, identity = ("0.2.0", "38", "target") if second else ("0.3.0", "77", "other")
                    data = {"data": [{"id": identity, "attributes": {"version": number, "processingState": "VALID"},
                                      "relationships": {"preReleaseVersion": {"data": {"id": identity}}}}],
                            "included": [{"id": identity, "type": "preReleaseVersions",
                                          "attributes": {"platform": "IOS", "version": version}}]}
                    if not second:
                        self.assertEqual(query["filter[app]"], ["app"])
                        self.assertEqual(query["filter[preReleaseVersion.platform]"], ["IOS"])
                        data["links"] = {"next": "https://api.appstoreconnect.apple.com/v1/builds?cursor=2"}
                return io.BytesIO(json.dumps(data).encode())

            with patch.dict(os.environ, ASC_API_KEY_ID="test-key", ASC_API_ISSUER_ID="test-issuer", ASC_API_KEY_P8=key.read_text()), \
                 patch("app_store_connect.urlopen", side_effect=respond):
                inventory = AppStoreConnect().inventory("dev.bybee.heeler", "0.2.0", 38)
            self.assertEqual(inventory, Inventory(AppleBuild("target", "0.2.0", 38, "VALID"), 77, True))
            token = requests[0].get_header("Authorization").removeprefix("Bearer ")
            header, claims, signature = token.split(".")
            self.assertEqual(json.loads(base64.urlsafe_b64decode(header + "=="))["alg"], "ES256")
            self.assertEqual(json.loads(base64.urlsafe_b64decode(claims + "=="))["aud"], "appstoreconnect-v1")
            raw = base64.urlsafe_b64decode(signature + "==")
            self.assertEqual(len(raw), 64)
            # Independent OpenSSL verification catches incorrect DER/JOSE conversion.
            integers = []
            for value in (raw[:32], raw[32:]):
                value = value.lstrip(b"\0") or b"\0"
                if value[0] >= 128:
                    value = b"\0" + value
                integers.append(b"\x02" + bytes([len(value)]) + value)
            body = b"".join(integers)
            (root / "sig").write_bytes(b"\x30" + bytes([len(body)]) + body)
            result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(root / "sig")],
                                    input=f"{header}.{claims}".encode(), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
