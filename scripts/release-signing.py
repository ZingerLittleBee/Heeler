#!/usr/bin/env python3
"""Manual App Store signing for the release workflow (.github/workflows/release.yml).

The workflow archives the committed project with manual signing: a CI-only
Apple Distribution certificate in a throwaway keychain, plus one App Store
provisioning profile per signed target. Nothing here talks to Apple; uploads
use the App Store Connect API key in the workflow.

    install --dir DIR          keychain, profiles, signing.xcconfig, ExportOptions.plist
    verify-ipa IPA --version X.Y.Z --build N
    cleanup --dir DIR          remove the keychain and the installed profiles

`install` reads these environment variables:

    DISTRIBUTION_P12_BASE64, DISTRIBUTION_P12_PASSWORD   the .p12, chain included
    DISTRIBUTION_CERT_SHA1                               SHA-1 of that certificate
    PROFILE_APP_BASE64, PROFILE_NOTIFICATION_SERVICE_BASE64, PROFILE_WIDGETS_BASE64

Every profile is checked before anything is built: App Store type, this team
and bundle ID, not expired, containing the distribution certificate, and
carrying the entitlements the target needs. A wrong profile fails here with
its name instead of as an opaque xcodebuild or App Store Connect error.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime
import hashlib
import os
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "Heeler.xcodeproj" / "project.pbxproj"

TEAM_ID = "9VM4RM39R3"
APP_GROUP = "group.dev.bybee.heeler.shared"
KEYCHAIN_NAME = "heeler-signing.keychain-db"
PROFILE_DIRS = (
    # Xcode 16 and later read profiles here; older tools read the second path.
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
)


@dataclass(frozen=True)
class Target:
    name: str
    bundle_id: str
    profile_env: str
    bundle_path: str  # inside Payload/, in the exported IPA
    push: bool


TARGETS = (
    Target("Heeler", "dev.bybee.heeler", "PROFILE_APP_BASE64", "Heeler.app", True),
    Target(
        "HeelerNotificationService",
        "dev.bybee.heeler.NotificationService",
        "PROFILE_NOTIFICATION_SERVICE_BASE64",
        "Heeler.app/PlugIns/HeelerNotificationService.appex",
        False,
    ),
    Target(
        "HeelerWidgets",
        "dev.bybee.heeler.Widgets",
        "PROFILE_WIDGETS_BASE64",
        "Heeler.app/PlugIns/HeelerWidgets.appex",
        False,
    ),
)


class SigningError(Exception):
    pass


def run(*args: str, input: bytes | None = None) -> bytes:
    result = subprocess.run(args, input=input, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise SigningError(f"{args[0]} {args[1] if len(args) > 1 else ''} failed: {detail}")
    return result.stdout


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        raise SigningError(f"{name} is empty or not set")
    return value


def b64env(name: str) -> bytes:
    # `base64` output may be wrapped or end in a newline; any other stray
    # character is an error.
    try:
        return base64.b64decode("".join(env(name).split()), validate=True)
    except (binascii.Error, ValueError) as error:
        raise SigningError(f"{name} is not valid base64: {error}") from error


def check_project() -> None:
    """The constants above must describe the committed project."""
    text = PBXPROJ.read_text()
    teams = set(re.findall(r"DEVELOPMENT_TEAM = (\w+);", text))
    if teams != {TEAM_ID}:
        raise SigningError(f"{PBXPROJ.name} DEVELOPMENT_TEAM is {sorted(teams)}, expected {TEAM_ID}")
    bundle_ids = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([\w.]+);", text))
    for target in TARGETS:
        if target.bundle_id not in bundle_ids:
            raise SigningError(f"{PBXPROJ.name} has no target with bundle ID {target.bundle_id}")


# --- Profiles ------------------------------------------------------------------


def decode_profile(data: bytes) -> dict:
    with tempfile.NamedTemporaryFile(suffix=".mobileprovision") as handle:
        handle.write(data)
        handle.flush()
        return plistlib.loads(run("security", "cms", "-D", "-i", handle.name))


def check_profile(target: Target, profile: dict, cert_sha1: str) -> None:
    name = profile.get("Name", "?")
    where = f"{target.profile_env} ({name})"
    entitlements = profile.get("Entitlements", {})

    if profile.get("TeamIdentifier") != [TEAM_ID]:
        raise SigningError(f"{where} belongs to team {profile.get('TeamIdentifier')}, expected {TEAM_ID}")
    expected_app_id = f"{TEAM_ID}.{target.bundle_id}"
    if entitlements.get("application-identifier") != expected_app_id:
        raise SigningError(
            f"{where} is for {entitlements.get('application-identifier')}, expected {expected_app_id}"
        )
    # App Store profiles list no devices and do not allow debugging.
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        raise SigningError(f"{where} is a development or ad hoc profile, not App Store")
    if entitlements.get("get-task-allow"):
        raise SigningError(f"{where} allows get-task-allow, so it is not an App Store profile")

    expiry = profile.get("ExpirationDate")
    now = datetime.datetime.now(datetime.timezone.utc)
    if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
        raise SigningError(f"{where} expired on {expiry}")

    certs = {hashlib.sha1(der).hexdigest().upper() for der in profile.get("DeveloperCertificates", [])}
    if cert_sha1 not in certs:
        raise SigningError(f"{where} does not include the distribution certificate {cert_sha1}")

    if APP_GROUP not in entitlements.get("com.apple.security.application-groups", []):
        raise SigningError(f"{where} lacks the App Group {APP_GROUP}")
    if target.push and entitlements.get("aps-environment") != "production":
        raise SigningError(f"{where} has aps-environment {entitlements.get('aps-environment')!r}, expected production")


def install(directory: Path) -> None:
    check_project()
    directory.mkdir(parents=True, exist_ok=True)
    cert_sha1 = env("DISTRIBUTION_CERT_SHA1").strip().upper().replace(":", "")

    profiles: dict[str, dict] = {}
    raw: dict[str, bytes] = {}
    for target in TARGETS:
        data = b64env(target.profile_env)
        profile = decode_profile(data)
        check_profile(target, profile, cert_sha1)
        profiles[target.name] = profile
        raw[target.name] = data

    keychain = directory / KEYCHAIN_NAME
    password = secrets.token_urlsafe(32)
    p12 = directory / "distribution.p12"
    p12.write_bytes(b64env("DISTRIBUTION_P12_BASE64"))
    p12.chmod(0o600)
    try:
        run("security", "create-keychain", "-p", password, str(keychain))
        run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
        run("security", "unlock-keychain", "-p", password, str(keychain))
        # -x: the private key cannot be exported again; only codesign may
        # use it without a prompt.
        run(
            "security", "import", str(p12), "-k", str(keychain), "-f", "pkcs12",
            "-P", env("DISTRIBUTION_P12_PASSWORD"), "-x",
            "-T", "/usr/bin/codesign",
        )
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, str(keychain))
    finally:
        p12.unlink(missing_ok=True)

    # Xcode looks identities up through the user search list.
    current = [
        line.strip().strip('"')
        for line in run("security", "list-keychains", "-d", "user").decode().splitlines()
        if line.strip()
    ]
    (directory / "search-list").write_text("\n".join(current) + "\n")
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), *current)

    # -v lists only identities whose chain validates, so a .p12 exported
    # without the Apple WWDR intermediate fails here.
    identities = run("security", "find-identity", "-v", "-p", "codesigning", str(keychain)).decode()
    if cert_sha1 not in identities.upper():
        raise SigningError(
            f"the keychain has no valid signing identity {cert_sha1}; export the .p12 with its chain:\n{identities}"
        )

    installed = []
    for target in TARGETS:
        uuid = profiles[target.name]["UUID"]
        for profile_dir in PROFILE_DIRS:
            profile_dir.mkdir(parents=True, exist_ok=True)
            path = profile_dir / f"{uuid}.mobileprovision"
            path.write_bytes(raw[target.name])
            installed.append(str(path))
    (directory / "installed-profiles").write_text("\n".join(installed) + "\n")

    # Archive-time overrides: manual signing for the three signed targets,
    # nothing for package targets (TARGET_NAME expands to an unset setting).
    lines = [
        "// Generated by scripts/release-signing.py for one release run.",
        "CODE_SIGN_STYLE = Manual",
        f"DEVELOPMENT_TEAM = {TEAM_ID}",
        "CODE_SIGN_IDENTITY = Apple Distribution",
        f"OTHER_CODE_SIGN_FLAGS = --keychain {keychain}",
        "PROVISIONING_PROFILE_SPECIFIER = $(HEELER_PROFILE_$(TARGET_NAME))",
    ]
    lines += [f"HEELER_PROFILE_{t.name} = {profiles[t.name]['Name']}" for t in TARGETS]
    (directory / "signing.xcconfig").write_text("\n".join(lines) + "\n")

    export_options = {
        "method": "app-store-connect",
        "destination": "export",
        "teamID": TEAM_ID,
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "provisioningProfiles": {t.bundle_id: profiles[t.name]["Name"] for t in TARGETS},
        "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
    }
    with (directory / "ExportOptions.plist").open("wb") as handle:
        plistlib.dump(export_options, handle)

    for target in TARGETS:
        profile = profiles[target.name]
        print(f"{target.name}: profile {profile['Name']!r} ({profile['UUID']}), expires {profile['ExpirationDate']:%Y-%m-%d}")
    print(f"identity {cert_sha1} in {keychain}")


# --- Exported IPA ---------------------------------------------------------------


def entitlements_of(bundle: Path) -> dict:
    data = run("codesign", "-d", "--entitlements", "-", "--xml", str(bundle))
    return plistlib.loads(data) if data.strip() else {}


def verify_ipa(ipa: Path, version: str, build: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        # ditto keeps the executable bits that codesign --verify needs.
        run("ditto", "-x", "-k", str(ipa), tmp)
        payload = Path(tmp) / "Payload"
        run("codesign", "--verify", "--deep", "--strict", str(payload / "Heeler.app"))
        for target in TARGETS:
            bundle = payload / target.bundle_path
            if not bundle.is_dir():
                raise SigningError(f"{ipa.name} has no {target.bundle_path}")
            with (bundle / "Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
            if info.get("CFBundleIdentifier") != target.bundle_id:
                raise SigningError(f"{target.bundle_path} is {info.get('CFBundleIdentifier')}, expected {target.bundle_id}")
            shown = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
            if shown != (version, build):
                raise SigningError(f"{target.bundle_path} is version {shown}, expected {(version, build)}")

            ents = entitlements_of(bundle)
            if ents.get("application-identifier") != f"{TEAM_ID}.{target.bundle_id}":
                raise SigningError(f"{target.bundle_path} is signed for {ents.get('application-identifier')}")
            if ents.get("get-task-allow"):
                raise SigningError(f"{target.bundle_path} is signed with get-task-allow")
            if APP_GROUP not in ents.get("com.apple.security.application-groups", []):
                raise SigningError(f"{target.bundle_path} lacks the App Group {APP_GROUP}")
            if target.push and ents.get("aps-environment") != "production":
                raise SigningError(f"{target.bundle_path} has aps-environment {ents.get('aps-environment')!r}")
            print(f"{target.bundle_path}: {target.bundle_id} {version} ({build}), entitlements OK")


# --- Cleanup ----------------------------------------------------------------------


def cleanup(directory: Path) -> None:
    search_list = directory / "search-list"
    if search_list.exists():
        keychains = [line for line in search_list.read_text().splitlines() if line]
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *keychains], check=False)
    keychain = directory / KEYCHAIN_NAME
    if keychain.exists():
        subprocess.run(["security", "delete-keychain", str(keychain)], check=False)
    installed = directory / "installed-profiles"
    if installed.exists():
        for line in installed.read_text().splitlines():
            if line:
                Path(line).unlink(missing_ok=True)
    shutil.rmtree(directory, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "cleanup"):
        command = commands.add_parser(name)
        command.add_argument("--dir", type=Path, required=True)
    verify = commands.add_parser("verify-ipa")
    verify.add_argument("ipa", type=Path)
    verify.add_argument("--version", required=True)
    verify.add_argument("--build", required=True)
    args = parser.parse_args()

    try:
        if args.command == "install":
            install(args.dir)
        elif args.command == "verify-ipa":
            verify_ipa(args.ipa, args.version, args.build)
        else:
            cleanup(args.dir)
    except SigningError as error:
        print(f"release-signing: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
