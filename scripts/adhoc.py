#!/usr/bin/env python3
"""Export a local Ad Hoc IPA and prepare a static installation page."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import importlib.util
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parent.parent

# Share the app/extension inventory and signed-bundle checks with App Store
# exports. Ad Hoc adds device-list/profile checks without changing that lane.
spec = importlib.util.spec_from_file_location("release_signing", ROOT / "scripts/release-signing.py")
signing = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = signing
spec.loader.exec_module(signing)


class AdHocError(Exception):
    pass


@dataclass(frozen=True)
class Package:
    version: str
    build: str
    device_count: int
    expires: str
    sha256: str


def base_url(value: str) -> str:
    """Accept an HTTPS directory, without credentials or ambiguous URL parts."""
    if not value:
        return ""
    if any(char.isspace() or ord(char) < 32 for char in value) or "\\" in value:
        raise AdHocError("ADHOC_URL must be an HTTPS directory URL without whitespace")
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment):
        raise AdHocError("ADHOC_URL must be an HTTPS directory URL without credentials, query or fragment")
    # Validate the port even though urlsplit otherwise accepts malformed ports.
    parsed.port
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/") + "/", "", ""))


def check_profile(target, profile: dict) -> tuple[set[str], dt.datetime]:
    label = target.bundle_id
    ents = profile.get("Entitlements", {})
    if profile.get("TeamIdentifier") != [signing.TEAM_ID]:
        raise AdHocError(f"{label}: provisioning profile belongs to another team")
    if ents.get("application-identifier") != f"{signing.TEAM_ID}.{label}":
        raise AdHocError(f"{label}: provisioning profile has the wrong application identifier")
    devices = profile.get("ProvisionedDevices")
    if (not isinstance(devices, list) or not devices
            or not all(isinstance(device, str) and device for device in devices)
            or profile.get("ProvisionsAllDevices") or ents.get("get-task-allow") is not False):
        raise AdHocError(f"{label}: expected an Ad Hoc profile with registered devices and debugging disabled")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, dt.datetime):
        raise AdHocError(f"{label}: provisioning profile has no expiration date")
    expires = expires.replace(tzinfo=dt.timezone.utc)
    if expires <= dt.datetime.now(dt.timezone.utc):
        raise AdHocError(f"{label}: provisioning profile has expired")
    return {device.upper() for device in devices}, expires


def inspect_ipa(ipa: Path, udid: str = "") -> Package:
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read("Payload/Heeler.app/Info.plist"))
        version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
        if not all(isinstance(value, str) and value for value in (version, build)):
            raise AdHocError("IPA has no version/build identity")
        devices: set[str] | None = None
        expirations = []
        for target in signing.TARGETS:
            raw = archive.read(f"Payload/{target.bundle_path}/embedded.mobileprovision")
            supported, expires = check_profile(target, signing.decode_profile(raw))
            devices = supported if devices is None else devices & supported
            expirations.append(expires)
        if not devices:
            raise AdHocError("The app and extensions have no registered device in common")
        if udid and udid.upper() not in devices:
            raise AdHocError("ADHOC_UDID is not provisioned in every app/extension profile")
    signing.verify_ipa(ipa, version, build)
    digest = hashlib.sha256()
    with ipa.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return Package(version, build, len(devices), min(expirations).isoformat(), digest.hexdigest())


def write_page(site: Path, package: Package, url: str) -> None:
    manifest_path = site / "manifest.plist"
    if url:
        manifest = {"items": [{
            "assets": [{"kind": "software-package", "url": url + "Heeler.ipa"}],
            "metadata": {
                "bundle-identifier": signing.TARGETS[0].bundle_id,
                "bundle-version": package.build,
                "kind": "software", "title": "Heeler",
            },
        }]}
        manifest_path.write_bytes(plistlib.dumps(manifest))
        install = "itms-services://?action=download-manifest&url=" + quote(url + "manifest.plist", safe="")
        action = f'<a class="button" href="{html.escape(install, quote=True)}">Install Heeler</a>'
        hint = "Open this page in Safari on your registered iPhone or iPad."
    else:
        manifest_path.unlink(missing_ok=True)
        action = '<button disabled>Installation not available yet</button>'
        hint = "The download address for this build has not been configured."
    site.joinpath("index.html").write_text(f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install Heeler</title>
<style>
:root {{ color-scheme: light dark; font: 17px/1.6 system-ui, sans-serif; }}
body {{ max-width: 32rem; margin: 12vh auto; padding: 0 1.5rem; }}
h1 {{ line-height: 1.2; }}
.button, button {{ display: inline-block; padding: .8rem 1.2rem; border-radius: .7rem;
  border: 0; font: inherit; background: #185adb; color: white; text-decoration: none; }}
button:disabled {{ background: #666; color: white; }}
a:focus-visible {{ outline: 3px solid currentColor; outline-offset: 4px; }}
small {{ display: block; margin-top: 2rem; }}
</style>
<main>
<h1>Heeler</h1>
<p>Version {html.escape(package.version)} · Build {html.escape(package.build)}</p>
<p>{hint}</p>
{action}
<small>Available only to registered devices. This replaces an existing Heeler installation.
Keep the existing app installed to preserve its data.</small>
</main>
</html>
""", encoding="utf-8")


def prepare(directory: Path, url: str, udid: str) -> None:
    # Validate before changing existing installation links.
    package = inspect_ipa(directory / "site/Heeler.ipa", udid)
    finish(directory, package, url, udid)


def finish(directory: Path, package: Package, url: str, udid: str) -> None:
    site = directory / "site"
    ipa = site / "Heeler.ipa"
    write_page(site, package, url)
    directory.joinpath("package.json").write_text(json.dumps({
        "bundle_id": signing.TARGETS[0].bundle_id,
        "version": package.version, "build": package.build,
        "sha256": package.sha256, "registered_device_count": package.device_count,
        "profiles_expire_at": package.expires, "requested_device_verified": bool(udid),
        "base_url": url,
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Verified Ad Hoc IPA: {ipa}")
    print(f"Common registered devices: {package.device_count}; profiles expire: {package.expires}")
    if not udid:
        print("No particular phone checked. Set ADHOC_UDID to verify your phone before hosting.")
    print(f"Installation page: {site / 'index.html'}")
    if url:
        print(f"After hosting the site directory, open: {url}")
    else:
        print("No hosting configured; no installation manifest was emitted.")
    print("Reconfigure links without rebuilding:")
    print(shlex.join(["make", "adhoc-page", f"ADHOC_DIR={directory}", "ADHOC_URL=https://your-host.example/build/"]))


def export_options() -> dict:
    return {
        "method": "release-testing", "destination": "export",
        "signingStyle": "automatic", "teamID": signing.TEAM_ID,
        "manageAppVersionAndBuildNumber": False, "thinning": "<none>",
    }


def build(url: str, udid: str, dry_run: bool) -> None:
    signing.check_project()
    if dry_run:
        print("Plan: archive the current checkout (Release, generic iOS), export release-testing,")
        print("verify signed app/extensions and Ad Hoc profiles, then generate a local site.")
        print("Output: build/adhoc/<unique-build>/; no connected device is needed.")
        print("Uses Xcode automatic signing; provisioning assets may be created or updated. No app uploads.")
        print("Export options: " + json.dumps(export_options(), sort_keys=True))
        print("Installation URL: " + (url or "not configured"))
        return
    parent = ROOT / "build/adhoc"
    parent.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    directory = Path(tempfile.mkdtemp(prefix=stamp, dir=parent))
    print(f"Build directory: {directory}", flush=True)
    archive = directory / "Heeler.xcarchive"
    options = directory / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps(export_options()))
    revision = signing.run("sh", str(ROOT / "scripts/source-revision.sh")).decode().strip()
    commands = [
        ("generate", ["make", "generate"]),
        ("archive", ["xcodebuild", "-project", "Heeler.xcodeproj", "-scheme", "Heeler",
                     "-configuration", "Release", "-destination", "generic/platform=iOS",
                     "-derivedDataPath", str(ROOT / "build/DerivedData-adhoc"),
                     "-archivePath", str(archive), "-allowProvisioningUpdates",
                     f"HEELER_SOURCE_REVISION={revision}", "archive"]),
        ("export", ["xcodebuild", "-exportArchive", "-archivePath", str(archive),
                    "-exportPath", str(directory / "export"), "-exportOptionsPlist", str(options),
                    "-allowProvisioningUpdates"]),
    ]
    for name, command in commands:
        log = directory / f"{name}.log"
        print(f"{name}: {log}", flush=True)
        with log.open("w") as handle:
            result = subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT)
        if result.returncode:
            raise AdHocError(f"{name} failed ({result.returncode}); see {log}")
    ipas = list((directory / "export").glob("*.ipa"))
    if len(ipas) != 1:
        raise AdHocError("Expected exactly one universal IPA in the export directory")
    # Keep build logs, archives and export diagnostics outside the hosting root.
    # Verify before making any IPA available under site/.
    package = inspect_ipa(ipas[0], udid)
    site = directory / "site"
    site.mkdir()
    shutil.copyfile(ipas[0], site / "Heeler.ipa")
    finish(directory, package, url, udid)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "page"))
    args = parser.parse_args()
    try:
        url = base_url(os.environ.get("ADHOC_URL", ""))
        udid = os.environ.get("ADHOC_UDID", "").strip()
        if args.command == "build":
            build(url, udid, os.environ.get("DRY_RUN") == "1")
        else:
            value = os.environ.get("ADHOC_DIR", "")
            if not value:
                raise AdHocError("ADHOC_DIR must name a previous build/adhoc/<unique-build> directory")
            prepare(Path(value).resolve(), url, udid)
    except (AdHocError, signing.SigningError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"adhoc: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
