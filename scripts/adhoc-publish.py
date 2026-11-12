#!/usr/bin/env python3
"""Verify an Ad Hoc export, publish it, and verify its remote bytes."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import zipfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import adhoc

ROOT = Path(__file__).resolve().parent.parent
FILES = (("Heeler.ipa", "application/octet-stream"),
         ("manifest.plist", "application/xml"), ("index.html", "text/html"))
MAX_IPA = 90 * 1024 * 1024


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward the upload credential or installation URL elsewhere.
        return None


def origin(value: str) -> str:
    value = adhoc.base_url(value)
    if not value or urlsplit(value).path != "/":
        raise adhoc.AdHocError("ADHOC_PUBLISH_URL must be an HTTPS origin without a path")
    return value.rstrip("/")


def token() -> str:
    value = os.environ.get("ADHOC_UPLOAD_TOKEN", "")
    if not value and sys.platform == "darwin":
        result = subprocess.run(["security", "find-generic-password", "-s", "heeler-adhoc",
                                 "-a", "upload-token", "-w"], capture_output=True, text=True)
        if result.returncode == 0:
            value = result.stdout.strip()
    if not value:
        raise adhoc.AdHocError("Set ADHOC_UPLOAD_TOKEN or the heeler-adhoc/upload-token Keychain item")
    return value


def input_ipa() -> Path:
    explicit = os.environ.get("ADHOC_IPA", "")
    if explicit:
        return Path(explicit).resolve()
    path = os.environ.get("CI_AD_HOC_SIGNED_APP_PATH", "")
    if not path:
        raise adhoc.AdHocError("Set ADHOC_IPA or run after an Xcode Cloud Ad Hoc archive")
    ipas = list(Path(path).rglob("*.ipa"))
    if len(ipas) != 1:
        raise adhoc.AdHocError("Expected exactly one IPA in CI_AD_HOC_SIGNED_APP_PATH")
    return ipas[0].resolve()


def upload(opener, url: str, path: Path, mime: str, credential: str) -> None:
    data = path.read_bytes()
    request = Request(url, data=data, method="PUT", headers={
        "Authorization": "Bearer " + credential,
        "Content-Type": mime, "X-File-SHA256": hashlib.sha256(data).hexdigest(),
    })
    for attempt in range(3):
        try:
            with opener.open(request, timeout=120) as response:
                if response.status not in (201, 204):
                    raise adhoc.AdHocError(f"Unexpected upload status for {path.name}")
            return
        except HTTPError as error:
            error.close()
            if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise adhoc.AdHocError(f"Upload of {path.name} failed (HTTP {error.code})") from None
        except (URLError, TimeoutError):
            if attempt == 2:
                raise adhoc.AdHocError(f"Upload of {path.name} failed; retry the same directory") from None
        time.sleep(attempt + 1)


def verify_remote(opener, url: str, path: Path, mime: str) -> None:
    digest = hashlib.sha256()
    size = 0
    try:
        with opener.open(url, timeout=120) as response:
            if response.status != 200 or response.headers.get_content_type() != mime:
                raise adhoc.AdHocError(f"Wrong remote status or content type for {path.name}")
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
    except (URLError, TimeoutError) as error:
        if isinstance(error, HTTPError):
            error.close()
        raise adhoc.AdHocError(f"Remote verification failed for {path.name}") from None
    if size != path.stat().st_size or digest.hexdigest() != hashlib.sha256(path.read_bytes()).hexdigest():
        raise adhoc.AdHocError(f"Remote bytes differ for {path.name}")


def publish(ipa: Path, base: str, credential: str, directory: Path | None = None) -> str:
    base = origin(base)
    if ipa.stat().st_size > MAX_IPA:
        raise adhoc.AdHocError("IPA exceeds the download service's 90 MiB upload limit")
    udid = os.environ.get("ADHOC_UDID", "").strip()
    package = adhoc.inspect_ipa(ipa, udid)
    directory = directory or ROOT / "build/adhoc" / f"publish-{package.sha256[:16]}"
    directory.mkdir(parents=True, exist_ok=True)
    receipt = directory / "deployment.json"
    if receipt.exists():
        deployment = json.loads(receipt.read_text())
        if deployment.get("sha256") != package.sha256 or deployment.get("origin") != base:
            raise adhoc.AdHocError("Deployment directory belongs to a different IPA or origin")
        identifier = deployment.get("id", "")
        if len(identifier) != 32 or any(c not in "0123456789abcdef" for c in identifier):
            raise adhoc.AdHocError("Invalid saved deployment identifier")
    else:
        identifier = secrets.token_hex(16)
        deployment = {"id": identifier, "sha256": package.sha256, "origin": base,
                      "source_commit": os.environ.get("CI_COMMIT", ""),
                      "cloud_build_url": os.environ.get("CI_BUILD_URL", "")}
        receipt.write_text(json.dumps(deployment, indent=2) + "\n")
    url = f"{base}/b/{identifier}/"
    site = directory / "site"
    site.mkdir(exist_ok=True)
    if ipa.resolve() != (site / "Heeler.ipa").resolve():
        shutil.copyfile(ipa, site / "Heeler.ipa")
    adhoc.finish(directory, package, url, udid)
    opener = build_opener(NoRedirect())
    # Cloudflare rejects Python's generic default agent before Worker routing.
    opener.addheaders = [("User-Agent", "Heeler-AdHoc/1.0")]
    # Publish the entry page last. Never upload archives, logs or device lists.
    for name, mime in FILES:
        upload(opener, url + name, site / name, mime, credential)
        verify_remote(opener, url + name, site / name, mime)
        print(f"Published and verified: {name}", flush=True)
    deployment["installation_url"] = url
    receipt.write_text(json.dumps(deployment, indent=2) + "\n")
    print(f"Install Heeler: {url}", flush=True)
    return url


def main() -> int:
    try:
        configured = ROOT / "adhoc-host/deployment.json"
        base = os.environ.get("ADHOC_PUBLISH_URL", "")
        if not base and configured.exists():
            base = json.loads(configured.read_text())["origin"]
        directory = os.environ.get("ADHOC_DIR", "")
        publish(input_ipa(), base, token(), Path(directory).resolve() if directory else None)
        return 0
    except (adhoc.AdHocError, adhoc.signing.SigningError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"adhoc-publish: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
