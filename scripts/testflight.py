#!/usr/bin/env python3
"""Cut and reconcile immutable TestFlight candidates; never publish to the store."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

from app_store_connect import AppStoreConnect, AppleError, Inventory


ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
TAG_PATTERN = re.compile(rf"builds/({VERSION_PATTERN})/([1-9][0-9]*)")
VERSION_FILES = ("project.yml", "Heeler.xcodeproj/project.pbxproj")
BUNDLE_ID = "dev.bybee.heeler"


class ReleaseError(Exception):
    pass


def run(*args: str, input: str | None = None) -> str:
    result = subprocess.run(args, input=input, text=True, capture_output=True)
    if result.returncode:
        raise ReleaseError(f"{' '.join(args[:2])} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def macho_uuids(path: Path) -> list[str]:
    found = re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", run("xcrun", "dwarfdump", "--uuid", str(path)))
    if not found:
        raise ReleaseError(f"No Mach-O UUIDs in {path.name}")
    return sorted(f"{uuid.upper()} ({arch})" for uuid, arch in found)


def package_symbols(archive: Path, ipa: Path, destination: Path) -> dict[str, list[str]]:
    root = archive / "dSYMs"
    bundles = sorted(root.glob("*.dSYM"))
    if not bundles:
        raise ReleaseError("Archive has no dSYM bundles")
    files = []
    identities = {}
    for bundle in bundles:
        if bundle.is_symlink() or not (bundle / "Contents/Info.plist").is_file():
            raise ReleaseError(f"Invalid dSYM bundle: {bundle.name}")
        for path in sorted(bundle.rglob("*")):
            if path.is_symlink():
                raise ReleaseError("Refusing symlinks in public dSYM assets")
            if not path.is_file():
                continue
            relative = path.relative_to(bundle).as_posix()
            dwarf = path.parent == bundle / "Contents/Resources/DWARF"
            if not (relative == "Contents/Info.plist" or dwarf or
                    (relative.startswith("Contents/Resources/Relocations/") and path.suffix == ".yml")):
                raise ReleaseError(f"Unexpected file in public dSYM bundle: {relative}")
            files.append(path)
            if dwarf:
                identities[path.relative_to(root).as_posix()] = macho_uuids(path)
        if not any(name.startswith(bundle.name + "/") for name in identities):
            raise ReleaseError(f"No DWARF symbols in {bundle.name}")
    available = {uuid for uuids in identities.values() for uuid in uuids}
    # Validate the exported binary, not only the pre-export archive. Export may
    # thin architectures; every shipped app/extension UUID must have symbols.
    with zipfile.ZipFile(ipa) as package, tempfile.TemporaryDirectory() as directory:
        plists = [name for name in package.namelist() if name.startswith("Payload/")
                  and name.endswith((".app/Info.plist", ".appex/Info.plist"))]
        if not plists:
            raise ReleaseError("IPA contains no app bundles")
        for name in plists:
            executable = plistlib.loads(package.read(name))["CFBundleExecutable"]
            if not executable or Path(executable).name != executable:
                raise ReleaseError("Invalid bundle executable name")
            binary = Path(directory) / "binary"
            with package.open(name.removesuffix("Info.plist") + executable) as source, binary.open("wb") as target:
                shutil.copyfileobj(source, target)
            if not set(macho_uuids(binary)) <= available:
                raise ReleaseError(f"Missing matching dSYM UUIDs for {executable}")
    # Deterministic ZIP metadata lets retries reuse identical symbol bundles.
    # Only reviewed dSYM contents are included, never the archive or IPA.
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for path in files:
            info = zipfile.ZipInfo("dSYMs/" + path.relative_to(root).as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            with path.open("rb") as source, package.open(info, "w") as target:
                shutil.copyfileobj(source, target)
    return identities


def check_symbols() -> None:
    identities = package_symbols(Path(os.environ["ARCHIVE"]), Path(os.environ["IPA"]), Path(os.environ["DSYM_ZIP"]))
    print(json.dumps(identities, indent=2))


def flag(name: str) -> bool:
    value = os.environ.get(name, "")
    if value not in ("", "0", "1"):
        raise ReleaseError(f"{name} must be 0 or 1")
    return value == "1"


def confirm() -> bool:
    if flag("DRY_RUN"):
        print("DRY_RUN=1: no commit, tag, push, dispatch, or upload.")
        return False
    if not flag("YES"):
        try:
            with open("/dev/tty", "r+") as terminal:
                terminal.write("Proceed? [y/N] ")
                terminal.flush()
                answer = terminal.readline().strip().lower()
        except OSError as error:
            raise ReleaseError("No terminal; review DRY_RUN=1, then use YES=1") from error
        if answer not in ("y", "yes"):
            raise ReleaseError("Aborted")
    return True


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(VERSION_PATTERN, value):
        raise ReleaseError(f"VERSION must be numeric X.Y.Z, got {value!r}")
    return tuple(map(int, value.split(".")))


def versions(ref: str | None = None) -> tuple[str, int]:
    values = []
    for name in VERSION_FILES:
        text = run("git", "show", f"{ref}:{name}") if ref else Path(name).read_text()
        separator, end = (r': "', '"') if name.endswith("yml") else (r" = ", ";")
        fields = []
        for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
            found = re.findall(rf"(?m)^\s*{key}{separator}([^\n]+){end}$", text)
            if not found or len(set(found)) != 1:
                raise ReleaseError(f"{name}: {key} must agree in every target")
            fields.append(found)
        if len(fields[0]) != len(fields[1]):
            raise ReleaseError(f"{name}: version/build target counts differ")
        version, build = fields[0][0], fields[1][0]
        version_tuple(version)
        if not re.fullmatch(r"[1-9][0-9]*", build):
            raise ReleaseError("CURRENT_PROJECT_VERSION must be a positive integer")
        values.append((version, int(build)))
    if values[0] != values[1]:
        raise ReleaseError("Committed Xcode project disagrees with project.yml; regenerate it")
    return values[0]


@dataclass(frozen=True)
class Candidate:
    tag: str
    version: str
    build: int
    source: str
    plugin: str
    bundle_id: str = BUNDLE_ID
    platform: str = "IOS"


def remote_tags() -> dict[str, str]:
    refs = dict(line.split()[::-1] for line in run("git", "ls-remote", "--tags", "origin", "refs/tags/builds/*").splitlines())
    tags = {}
    numbers = set()
    for ref, sha in refs.items():
        tag = ref.removeprefix("refs/tags/")
        match = TAG_PATTERN.fullmatch(tag)
        if not match:
            continue
        if int(match[2]) in numbers:
            raise ReleaseError("Remote build tags reuse a global build number")
        numbers.add(int(match[2]))
        if ref + "^{}" not in refs:
            raise ReleaseError(f"{tag} is not annotated")
        tags[tag] = refs[ref + "^{}"]
    return tags


def latest_tag(tags: dict[str, str]) -> str:
    return max(tags, key=lambda tag: int(tag.rsplit("/", 1)[1]), default="")


class GitHub:
    def __init__(self):
        remote = run("git", "remote", "get-url", "origin")
        self.repo = run("gh", "repo", "view", remote, "--json", "nameWithOwner", "--jq", ".nameWithOwner")

    def api(self, path: str, body: dict | None = None, method: str = "GET", missing=False):
        args = ["gh", "api", "--method", method]
        if body is not None:
            args += ["--input", "-"]
        args += [f"repos/{self.repo}/{path}"]
        result = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                                text=True, capture_output=True)
        if missing and result.returncode and "HTTP 404" in result.stderr:
            return None
        if result.returncode:
            raise ReleaseError(f"GitHub request failed: {result.stderr.strip()}")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def release(self, tag: str):
        # The tag endpoint only finds published releases. Checkpoints are
        # drafts, visible only to collaborators, so use the paginated list.
        page = 1
        while True:
            releases = self.api(f"releases?per_page=100&page={page}")
            for release in releases:
                if release["tag_name"] == tag:
                    return release
            if len(releases) < 100:
                return None
            page += 1

    def has_asset(self, release: dict, name: str, sha256: str) -> bool:
        assets = [asset for asset in release.get("assets", []) if asset["name"] == name]
        if not assets:
            return False
        if len(assets) != 1 or assets[0]["state"] != "uploaded":
            raise ReleaseError(f"Incomplete or conflicting asset: {name}; reconcile without replacing it")
        asset = assets[0]
        digest = asset.get("digest")
        if digest is None:
            # GitHub permits a null digest. Stream the download instead of
            # trusting its filename/size or loading a large ZIP into memory.
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "asset"
                with path.open("wb") as handle:
                    result = subprocess.run(["gh", "api", "-H", "Accept: application/octet-stream",
                                             f"repos/{self.repo}/releases/assets/{asset['id']}"],
                                            stdout=handle, stderr=subprocess.PIPE)
                if result.returncode:
                    raise ReleaseError(f"Cannot verify retained asset: {name}")
                digest = "sha256:" + file_sha256(path)
        if digest != "sha256:" + sha256:
            raise ReleaseError(f"Asset digest conflicts with the checkpoint: {name}")
        return True


RECORD_MARKER = "<!-- heeler-build-record:v1 -->"
# The record folds above the notes. Older records, such as 0.1.17 (40)'s,
# have no <details> wrapper.
RECORD_BODY = re.compile(re.escape(RECORD_MARKER)
                         + r"\n(?:<details><summary>Build record</summary>\n\n)?```json\n(.+?)\n```", re.S)


@dataclass
class BuildRecord:
    candidate: Candidate
    state: str
    run_id: str
    run_attempt: str
    observed_at: str
    ipa_sha256: str = ""
    toolchain: str = ""
    apple_build_id: str = ""
    apple_processing_state: str = ""
    dsym_asset: str = ""
    dsym_sha256: str = ""
    dsym_uuids: dict[str, list[str]] = field(default_factory=dict)

    @classmethod
    def read(cls, release: dict) -> BuildRecord:
        match = RECORD_BODY.match(release.get("body", ""))
        if not match:
            raise ReleaseError("Missing build checkpoint; reconcile before retrying")
        try:
            data = json.loads(match[1])
            data["candidate"] = Candidate(**data["candidate"])
            record = cls(**data)
        except (KeyError, TypeError, ValueError) as error:
            raise ReleaseError("Invalid build checkpoint") from error
        if record.state not in ("reserved", "prepared", "upload_started", "processing", "valid", "rejected"):
            raise ReleaseError("Unknown checkpoint state")
        return record

    def has_manifest(self, github: GitHub, release: dict) -> bool:
        assets = [asset for asset in release.get("assets", []) if asset["name"] == "build-manifest.json"]
        if not assets:
            return False
        if len(assets) != 1:
            raise ReleaseError("Conflicting build manifests; reconcile the record")
        manifest = json.loads(run("gh", "api", "-H", "Accept: application/octet-stream",
                                  f"repos/{github.repo}/releases/assets/{assets[0]['id']}"))
        if manifest != asdict(self):
            raise ReleaseError("Build manifest conflicts with the checkpoint; preserve it and reconcile")
        return True

    def has_symbols(self, github: GitHub, release: dict) -> bool:
        return bool(self.dsym_asset and self.dsym_sha256 and self.dsym_uuids
                    and github.has_asset(release, self.dsym_asset, self.dsym_sha256))

    def save(self, github: GitHub, release: dict | None) -> dict:
        notes = notes_for(run("git", "show", f"{self.candidate.source}:CHANGELOG.md"), self.candidate.version)
        notes = run(sys.executable, "scripts/format-release-notes.py", input=notes)
        body = (f"{RECORD_MARKER}\n<details><summary>Build record</summary>\n\n```json\n"
                + json.dumps(asdict(self), indent=2) + "\n```\n\n</details>\n\n" + notes)
        payload = {"tag_name": self.candidate.tag, "name": f"{self.candidate.version} ({self.candidate.build}) - TestFlight",
                   "body": body, "draft": True if release is None else release["draft"],
                   "prerelease": True, "make_latest": "false"}
        if release is None:
            return github.api("releases", payload, "POST")
        return github.api(f"releases/{release['id']}", payload, "PATCH")


# release.yml's first job. Every later job needs it, and it succeeds only
# after saving the checkpoint.
CANDIDATE_JOB = "Resolve the candidate"


def unreserved_problem(github: GitHub, tag: str, source: str) -> str | None:
    """Why a tag without a checkpoint is unresolved, or None when it is void.

    A rerun refuses to create a missing checkpoint and the tag cannot be pushed
    again, so once the tag's push run has ended without its candidate job ever
    succeeding, no job can reserve or upload that build.
    """
    runs = [workflow_run for workflow_run in github.api(
        f"actions/workflows/release.yml/runs?event=push&head_sha={source}&per_page=100")["workflow_runs"]
        if workflow_run["head_branch"] == tag and workflow_run["head_sha"] == source]
    if not runs:
        return "no checkpoint or workflow yet"
    if len(runs) != 1:
        return "no checkpoint, several workflow runs; reconcile them"
    if runs[0]["status"] != "completed":
        return "no checkpoint, workflow still active"
    page = github.api(f"actions/runs/{runs[0]['id']}/jobs?filter=all&per_page=100")
    jobs = page["jobs"]
    if page["total_count"] != len(jobs):
        return "no checkpoint, too many jobs to inspect; reconcile them"
    if any(job["name"] == CANDIDATE_JOB and job["conclusion"] == "success" for job in jobs):
        return "no checkpoint although the candidate job succeeded; reconcile it"
    if any(job["name"] != CANDIDATE_JOB and job["conclusion"] != "skipped" for job in jobs):
        return "no checkpoint although later jobs ran; reconcile it"
    return None


# GitHub's annotation on a job it never gave a runner, as when macOS arm64
# capacity runs out. ci-full.yml's summary job then fails in its first step.
NO_RUNNER = "The job was not acquired by Runner"
WORKER_CHECK = "Require every worker to succeed"
# The push run and at most two automatic retries; later ones need a person.
AUTOMATIC_ATTEMPTS = 3


def runner_shortage_problem(github: GitHub, run_id: str, attempt: int) -> str | None:
    """Why an attempt's failure needs a person, or None when every failed job
    either never got a runner or only reports that a worker did not succeed."""
    page = github.api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    jobs = page["jobs"]
    if page["total_count"] != len(jobs):
        return "too many jobs to inspect"
    starved = False
    for job in jobs:
        if job["conclusion"] in ("success", "skipped"):
            continue
        failed_steps = [step["name"] for step in job["steps"] if step["conclusion"] == "failure"]
        if not job["steps"] and any(
                annotation["annotation_level"] == "failure" and annotation["message"].startswith(NO_RUNNER)
                for annotation in github.api(f"check-runs/{job['id']}/annotations")):
            starved = True
        elif failed_steps != [WORKER_CHECK]:
            return f"{job['name']} ended {job['conclusion']} for another reason"
    return None if starved else "every job got a runner"


def automatic_retry() -> None:
    """Release retry's job: rerun an attempt that failed only for lack of runners."""
    run_id, attempt = os.environ["RUN_ID"], int(os.environ["RUN_ATTEMPT"])
    if attempt >= AUTOMATIC_ATTEMPTS:
        print(f"Attempt {attempt} was the last automatic one; review it before make testflight-retry.")
        return
    github = GitHub()
    latest = github.api(f"actions/runs/{run_id}")["run_attempt"]
    if latest != attempt:
        print(f"Attempt {latest} has already started; nothing to retry.")
        return
    problem = runner_shortage_problem(github, run_id, attempt)
    if problem:
        print(f"No automatic retry: {problem}.")
        return
    status(retry=True, run_id=run_id)


def require_settled(github: GitHub, tags: dict[str, str]) -> None:
    for tag in sorted(tags, key=lambda value: int(value.rsplit("/", 1)[1]), reverse=True):
        release = github.release(tag)
        if release is None:
            problem = unreserved_problem(github, tag, tags[tag])
            if problem:
                raise ReleaseError(f"{tag} is unresolved ({problem})")
            # Void: it never reserved its number, so check the older tags.
            continue
        record = BuildRecord.read(release)
        if record.candidate.tag != tag or record.candidate.source != tags[tag]:
            raise ReleaseError("Checkpoint identity does not match the immutable tag")
        if (record.state == "valid" and not release["draft"] and release["prerelease"]
                and record.has_manifest(github, release) and record.has_symbols(github, release)):
            # This upload passed the same predecessor gate. Its durable record
            # remains sufficient after GitHub expires the workflow run.
            return
        workflow_run = github.api(f"actions/runs/{record.run_id}")
        if workflow_run["head_sha"] != tags[tag] or workflow_run["status"] != "completed":
            raise ReleaseError(f"{tag} is unresolved (workflow still active or identity mismatch)")
        before_upload_failure = record.state in ("reserved", "prepared") and workflow_run["conclusion"] in (
            "failure", "cancelled", "timed_out", "startup_failure")
        if not (before_upload_failure or record.state == "rejected"):
            raise ReleaseError(f"{tag} is unresolved ({record.state}); run make testflight-retry TAG={tag}")
        # A failed newer reservation must not hide an older uncertain upload.


def candidate_from_tag(tag: str) -> Candidate:
    match = TAG_PATTERN.fullmatch(tag)
    if not match:
        raise ReleaseError("TAG must be builds/X.Y.Z/N")
    ref = f"refs/tags/{tag}"
    # Forced: on a tag push, actions/checkout leaves a lightweight tag at the
    # commit, which a plain fetch refuses to replace, failing with no output.
    # The checks below still require the remote's annotated tag.
    run("git", "fetch", "--quiet", "origin", f"+{ref}:{ref}", "+refs/heads/main:refs/remotes/origin/main")
    if run("git", "cat-file", "-t", ref) != "tag":
        raise ReleaseError("Build tag must be annotated")
    source = run("git", "rev-parse", ref + "^{commit}")
    run("git", "merge-base", "--is-ancestor", source, "origin/main")
    version, build = versions(source)
    plugin_text = run("git", "show", f"{source}:plugin/herdr-plugin.toml")
    plugin = re.search(r'(?m)^version = "([^"]+)"$', plugin_text)
    if plugin is None:
        raise ReleaseError("Candidate has no plugin version")
    candidate = Candidate(tag, version, build, source, plugin[1])
    annotation = run("git", "cat-file", "-p", ref).split("\n\n", 1)[1]
    if (version, build) != (match[1], int(match[2])) or json.loads(annotation) != asdict(candidate):
        raise ReleaseError("Tag, annotation, and committed target versions disagree")
    if remote_tags().get(tag) != source:
        raise ReleaseError("Remote tag identity changed")
    return candidate


def output(**values) -> None:
    for key, value in values.items():
        print(f"{key}={value}")
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")


def initialize() -> None:
    if os.environ.get("GITHUB_EVENT_NAME") != "push":
        if os.environ.get("GITHUB_REF") != "refs/heads/main":
            raise ReleaseError("Rehearsals run from main only")
        current, counter = versions()
        version = os.environ.get("VERSION", "")
        if version_tuple(version) < version_tuple(current):
            raise ReleaseError("Rehearsal VERSION cannot decrease")
        tag = latest_tag(remote_tags())
        build = max(counter, int(tag.rsplit("/", 1)[1]) if tag else 0) + 1
        output(mode="rehearsal", version=version, build=build)
        return
    candidate = candidate_from_tag(os.environ.get("GITHUB_REF_NAME", ""))
    if candidate.source != os.environ.get("GITHUB_SHA") or candidate.source != run("git", "rev-parse", "HEAD"):
        raise ReleaseError("Workflow checkout does not match the candidate")
    github = GitHub()
    release = github.release(candidate.tag)
    if release is None:
        if os.environ.get("GITHUB_RUN_ATTEMPT") != "1":
            raise ReleaseError("Missing checkpoint on a rerun; reconcile original run evidence")
        BuildRecord(candidate, "reserved", os.environ["GITHUB_RUN_ID"], "1", "").save(github, None)
    elif BuildRecord.read(release).candidate != candidate:
        raise ReleaseError("Existing checkpoint identifies different source")
    output(mode="candidate", tag=candidate.tag, version=candidate.version, build=candidate.build)


def context() -> tuple[GitHub, dict, BuildRecord]:
    if os.environ.get("GITHUB_EVENT_NAME") != "push":
        raise ReleaseError("Only a build-tag push can authorize candidate side effects")
    candidate = candidate_from_tag(os.environ.get("GITHUB_REF_NAME", ""))
    if candidate.source != os.environ.get("GITHUB_SHA") or candidate.source != run("git", "rev-parse", "HEAD"):
        raise ReleaseError("Checkout does not match the candidate")
    github = GitHub()
    release = github.release(candidate.tag)
    if release is None:
        raise ReleaseError("Missing checkpoint; reconcile original run evidence")
    record = BuildRecord.read(release)
    if record.candidate != candidate or record.run_id != os.environ.get("GITHUB_RUN_ID"):
        raise ReleaseError("Checkpoint source or workflow run mismatch")
    return github, release, record


def check_unused(github: GitHub, candidate: Candidate, inventory: Inventory) -> None:
    if inventory.selected:
        raise ReleaseError("Apple already has this build without a matching upload checkpoint; reconcile it")
    if inventory.highest_number >= candidate.build:
        raise ReleaseError("Apple build counter is ahead of this candidate; reconcile the global floor")
    if inventory.closed:
        raise ReleaseError("Apple has closed this marketing version; choose the next VERSION explicitly")
    tags = remote_tags()
    if latest_tag(tags) != candidate.tag:
        raise ReleaseError("A newer candidate is reserved; an older tag cannot start an upload")
    # The workflow's app-wide concurrency lock, unlike the local cutter, spans
    # this check and upload. Earlier retries cannot change state in between.
    require_settled(github, {tag: source for tag, source in tags.items() if tag != candidate.tag})


def plan() -> None:
    apple = AppStoreConnect()
    if os.environ.get("MODE") == "rehearsal":
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or os.environ.get("GITHUB_REF") != "refs/heads/main":
            raise ReleaseError("Rehearsals run from main only")
        inventory = apple.inventory(BUNDLE_ID, os.environ["VERSION"], int(os.environ["BUILD"]))
        if inventory.selected or inventory.highest_number >= int(os.environ["BUILD"]) or inventory.closed:
            raise ReleaseError("Rehearsal identity is unavailable; reconcile Apple inventory first")
        output(action="archive")
        return
    github, _, record = context()
    candidate = record.candidate
    inventory = apple.inventory(candidate.bundle_id, candidate.version, candidate.build)
    if record.state == "rejected":
        raise ReleaseError("Apple rejected this binary; create a new candidate")
    if record.state in ("upload_started", "processing", "valid"):
        output(action="observe")
    else:
        check_unused(github, candidate, inventory)
        output(action="archive")


def upload() -> None:
    github, release, record = context()
    if record.state not in ("reserved", "prepared"):
        raise ReleaseError("Upload was already attempted; observe Apple, never upload again")
    candidate = record.candidate
    apple = AppStoreConnect()
    check_unused(github, candidate, apple.inventory(candidate.bundle_id, candidate.version, candidate.build))
    ipa = Path(os.environ["IPA"])
    record.ipa_sha256 = file_sha256(ipa)
    record.toolchain = run("xcodebuild", "-version")
    record.run_attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    with tempfile.TemporaryDirectory() as directory:
        symbols = Path(directory) / "dSYMs.zip"
        record.dsym_uuids = package_symbols(Path(os.environ["ARCHIVE"]), ipa, symbols)
        record.dsym_sha256 = file_sha256(symbols)
        record.dsym_asset = f"Heeler-{candidate.version}-{candidate.build}-dSYMs-{record.dsym_sha256}.zip"
        symbols = symbols.rename(symbols.with_name(record.dsym_asset))
        record.state = "prepared"
        release = record.save(github, release)
        if not record.has_symbols(github, release):
            run("gh", "release", "upload", candidate.tag, str(symbols), "--repo", github.repo)
            release = github.release(candidate.tag)
        if release is None or not record.has_symbols(github, release):
            raise ReleaseError("dSYM retention is unresolved; no Apple upload is authorized")
    check_unused(github, candidate, apple.inventory(candidate.bundle_id, candidate.version, candidate.build))
    # Persist BEFORE starting the external side effect. A lost response, runner
    # cancellation, or failed checkpoint write must never authorize re-upload.
    record.state = "upload_started"
    release = record.save(github, release)
    try:
        run("xcrun", "altool", "--upload-app", "-f", str(ipa), "-t", "ios",
            "--apiKey", os.environ["ASC_API_KEY_ID"], "--apiIssuer", os.environ["ASC_API_ISSUER_ID"])
    except ReleaseError as error:
        raise ReleaseError(f"Upload outcome is unknown; retry observation only. {error}") from error
    record.state = "processing"
    record.save(github, release)


def observe() -> None:
    github, release, record = context()
    if record.state not in ("upload_started", "processing", "valid"):
        raise ReleaseError("No upload checkpoint to observe")
    if record.state == "valid":
        print("Apple processing was already recorded as valid; preserve the original observation.")
        return
    candidate = record.candidate
    apple = AppStoreConnect()
    for attempt in range(30):
        inventory = apple.inventory(candidate.bundle_id, candidate.version, candidate.build)
        build = inventory.selected
        if build:
            if record.apple_build_id and record.apple_build_id != build.id:
                raise ReleaseError("Apple build ID changed; reconcile before proceeding")
            record.apple_build_id = build.id
            record.apple_processing_state = build.state
            record.observed_at = datetime.now(timezone.utc).isoformat()
            if build.state == "VALID":
                record.state = "valid"
            elif build.state in ("FAILED", "INVALID"):
                record.state = "rejected"
            else:
                record.state = "processing"
            release = record.save(github, release)
            if record.state == "valid":
                print(f"Apple processed {candidate.version} ({candidate.build}); tester distribution may still be pending.")
                return
            if record.state == "rejected":
                raise ReleaseError("Apple processing rejected this binary; fix it in a new numbered candidate")
        if attempt < 29:
            time.sleep(30)
    raise ReleaseError("Apple visibility/processing is unresolved; keep the reservation and retry observation only")


def publish_record() -> None:
    github, release, record = context()
    if record.state != "valid" or not record.apple_build_id or not record.ipa_sha256:
        raise ReleaseError("Only a processed build with upload provenance can have a public record")
    if not record.has_symbols(github, release):
        raise ReleaseError("Missing retained dSYM asset; restore the original symbols before publication")
    # Never replace an existing asset: a retry must preserve published evidence.
    # The matching symbols are already attached; never attach IPA/signing files.
    if not record.has_manifest(github, release):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "build-manifest.json"
            manifest.write_text(json.dumps(asdict(record), indent=2) + "\n")
            run("gh", "release", "upload", record.candidate.tag, str(manifest), "--repo", github.repo)
        release = github.release(record.candidate.tag)
        if release is None or not record.has_manifest(github, release):
            raise ReleaseError("Manifest attachment is unresolved; retry record repair")
    release["draft"] = False
    release = record.save(github, release)
    if release["draft"] or not release["prerelease"]:
        raise ReleaseError("Build record was not published as a prerelease")
    print(f"Recorded {record.candidate.tag}; no App Store submission was made.")


def status(retry=False, run_id: str | None = None) -> None:
    candidate = candidate_from_tag(os.environ.get("TAG", ""))
    github = GitHub()
    release = github.release(candidate.tag)
    if release is None:
        raise ReleaseError("Reserved tag has no checkpoint; inspect its original workflow before reconciliation")
    record = BuildRecord.read(release)
    if record.candidate != candidate:
        raise ReleaseError("Checkpoint source mismatch")
    if run_id is not None and record.run_id != run_id:
        raise ReleaseError("Checkpoint names another workflow run")
    workflow_run = github.api(f"actions/runs/{record.run_id}")
    if workflow_run["head_sha"] != candidate.source or workflow_run["event"] != "push":
        raise ReleaseError("Workflow source mismatch")
    print(json.dumps(asdict(record), indent=2))
    print(f"Workflow: {workflow_run['status']} / {workflow_run.get('conclusion')}\n"
          f"Draft: {release['draft']}. This is recorded Apple processing state, not live App Store status.")
    if not retry:
        return
    if workflow_run["status"] != "completed":
        raise ReleaseError("Original workflow is still active; do not start a competing retry")
    if record.state == "rejected":
        raise ReleaseError("Rejected binary; create a new candidate")
    if (record.state == "valid" and not release["draft"] and workflow_run["conclusion"] == "success"
            and record.has_manifest(github, release) and record.has_symbols(github, release)):
        print("Candidate is already recorded; nothing to retry.")
        return
    if record.state in ("reserved", "prepared"):
        if latest_tag(remote_tags()) != candidate.tag:
            raise ReleaseError("A newer candidate is reserved; this retry cannot upload")
        print("Resume failed tests/building of the original tag; Apple is checked again before upload.")
    else:
        print("Resume Apple observation / record repair only; no rebuild or upload.")
    print(f"gh run rerun {record.run_id} --failed --repo {github.repo}")
    if confirm():
        run("gh", "run", "rerun", record.run_id, "--failed", "--repo", github.repo)


def check() -> None:
    version = os.environ.get("VERSION", "")
    version_tuple(version)
    github = GitHub()
    print(f"Rehearse signing and validation from origin/main for {version}; no tag or upload.\n"
          f"gh workflow run release.yml --ref main -f version={version} --repo {github.repo}")
    if confirm():
        run("gh", "workflow", "run", "release.yml", "--ref", "main", "-f", f"version={version}", "--repo", github.repo)


def notes_for(text: str, version: str) -> str:
    matches = list(re.finditer(rf"(?m)^## \[{re.escape(version)}\][^\n]*$", text))
    if len(matches) != 1:
        raise ReleaseError(f"CHANGELOG needs exactly one [{version}] section")
    rest = text[matches[0].end():]
    return re.split(r"(?m)^## ", rest, maxsplit=1)[0].strip()


def cut_notes(text: str, version: str) -> str:
    headings = list(re.finditer(r"(?m)^## \[([^\]]+)\]([^\n]*)$", text))
    if not headings or headings[0][1] != "Unreleased":
        raise ReleaseError("CHANGELOG must start with an [Unreleased] section")
    existing = [heading for heading in headings if heading[1] == version]
    if len(existing) > 1 or (existing and (existing[0] != headings[1] or existing[0][2].strip())):
        raise ReleaseError("Refusing to merge a historical, duplicate, or out-of-order version section")
    fresh = notes_for(text, "Unreleased")
    previous = notes_for(text, version) if existing else ""
    if not previous and not fresh:
        raise ReleaseError("A new version needs release notes")
    sections: dict[str, str] = {}
    for body in (previous, fresh):
        if not body:
            continue
        parts = re.split(r"(?m)^### (.+)\n", body + "\n")
        if parts[0].strip() or len(parts) == 1:
            raise ReleaseError("Release notes must use ### category headings")
        seen = set()
        for category, content in zip(parts[1::2], parts[2::2]):
            if category in seen:
                raise ReleaseError("Ambiguous duplicate release-note category")
            seen.add(category)
            old = sections.get(category, "")
            content = content.strip()
            if old and set(re.split(r"\n(?=- )", old)) & set(re.split(r"\n(?=- )", content)):
                raise ReleaseError("Ambiguous duplicate release note; reconcile it before cutting")
            sections[category] = "\n".join(part for part in (old, content) if part)
    stop = headings[2 if existing else 1].start() if len(headings) > (2 if existing else 1) else len(text)
    merged = "\n\n".join(f"### {category}\n\n{body}" for category, body in sections.items())
    return text[:headings[0].start()] + f"## [Unreleased]\n\n## [{version}]\n\n{merged}\n\n" + text[stop:]


def cut() -> None:
    if os.environ.get("BUILD"):
        raise ReleaseError("BUILD overrides are not supported; the command allocates the next build")
    for tool in ("git", "gh", "xcodegen"):
        if not shutil.which(tool):
            raise ReleaseError(f"{tool} is required")
    run("gh", "auth", "status")
    if run("git", "status", "--porcelain"):
        raise ReleaseError("Working tree must be clean")
    if run("git", "branch", "--show-current") != "main":
        raise ReleaseError("Cut candidates from main")
    run("git", "fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
    if run("git", "rev-parse", "HEAD") != run("git", "rev-parse", "origin/main"):
        raise ReleaseError("main differs from origin/main; reconcile it before cutting")
    current, counter = versions()
    tags = remote_tags()
    latest = latest_tag(tags)
    version = os.environ.get("VERSION", "")
    if not version and (not latest or latest.split("/")[1] != current):
        raise ReleaseError("Pass VERSION=X.Y.Z for the first candidate of a version")
    version = version or current
    if version_tuple(version) < version_tuple(current):
        raise ReleaseError("VERSION cannot decrease")
    if latest:
        require_settled(GitHub(), tags)
    build = max(counter, int(latest.rsplit("/", 1)[1]) if latest else 0) + 1
    tag = f"builds/{version}/{build}"
    if subprocess.run(["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"]).returncode == 0:
        raise ReleaseError(f"Local {tag} already exists; inspect the previous push before proceeding")
    plugin = run("bash", "scripts/check-plugin-published.sh")
    changelog = cut_notes(Path("CHANGELOG.md").read_text(), version)
    print(f"TestFlight {version} ({build})\nTag: {tag}\nPlugin: {plugin}\n"
          f"Versions: {current} ({counter}) -> {version} ({build}) in all targets\n"
          "Files: project.yml, Heeler.xcodeproj/project.pbxproj, CHANGELOG.md\n"
          "Regenerate: xcodegen generate\n"
          f"Commit, then git push --atomic origin main refs/tags/{tag}\n"
          "GitHub Actions runs the full test gate, archives and uploads.\n\n"
          + notes_for(changelog, version))
    if not confirm():
        return
    # The confirmation prompt may have been open while somebody retried the
    # previous candidate. Recheck before beginning a new reservation.
    if latest:
        require_settled(GitHub(), remote_tags())
    Path("CHANGELOG.md").write_text(changelog)
    project = Path("project.yml")
    text = re.sub(r'(?m)^(\s*MARKETING_VERSION: )"[^"\n]+"$', rf'\g<1>"{version}"', project.read_text())
    text = re.sub(r'(?m)^(\s*CURRENT_PROJECT_VERSION: )"[^"\n]+"$', rf'\g<1>"{build}"', text)
    project.write_text(text)
    run("xcodegen", "generate")
    if versions() != (version, build):
        raise ReleaseError("Generated project versions do not match the plan")
    changed = set(run("git", "diff", "--name-only").splitlines())
    if not changed <= {*VERSION_FILES, "CHANGELOG.md"}:
        raise ReleaseError("Generation changed unexpected files; inspect local changes, nothing was committed")
    if latest:
        require_settled(GitHub(), remote_tags())
    run("git", "add", *VERSION_FILES, "CHANGELOG.md")
    run("git", "commit", "-m", f"chore: prepare testflight {version} ({build})")
    candidate = Candidate(tag, version, build, run("git", "rev-parse", "HEAD"), plugin)
    run("git", "tag", "-a", tag, "-m", json.dumps(asdict(candidate), sort_keys=True))
    try:
        run("git", "push", "--atomic", "origin", "main", f"refs/tags/{tag}")
    except ReleaseError as error:
        raise ReleaseError(f"{error}\nPush outcome may be unknown. Preserve the local commit/tag, "
                           "inspect remote main and tag before retrying. Never force or reuse the number.") from error
    print(f"Pushed {tag}; follow .github/workflows/release.yml. No App Store submission was made.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = {"cut": cut, "status": status, "retry": lambda: status(retry=True), "check": check,
                "ci-init": initialize, "ci-plan": plan, "ci-upload": upload, "ci-retry": automatic_retry,
                "ci-observe": observe, "ci-publish": publish_record, "ci-symbols": check_symbols}
    parser.add_argument("command", choices=commands)
    args = parser.parse_args()
    os.chdir(ROOT)
    try:
        commands[args.command]()
    except (ReleaseError, AppleError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"testflight: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
