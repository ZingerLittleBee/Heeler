# TestFlight builds and App Store publication

One upload path, one immutable tag per candidate. App Store publication selects
an existing TestFlight build in App Store Connect; it does not build again,
create another tag, or run another repository command.

```sh
make testflight VERSION=0.2.0 DRY_RUN=1 # inspect the first candidate plan
make testflight VERSION=0.2.0           # tag main as a build of the intended version
make testflight                         # another build of the same version
make testflight VERSION=0.2.1           # explicitly start the next version
make release-status TAG=builds/0.2.0/39
make testflight-retry TAG=builds/0.2.0/39
make release-check VERSION=0.2.0        # signing/validation rehearsal only
make testflight-notes TAG=builds/0.2.0/39  # changelog entries external testers have not had
make testflight-beta TAG=builds/0.2.0/39 NOTES=notes.txt  # release to external testers
```

Numbers are illustrative; migration must establish the real counter first.
Mutating commands print their plan and ask for confirmation. `YES=1` skips
only the prompt; `DRY_RUN=1` creates no tag, push, dispatch, or upload.
Options are make variables, not `--dry-run` (which make interprets as `-n`).
Requires Git, authenticated `gh` and Python 3.9+.

`make publish`, `make bump`, and `make upload` are retired and fail with an
explanation. They are not aliases: `make testflight` now pushes a tag and starts
CI instead of uploading from the local Mac. `make archive` remains available
for local inspection, and `make plugin` remains independent.

The implementation is [testflight.py](../../scripts/testflight.py) and
[release.yml](../../.github/workflows/release.yml). The rationale is
[ADR 0038](../adr/0038-testflight-build-tags.md), with builds that tag `main`
and run no tests from [ADR 0039](../adr/0039-release-builds-tag-main-without-tests.md);
the earlier [research](../research/app-store-build-tags.md) preserves the alternatives.

## Candidate identity and notes

`builds/X.Y.Z/N` is an annotated, immutable tag: `X.Y.Z` is the numeric Apple
marketing version and `N` is the actual integer Apple build number. Its JSON
annotation records bundle ID, platform, version, build, source commit, and
bundled plugin version. Historical `v*` tags retain their old meaning and stay
unchanged. A tag reserves a build; it does not prove an upload or store release.

The tag, not the committed project, names the version and build. The archive
passes both to all three signed targets, and the IPA check verifies each bundle.
`project.yml` and the Xcode project keep the values of the last build cut before
ADR 0039; they set local builds and stay a floor for the version and counter.
Heeler uses a global increasing build counter even though iOS allows different
marketing versions to have their own number sequences. Failed reservations
consume numbers. Never reuse a number or move a tag, including before upload.

`CHANGELOG.md` remains the notes source, and a cut never rewrites it. A build's
notes are its commit's `[Unreleased]` folded into one cumulative, undated
`## [X.Y.Z]` section for its version; its build record carries them. A rebuild
may have no new notes; a new version needs notes. Before starting a new version,
move the entries the newest build included from `[Unreleased]` under its
`## [X.Y.Z]` heading; the cut refuses until then. Duplicate categories/entries
or a historical section collision require explicit reconciliation. Each tag's
commit fixes its notes, so store metadata uses the selected build's notes, not
newer notes on `main`.

## Cutting a build

1. Require a clean `main` equal to freshly fetched `origin/main` and the plugin
   version already published on the `plugin` branch.
2. Require explicit `VERSION=X.Y.Z` for the first candidate. Thereafter an omitted
   version keeps the current one. Version downgrades and `BUILD` overrides fail.
3. Require preceding reservations to be settled. A running workflow, missing
   checkpoint, uncertain upload, or unfinished record blocks another cut.
   A completed pre-upload failure or Apple rejection permits a new candidate,
   provided it does not hide an older unresolved upload. So does a tag whose
   push run ended without its first job ever succeeding: that job saves the
   checkpoint and every later job needs it, so the tag is void.
4. Refuse the commit the newest build already has, unless that tag is void or
   its binary was rejected. A pre-upload failure is retried with
   `make testflight-retry`; otherwise merge a change or pass a new `VERSION`.
5. Allocate one above the maximum committed counter and all well-formed remote
   build-tag numbers. Print the tag, commit, plugin version and notes.
6. After confirmation, recheck settlement, annotate the tag on the `main` commit
   and push only the tag, without force. Nothing is committed. Preserve the
   local tag and inspect remote tags if the push response is lost; do not
   assume that nothing reached GitHub.

No tests run when cutting or in the release workflow, and neither reads CI
status. Run [ci-full.yml](../../.github/workflows/ci-full.yml) by hand first
when a change needs full coverage.

## GitHub Actions triggers and gates

| Entry | Result |
| --- | --- |
| Push `builds/**` | Exact tag/annotation/source validation, a signed archive with the tag's version and build, Apple validation and a single upload. No tests |
| Push ordinary `main` or a historical `v*` tag | No distribution workflow |
| `make release-check VERSION=X.Y.Z` | Manual dispatch from `main`, explicit version, next unreserved build as an override; archive and validate, never upload or reserve a number |
| `make testflight-retry TAG=...` | Re-run failed jobs of the original tag's run after reporting the recovery action |
| A tag's run fails because GitHub gave a job no runner | [release-retry.yml](../../.github/workflows/release-retry.yml) re-runs its failed jobs as `make testflight-retry` would, until the run's third attempt |
| Select a build in App Store Connect | No GitHub Action or new tag |

`meta` validates the immutable source and creates a draft prerelease checkpoint.
`archive` follows it directly. It uses the committed project with the tag's
version and build, pinned packages without a restored cache, manual signing,
and the existing IPA version/bundle/entitlement checks in
[release-signing.py](../../scripts/release-signing.py).
Export keeps `manageAppVersionAndBuildNumber=false`.

The signing job queries Apple before building and again immediately before
upload. An unexpectedly occupied/higher build or closed version stops it;
it never silently rewrites the candidate. App-wide concurrency serializes
distribution workflows, but is not a FIFO queue or a lock on local commands.
The cutter rechecks settlement after confirmation. A retry can
still start between its final read and push, leaving a newer reserved tag while
the older upload is unresolved. CI checks predecessor settlement again inside
the workflow concurrency lock, before archive and upload. The newer tag remains
reserved but cannot upload until reconciliation; a pre-upload failure of that
newer run cannot conceal the older uncertainty. Never delete the newer tag.
The stale-tag check also prevents an older candidate from starting an upload
after a newer reservation has already become visible.

Before calling `altool --upload-app`, CI attaches the matching dSYMs to the
candidate's draft release and verifies their retained SHA-256. It then durably
saves `upload_started`, the IPA SHA-256, toolchain, and upload run/attempt in the
draft release body. Losing the upload response or failing to save the next
checkpoint cannot authorize another upload. After Apple reports `VALID`,
`release` verifies the retained symbols, attaches `build-manifest.json`, and
publishes the record and symbols as a **prerelease**, never Latest, titled
`X.Y.Z (N) - TestFlight`. No store submission is made. TestFlight groups, export
compliance, and external beta review may still need attention.

The draft is a durable checkpoint, not an invitation to publish by hand. Keep
its machine-readable body and manifest intact. `release-status` reports recorded
state and the last Apple observation time, not live App Store availability.
Record retries reuse an existing matching manifest without replacing it, and
stop on conflicting contents. A published record without its matching manifest
or dSYM attachment is unfinished. Once valid, its original Apple observation
stays frozen so reruns do not change the manifest identity.

## Failure and recovery

| Outcome | Recovery |
| --- | --- |
| A job never got a runner, as when GitHub runs short of macOS capacity | Retried automatically until the run's third attempt. After that, check GitHub's status and run `make testflight-retry`. |
| Signing, archive, validation, or pre-upload check fails | Retry a transient failure on the same tag; a cut from the same commit refuses. A code fix needs a new build number; the failed tag remains. |
| dSYM validation or retention fails | No Apple upload starts. Fix a transient storage failure and retry; conflicting/incomplete assets require reconciliation, never overwrite. |
| Upload response is lost, or Apple has not exposed it yet | Retry observation only. An empty Apple response does not prove the upload failed. The candidate remains unresolved. |
| Apple is processing | Retry observation, without building or uploading. CI polls for up to 15 minutes per attempt. |
| Apple is valid but manifest/publication fails | Retry the original run to finish the record only. |
| Retained dSYM attachment is missing or changed after upload | Restore the original matching asset; do not rebuild or upload the binary again to replace its symbols. |
| Apple rejects processing | Preserve the rejected checkpoint/tag; fix the cause and cut a new build. |
| A newer tag is already reserved | An older run can observe an existing upload or repair records, but cannot start a new upload. |
| The run ends before saving its checkpoint (its first job never succeeded) | The tag is void and the next cut skips it. A rerun cannot help, since it refuses to create a checkpoint; fix the cause and cut a new build. |
| No checkpoint otherwise, conflicting identity, or ambiguous side effect | Stop for operator reconciliation; do not recreate a checkpoint by guessing. |

Recovery deliberately uses `gh run rerun --failed`, not a new dispatch from
`main`: the original run keeps the candidate's SHA and its checkpoint. The
automatic retry takes the same path and checks, but only when every failed job
carries GitHub's "not acquired by Runner" annotation, so a build failure or a
run cancelled by hand waits for a person. Manual dispatch remains rehearsal-only. GitHub allows reruns for
30 days; after that, operator reconciliation is required. A failed candidate
proved not to have uploaded can be superseded with a new number, but a known
or possible upload must be reconciled first. Never delete/re-cut a tag as recovery.

For missing checkpoints or permanently unresolved uploads, inspect the original
run's steps and App Store Connect inventory with an authorized maintainer.
Any manual repair must preserve the exact source, version/build, original run,
and evidence of whether upload started. Do not change `upload_started` back to
`reserved` merely because a query returns no build.

## External testing

A processed build reaches external testers only after it joins the **Public
Beta** group and passes Beta App Review. The
[testflight-beta skill](../../.claude/skills/testflight-beta/SKILL.md) drafts
each build's What to Test from the changelog. The maintainer tests the build and
approves the notes before the skill releases it.

`make testflight-notes TAG=...` lists the changelog entries that are new since
the group's newest build, by upload date. `SINCE=<commit>` replaces that
lookup. `make testflight-beta TAG=... NOTES=notes.txt` does four things:

- requires a `valid` record and an Apple `VALID` build;
- sets What to Test to the text in NOTES, at most 4000 characters, in every
  Test Information locale. The app has only `en-US`, so the notes carry the
  English and then the Chinese;
- adds the build to `GROUP` (default `Public Beta`);
- submits the build for Beta App Review, unless adding it already did.

A rerun changes only what differs.

Both commands run on the maintainer's Mac. Environment variables override the
login Keychain, which holds the Team API key from the `release` environment as
one generic password per variable. The `.p8` is base64-encoded:

```sh
security add-generic-password -U -s heeler-app-store-connect -a ASC_API_KEY_ID -w <key id>
security add-generic-password -U -s heeler-app-store-connect -a ASC_API_ISSUER_ID -w <issuer id>
security add-generic-password -U -s heeler-app-store-connect -a ASC_API_KEY_P8 -w "$(base64 -i AuthKey_<key id>.p8)"
```

## Signing and credentials

The `release` environment admits only branch `main` and tags `builds/*/*`.
Only admins may create build tags. This push is the upload authorization;
the environment has no additional reviewer. Keep credentials environment-scoped.

| Name | Kind | Content |
| --- | --- | --- |
| `DISTRIBUTION_P12_BASE64` | secret | Apple Distribution `.p12`, including private key and WWDR chain |
| `DISTRIBUTION_P12_PASSWORD` | secret | `.p12` export password |
| `DISTRIBUTION_CERT_SHA1` | variable | Signing certificate SHA-1 |
| `PROFILE_APP_BASE64` | secret | App Store profile for `dev.bybee.heeler` |
| `PROFILE_NOTIFICATION_SERVICE_BASE64` | secret | App Store profile for `dev.bybee.heeler.NotificationService` |
| `PROFILE_WIDGETS_BASE64` | secret | App Store profile for `dev.bybee.heeler.Widgets` |
| `ASC_API_KEY_P8` | secret | App Store Connect Team API `.p8`, App Manager role |
| `ASC_API_KEY_ID` | variable | API key ID |
| `ASC_API_ISSUER_ID` | variable | Team issuer ID |

The read-only Apple inventory client uses the same Team API key. Signing remains
in a throwaway keychain; cleanup runs even after failure. Rotate expired profiles
and certificates, then rehearse before cutting another candidate. Local development
continues to use automatic signing. No Xcode Cloud setup is required.

## Public dSYM retention

The maintainer chose to publish debug symbols with each build's release in this
open-source repository. No separate private repository, storage service or
credential is required; the existing job's `contents: write` permission suffices.
Symbols may expose function names and compile-time paths. This is an intentional
public artifact, not a guarantee that DWARF contents have been redacted.

CI verifies every exported app/extension Mach-O UUID and architecture against
the archive's symbols, then creates a deterministic ZIP of the dSYM bundles.
Only bundle plists, DWARF files and relocation metadata are allowed; symlinks
and unexpected files fail validation. Neither the IPA, whole `.xcarchive`, raw
Apple responses nor signing material is attached. The full archive remains
ephemeral and is discarded with the runner.

The asset is `Heeler-X.Y.Z-N-dSYMs-<sha256>.zip`. Its name, SHA-256 and per-file
UUID/architecture inventory join the candidate/source and IPA digest in
`build-manifest.json`. GitHub's asset digest is checked, or the retained file is
downloaded and hashed when the API supplies no digest. A missing or conflicting
asset stops publication. The release keeps the symbols independently of the
runner and workflow-artifact retention period; do not delete them while users
may still run that build.

Pre-upload retries can rebuild and produce different symbols. Each content
digest gets its own asset name; existing attachments are never clobbered.
Earlier attempts remain for diagnosis, while the manifest identifies the
symbols matching the actual upload. Once upload may have started, retries only
observe Apple or repair records and do not regenerate symbols. Signing
rehearsals also validate/package symbols locally, but attach nothing to GitHub.

## Migration checklist

Shared settings, dispatches and uploads require maintainer authorization.

1. Stop legacy release commands and wait for old runs to finish. Reconcile the
   live/pending version and consumed or uncertain Apple builds. Set the committed
   counter to at least the highest consumed/reserved number and regenerate the
   project. Do not infer upload from a bump commit or backfill speculative tags.
2. Land this implementation on `main`. Keep all historical tags/releases unchanged.
3. In environment `release`, keep branch `main`, add tag pattern `builds/*/*`,
   and remove `v*` so old workflow reruns cannot receive upload credentials.
4. Keep the existing protections on `refs/tags/v*`; add `refs/tags/builds/*/*`
   with creation/update/deletion restrictions and the existing Admin bypass.
   Do not broaden token or bot access. A single `*` does not cross `/` in these
   settings; Actions' separate trigger glob is `builds/**`.
5. Authorize `make release-check VERSION=<intended-version>`. It must pass Apple
   inventory, signing, export, IPA validation and dSYM matching/packaging.
   Rehearsal does not prove tag environment access or asset/upload behavior.
6. Review the first `make testflight VERSION=<intended-version> DRY_RUN=1`, then
   authorize the real cut. Verify tag/annotation, Apple `VALID`, the
   prerelease/manifest and matching dSYM ZIP, and absence of a new `v*` tag.
   Verify one subsequent build retains the marketing version and advances the
   global build number.
7. Select a tested build in App Store Connect and complete review/publication
   there. No Git-side formal-release step follows.

## Publishing the herdr plugin

The plugin is independent and ships from its append-only `plugin` branch:

```sh
make plugin
make plugin DRY_RUN=1
make plugin YES=1
make plugin SOURCE=<commit>
```

Users install `herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes`.
The branch contains runtime files plus the repository license, not the whole
app. [publish-plugin.sh](../../scripts/publish-plugin.sh) assembles a commit on
`origin/main`, checks its version and runtime tree, runs `npm ci` and tests,
then asks before appending a commit and pushing without force. Earlier commits
remain installable. Development and tests stay under `plugin/` on `main`;
`plugin/helper/` never reaches the branch, since the Host Helper ships inside
the app.

When the app needs a new plugin, bump every version listed in the plugin
README's "Releasing a plugin version", land it, and run `make plugin` first.
`make testflight` checks the published version before cutting; it never publishes
the plugin itself. Otherwise the app would ask users to update to a version the
plugin branch does not yet provide.

Older apps install `ZingerLittleBee/Heeler/plugin --ref main`, so `plugin/` on
`main` must remain directly installable. herdr 0.7.5+ replaces an older
GitHub-installed plugin with the same ID; a linked installation must first be
unlinked through the app's notice.
