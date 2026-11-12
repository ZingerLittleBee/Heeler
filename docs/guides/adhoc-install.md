# Ad Hoc installation

## Xcode Cloud to Cloudflare

The **Ad Hoc** Xcode Cloud workflow is a manually triggered iOS Archive using
the committed `Heeler` scheme. Select the branch to build in Xcode's Cloud
navigator. A branch must be pushed before Cloud can build it. The workflow
keeps Distribution Preparation set to **None** and has no TestFlight post-action.

On a successful archive, executable `ci_scripts/ci_post_xcodebuild.sh` runs
`make adhoc-publish`. It reads Apple's `CI_AD_HOC_SIGNED_APP_PATH`, verifies the
IPA and all embedded provisioning profiles, uploads to the Cloudflare service,
and verifies each downloaded file against its local bytes. The final
`Install Heeler: https://.../b/<random-id>/` line in the post-build log is the
installation link. Open it in Safari on a registered iPhone or iPad.

Configure these variables on this workflow only:

| Variable | Secret | Purpose |
| --- | --- | --- |
| `ADHOC_PUBLISH_URL` | No | HTTPS origin from `adhoc-host/deployment.json` |
| `ADHOC_UPLOAD_TOKEN` | Yes | Dedicated upload credential matching the Worker's `UPLOAD_TOKEN` |
| `ADHOC_UDID` | Yes | Optional device ID that must appear in every embedded profile |

The hook skips other actions, failed archives and workflows without
`ADHOC_PUBLISH_URL`. Once opted in, a missing credential, invalid signature,
unsupported device, failed upload or failed download check fails the script.
This must not be treated as a successfully published build. A failed publication
does not imply the archive failed; its signed export remains available in Cloud
artifacts and can be republished locally without rebuilding.

### Publish an existing signed export

```sh
make adhoc-publish ADHOC_IPA=/path/to/Heeler.ipa
```

The origin defaults to the checked-in deployment configuration. Locally, the
credential comes from `ADHOC_UPLOAD_TOKEN` or the macOS Keychain generic-password
item with service `heeler-adhoc` and account `upload-token`. Never put credentials
in a command argument, Makefile, plist, repository file or log.

Local publication output lives in `build/adhoc/publish-<ipa-sha-prefix>/`;
`ADHOC_DIR` can select another output directory. `deployment.json` retains the
random installation URL and digest, so rerunning the same command resumes the
same publication. The service accepts matching retries and rejects replacing an
existing object with different content. IPA, manifest and page upload in that
order; the entry page appears last. A different IPA or origin requires a new
output directory. Publication does not change the IPA's version or build number.

### Download service

`adhoc-host/` contains a small Worker bound to the private `heeler-adhoc` R2
bucket. This avoids the Workers static asset limit of 25 MiB per file; the
publisher currently limits IPAs to 90 MiB. It serves only `Heeler.ipa`,
`manifest.plist` and `index.html` under 128-bit random build paths, with HTTPS,
correct MIME types, HEAD and single byte-range support. There is no bucket
listing, latest-build pointer, public archive or log download. The R2 bucket's
public access stays disabled. Uploads need the separate Worker secret and cannot
delete or overwrite builds. Request observability is disabled to keep private
installation paths out of request logs.

Anyone possessing an installation link can download its IPA; the IPA embeds
registered-device identifiers. Keep links private. iOS installation still
requires a device included in every profile. These are bearer links, not an
interactive-login system: the iOS installer cannot reuse Safari login cookies.
Existing links remain available until an operator removes their objects from
R2; provisioning expiry separately limits installation and use.

For infrastructure maintenance, use the pinned Wrangler from this directory:

```sh
cd adhoc-host
pnpm install --frozen-lockfile
pnpm exec wrangler r2 bucket create heeler-adhoc # First setup only
pnpm run deploy
pnpm exec wrangler secret put UPLOAD_TOKEN
```

Deploy the Worker before the first `secret put` when creating a new service.
Keep any credential rotation synchronized with the Cloud workflow and local
Keychain. Use a new, narrowly scoped upload secret rather than putting a
Cloudflare account API token into Xcode Cloud. R2 storage and Worker requests
consume the account's normal quotas; no paid plan is enabled by these commands.

References: Apple's [archive environment variables](https://developer.apple.com/documentation/xcode/environment-variable-reference),
[custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts),
Cloudflare's [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
and [R2 Worker API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/).

## Local export

Use Ad Hoc to install the current checkout on registered iPhones or iPads without
a live Xcode connection. This is separate from TestFlight and works on a feature
branch or a dirty checkout. It neither reserves a release build number nor uploads
anything. It uses the project's current version and build number.

## Signing prerequisites

The Mac needs Xcode, XcodeGen, and an account signed in to Xcode with permission
to manage signing for the project's team. The intended devices must already be
registered in that team's Apple Developer account.

Both archive and export use `-allowProvisioningUpdates`, matching the previous
local TestFlight flow. Xcode may create, download or update signing certificates,
app identifiers and provisioning profiles. The tool does not require an Apple
Distribution private key to already exist in the local Keychain: Xcode decides
whether local or cloud-managed signing is available to the account. It does not
pass `-allowProvisioningDeviceRegistration` or register the optional `ADHOC_UDID`.

Ad Hoc profiles must cover all three bundle identifiers:
`dev.bybee.heeler`, `dev.bybee.heeler.NotificationService`, and
`dev.bybee.heeler.Widgets`, with the shared App Group and production push for the
main app. Xcode manages these profiles automatically. New devices require updated
profiles and a new export. An archive/export failure points to its retained Xcode
log; missing local distribution identities alone are not treated as a failure.
See Apple's [registered-device distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).

## Build without choosing a host

```sh
make adhoc DRY_RUN=1
make adhoc
# Optional: fail if this device is not supported by every embedded profile.
make adhoc ADHOC_UDID=<registered-device-udid>
```

No phone needs to be connected. The tool regenerates the Xcode project, archives
Release for generic iOS and exports with Xcode's `release-testing` method (the
current name for `ad-hoc`). It checks the signed app and both extensions, their
bundle identifiers, matching versions, App Group and production push entitlement,
and unexpired Ad Hoc profiles. The device lists must have a nonempty intersection;
`ADHOC_UDID` must belong to that intersection when supplied. Without it, the output
reports the common device count but does not claim your particular phone is covered.

Each invocation uses a new directory under `build/adhoc/` and prints its path:

```text
build/adhoc/<unique-build>/
  site/
    Heeler.ipa
    index.html
  package.json
  Heeler.xcarchive/
  ExportOptions.plist
  export/
  generate.log
  archive.log
  export.log
```

`package.json` records the IPA SHA-256, version/build, common device count and
earliest profile expiry. It contains no device list. The IPA itself necessarily
embeds profiles containing registered device identifiers. All output stays in
the ignored `build/` directory. Keep the archive and its dSYMs for crash diagnosis.
An unsuccessful build keeps diagnostics but produces no install-ready site.

Without `ADHOC_URL`, the page has a disabled installation button and there is no
manifest with a placeholder URL. You can inspect the page locally; it cannot
install the app yet.

## Configure the installation address later

Once you have chosen an HTTPS directory for this build:

```sh
make adhoc-page \
  ADHOC_DIR=build/adhoc/<unique-build> \
  ADHOC_URL=https://downloads.example.com/heeler/<unique-build>/ \
  ADHOC_UDID=<registered-device-udid>
```

This revalidates the IPA and rewrites only the page, `manifest.plist` and local
package summary, without rebuilding or changing the IPA. It also works with
`ADHOC_URL` omitted to remove old installation links. For subsequent builds you
may supply `ADHOC_URL` directly to `make adhoc`.

Host **only the contents of `site/`** at the exact directory URL, keeping the
filenames unchanged. Nothing is published by these commands. Use a distinct URL
per build to avoid cached manifests/packages. The host needs a TLS certificate
trusted by iOS and must serve both `manifest.plist` and `Heeler.ipa` to the phone's
installer without an interactive login or browser cookies. Serve `.plist` as
`application/xml` and `.ipa` as `application/octet-stream`. The HTML page links to
the manifest through `itms-services`; the manifest contains the absolute IPA URL.

Open that HTTPS page in **Safari on the registered phone** and tap Install Heeler.
The phone needs access to the download host, not to the building Mac. A private
Tailscale host requires the standalone Tailscale VPN app on the phone; Heeler's
in-app overlay cannot carry the system installer's downloads. Hosting and actual
device installation are separate acceptance steps from a successful local export.

This uses the same app identifier as the existing Heeler installation and can
replace it. Keep the existing app installed to retain its data; back up important
data before testing a build with incompatible storage changes. Ad Hoc profiles
expire, and these builds do not provide a connected debugger or automatic updates.

## Verification

`make test-adhoc` exercises the export orchestration with fake external signing
tools, real IPA/plist fixtures and real page generation. `make test-tools` includes
these tests. They do not prove Apple signing acceptance or installation on iOS;
those require a real export followed by a Safari installation on a registered
device. A dry run creates no files and does not access signing identities.
