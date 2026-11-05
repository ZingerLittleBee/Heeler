"""App Store Connect with the Team API key: the read-only upload inventory, and
external TestFlight distribution of a processed build."""

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


API = "https://api.appstoreconnect.apple.com/v1/"


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


@dataclass(frozen=True)
class BetaBuild:
    id: str
    processing_state: str
    external_state: str
    groups: frozenset[str]
    # Locale to (betaBuildLocalization id, What to Test).
    whats_new: dict[str, tuple[str, str]]


@dataclass(frozen=True)
class GroupBuild:
    version: str
    number: int


def detail(error: HTTPError) -> str:
    try:
        return ": " + json.loads(error.read())["errors"][0]["detail"]
    except (ValueError, KeyError, IndexError, TypeError):
        return ""


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

    def pages(self, path: str, query: dict, subject="Apple inventory", stop="; no upload is authorized"):
        url = API + path + "?" + urlencode(query)
        while url:
            if urlsplit(url).scheme != "https" or urlsplit(url).netloc != "api.appstoreconnect.apple.com":
                raise AppleError("Unexpected Apple pagination origin")
            request = Request(url, headers={"Authorization": "Bearer " + self.authorization()})
            try:
                with urlopen(request, timeout=60) as response:
                    page = json.load(response)
            except HTTPError as error:
                raise AppleError(f"{subject} request failed (HTTP {error.code}){detail(error)}{stop}") from error
            except URLError as error:
                raise AppleError(f"{subject} is unavailable{stop}") from error
            yield page
            url = page.get("links", {}).get("next")

    def app_id(self, bundle_id: str, **failure) -> str:
        apps = [app for page in self.pages("apps", {"filter[bundleId]": bundle_id, "limit": 2}, **failure)
                for app in page["data"]]
        if len(apps) != 1 or apps[0]["attributes"]["bundleId"] != bundle_id:
            raise AppleError("Expected exactly one Apple app with the candidate bundle ID")
        return apps[0]["id"]

    def inventory(self, bundle_id: str, version: str, number: int) -> Inventory:
        app_id = self.app_id(bundle_id)
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

    # External TestFlight distribution. Reads fail without the upload wording.
    BETA = {"subject": "App Store Connect", "stop": ""}

    def external_group(self, app_id: str, name: str) -> str:
        groups = [group for page in self.pages("betaGroups", {"filter[app]": app_id, "limit": 200}, **self.BETA)
                  for group in page["data"] if not group["attributes"]["isInternalGroup"]]
        named = [group["id"] for group in groups if group["attributes"]["name"] == name]
        if len(named) != 1:
            names = ", ".join(sorted(group["attributes"]["name"] for group in groups)) or "none"
            raise AppleError(f"Expected one external TestFlight group named {name!r}; external groups: {names}")
        return named[0]

    def beta_build(self, app_id: str, version: str, number: int) -> BetaBuild:
        pages = list(self.pages("builds", {
            "filter[app]": app_id, "filter[version]": str(number), "filter[preReleaseVersion.version]": version,
            "filter[preReleaseVersion.platform]": "IOS", "include": "buildBetaDetail,betaBuildLocalizations,betaGroups",
            "limit[betaBuildLocalizations]": 50, "limit[betaGroups]": 50, "limit": 2}, **self.BETA))
        builds = [build for page in pages for build in page["data"]]
        if len(builds) != 1:
            raise AppleError(f"Expected one Apple build {version} ({number}); found {len(builds)}")
        included = {(item["type"], item["id"]): item["attributes"] for page in pages for item in page.get("included", [])}
        relationships = builds[0]["relationships"]
        beta = included[("buildBetaDetails", relationships["buildBetaDetail"]["data"]["id"])]
        whats_new = {}
        for reference in relationships["betaBuildLocalizations"]["data"]:
            localization = included[("betaBuildLocalizations", reference["id"])]
            whats_new[localization["locale"]] = (reference["id"], localization.get("whatsNew") or "")
        return BetaBuild(builds[0]["id"], builds[0]["attributes"]["processingState"], beta["externalBuildState"],
                         frozenset(reference["id"] for reference in relationships["betaGroups"]["data"]), whats_new)

    def group_builds(self, app_id: str, group_id: str):
        """The group's builds, most recently uploaded first."""
        for page in self.pages("builds", {"filter[app]": app_id, "filter[betaGroups]": group_id,
                                          "include": "preReleaseVersion", "sort": "-uploadedDate", "limit": 50},
                               **self.BETA):
            versions = {item["id"]: item["attributes"]["version"] for item in page.get("included", [])
                        if item["type"] == "preReleaseVersions"}
            for build in page["data"]:
                yield GroupBuild(versions[build["relationships"]["preReleaseVersion"]["data"]["id"]],
                                 int(build["attributes"]["version"]))

    def send(self, method: str, path: str, body: dict) -> None:
        request = Request(API + path, data=json.dumps(body).encode(), method=method,
                          headers={"Authorization": "Bearer " + self.authorization(),
                                   "Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=60) as response:
                response.read()
        except HTTPError as error:
            raise AppleError(f"App Store Connect {method} {path} failed (HTTP {error.code}){detail(error)}") from error
        except URLError as error:
            raise AppleError(f"App Store Connect is unavailable; {method} {path} may have applied") from error

    def set_whats_new(self, build: BetaBuild, locale: str, text: str) -> None:
        if locale in build.whats_new:
            identity = build.whats_new[locale][0]
            self.send("PATCH", f"betaBuildLocalizations/{identity}", {"data": {
                "type": "betaBuildLocalizations", "id": identity, "attributes": {"whatsNew": text}}})
        else:
            self.send("POST", "betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build.id}}}}})

    def add_to_group(self, group_id: str, build_id: str) -> None:
        self.send("POST", f"betaGroups/{group_id}/relationships/builds", {"data": [{"type": "builds", "id": build_id}]})

    def submit_for_review(self, build_id: str) -> None:
        self.send("POST", "betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
