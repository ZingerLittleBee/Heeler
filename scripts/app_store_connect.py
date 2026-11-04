"""Read-only App Store Connect inventory using the existing Team API key."""

from __future__ import annotations

import base64
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


class AppleError(Exception):
    pass


@dataclass(frozen=True)
class AppleBuild:
    id: str
    version: str
    number: int
    state: str


@dataclass(frozen=True)
class Inventory:
    selected: AppleBuild | None
    highest_number: int
    closed: bool


def encoded(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


class AppStoreConnect:
    def __init__(self):
        self.token = ""
        self.expires = 0

    def authorization(self) -> str:
        now = int(time.time())
        if self.expires > now + 60:
            return self.token
        required = ("ASC_API_KEY_ID", "ASC_API_ISSUER_ID", "ASC_API_KEY_P8")
        if any(not os.environ.get(key) for key in required):
            raise AppleError("App Store Connect Team API credentials are missing")
        header = {"alg": "ES256", "kid": os.environ["ASC_API_KEY_ID"], "typ": "JWT"}
        claims = {"iss": os.environ["ASC_API_ISSUER_ID"], "iat": now,
                  "exp": now + 600, "aud": "appstoreconnect-v1"}
        message = encoded(json.dumps(header).encode()) + "." + encoded(json.dumps(claims).encode())
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "AuthKey.p8"
            key.write_text(os.environ["ASC_API_KEY_P8"])
            key.chmod(0o600)
            result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)],
                                    input=message.encode(), capture_output=True)
        if result.returncode:
            raise AppleError("Could not sign the App Store Connect JWT")
        # OpenSSL emits the short-form DER sequence of two P-256 integers.
        # JOSE uses their unsigned, fixed-width concatenation instead.
        der = result.stdout
        if len(der) < 6 or der[0] != 0x30 or der[1] != len(der) - 2:
            raise AppleError("Expected a P-256 DER signature")
        offset, integers = 2, []
        for _ in range(2):
            if offset + 2 > len(der) or der[offset] != 2:
                raise AppleError("Invalid P-256 signature integer")
            length = der[offset + 1]
            value = der[offset + 2:offset + 2 + length]
            if len(value) != length or not 1 <= length <= 33:
                raise AppleError("Invalid P-256 signature length")
            integers.append(int.from_bytes(value, "big").to_bytes(32, "big"))
            offset += 2 + length
        if offset != len(der):
            raise AppleError("Invalid P-256 signature tail")
        self.token = message + "." + encoded(b"".join(integers))
        self.expires = now + 600
        return self.token

    def pages(self, path: str, query: dict):
        url = "https://api.appstoreconnect.apple.com/v1/" + path + "?" + urlencode(query)
        while url:
            if urlsplit(url).scheme != "https" or urlsplit(url).netloc != "api.appstoreconnect.apple.com":
                raise AppleError("Unexpected Apple pagination origin")
            request = Request(url, headers={"Authorization": "Bearer " + self.authorization()})
            try:
                with urlopen(request, timeout=60) as response:
                    page = json.load(response)
            except HTTPError as error:
                raise AppleError(f"Apple inventory request failed (HTTP {error.code}); no upload is authorized") from error
            except URLError as error:
                raise AppleError("Apple inventory is unavailable; no upload is authorized") from error
            yield page
            url = page.get("links", {}).get("next")

    def inventory(self, bundle_id: str, version: str, number: int) -> Inventory:
        apps = [app for page in self.pages("apps", {"filter[bundleId]": bundle_id, "limit": 2}) for app in page["data"]]
        if len(apps) != 1 or apps[0]["attributes"]["bundleId"] != bundle_id:
            raise AppleError("Expected exactly one Apple app with the candidate bundle ID")
        app_id = apps[0]["id"]
        highest, selected = 0, None
        for page in self.pages("builds", {"filter[app]": app_id, "filter[preReleaseVersion.platform]": "IOS",
                                          "include": "preReleaseVersion", "limit": 200}):
            versions = {item["id"]: item["attributes"] for item in page.get("included", [])
                        if item["type"] == "preReleaseVersions"}
            for build in page["data"]:
                pre = versions[build["relationships"]["preReleaseVersion"]["data"]["id"]]
                if pre["platform"] != "IOS":
                    continue
                value = build["attributes"]["version"]
                if not value.isdecimal():
                    raise AppleError("Noninteger Apple build number; reconcile the counter before migration")
                highest = max(highest, int(value))
                if pre["version"] == version and int(value) == number:
                    if selected is not None:
                        raise AppleError("Ambiguous Apple build identity")
                    selected = AppleBuild(build["id"], version, number, build["attributes"]["processingState"])
        closed = False
        for page in self.pages(f"apps/{app_id}/appStoreVersions", {"filter[platform]": "IOS", "limit": 200}):
            for item in page["data"]:
                attributes = item["attributes"]
                if attributes["versionString"] == version and attributes.get("appVersionState") in (
                    "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION"):
                    closed = True
        return Inventory(selected, highest, closed)
