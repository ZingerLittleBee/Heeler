# App Store versions, TestFlight builds, and Git tags

Research date: 2026-11-03. Heeler source baseline:
`148256743e9bfc0765fa59c75e6928b08f1a366c`.

This records the research and original proposal, not the operational contract.
App Store Connect's private inventory was not inspected; repository build bumps
are not proof of upload. The user subsequently chose GitHub Actions. Use
[the release contract](../guides/releasing.md) and
[ADR 0038](../adr/0038-testflight-build-tags.md) for the implementation.
The separate [Xcode Cloud assessment](xcode-cloud-feasibility.md) records why
that service was not selected.

Implementation amendment: recovery reruns the original tag workflow, rather
than dispatching from current main, to preserve same-source test evidence.
Manual dispatch is rehearsal-only. Missing checkpoints and runs beyond GitHub's
30-day retry window require operator reconciliation. The maintainer subsequently
chose public dSYM attachments on this repository's build releases, replacing
the original private-storage prerequisite. Full archives are not retained.
Shared policy changes and actual uploads still require separate authorization.
The local cutter cannot atomically lock out CI retries: a racing cut may reserve
a newer tag. The serialized CI workflow rechecks all unsettled predecessors and
blocks subsequent uploads until reconciliation; it does not remove reserved tags.

## Recommendation

User decision on 2026-11-03: remove the separate formal-release command.
App Store publication consists of selecting an existing TestFlight build
in App Store Connect. This supersedes the earlier two-layer Git-tag proposal.

Track build identity in Git; leave release selection and state to Apple:

- Keep one marketing version throughout a release's TestFlight iterations.
- Keep Heeler's increasing integer build counter, without resetting it for
  each marketing version. Allocate it through one coordinated path.
- Give every distribution candidate an immutable annotated build tag such
  as `builds/0.2.0/38`.
- Select and submit the already-tested build in App Store Connect. No
  repository command, rebuild, or additional Git tag is required before or
  after store publication.
- Do not add a `make publish` replacement, a store-publication verification
  workflow, or automatic stable GitHub releases. New automation creates only
  build tags and their TestFlight prerelease records.
- Leave historical `v*` tags unchanged and document their older meaning.

The principle is supported by Apple's version/build model and release
tooling. The exact `builds/X.Y.Z/N` spelling is a Heeler recommendation,
not an Apple requirement or a universal open-source convention.

## Proposed make command contract

These are proposed semantics, not commands to run against today's Makefile.
In particular, today's `make testflight` uploads locally and today's
`make publish` cuts a new version. Implement and migrate first.

The first iteration uses one current marketing version and one unresolved
candidate at a time. Changing the intended version is an explicit input,
not the result of closing a Git-side publication state. App Review submission,
compliance answers, tester-group assignment, and choosing the store release
time remain manual in App Store Connect. Automatic submission, concurrent
release branches, local distribution uploads, and a fastlane migration are
out of scope.

| Proposed command | Exact effect |
| --- | --- |
| `make testflight VERSION=0.2.0 DRY_RUN=1` | Read-only plan: show the version, proposed next build, files, annotated tag, atomic push, and CI upload. No commit, tag, push, workflow dispatch, or upload. |
| `make testflight VERSION=0.2.0` | Set the intended marketing version, allocate the next build, commit synchronized version settings and candidate notes, create `builds/0.2.0/N`, and push commit/tag atomically. CI tests and uploads that candidate. |
| `make testflight` | Create another build of the current version after its first build-tag cut. Never silently increment the marketing version or use a stable tag as the version's open/closed flag. |
| `make testflight-retry TAG=builds/0.2.0/39` | Reconcile/resume that candidate, without changing its source, tag, or build number. An accepted upload is never repeated. Code changes require a new candidate. |
| `make release-status TAG=builds/0.2.0/39` | Read GitHub's recorded candidate state, source, CI run, and last Apple processing observation time. Do not claim this is a live App Store publication check. |
| `make release-check VERSION=0.2.0` | Dispatch the existing signing/validation rehearsal with an explicit version. It can archive and validate, but creates no tag, uploads no build, and consumes no build number. It does not replace candidate tests. |

Normal mutating commands print the complete plan and ask before their first
external mutation. Retain `YES=1` to skip the prompt, not validation. Require
explicit `VERSION` for the first cut and when moving to a newer version.
Reject a `BUILD` override on a new TestFlight cut. All examples use
illustrative numbers: the first new build is 38 only if migration finds no
occupied or reserved number above 37.

Retire `make publish` without a formal-release replacement. Retire the public
`make bump` and `make upload` paths with an explicit error explaining the
TestFlight replacement. Do not silently alias the old commands: a
previously local operation now pushes a tag and starts CI. Keep `make archive`
for local inspection, but do not expose a second supported distribution
route. `make plugin` keeps its current meaning.

### Cutting a candidate

1. Require a clean `main` equal to freshly fetched `origin/main`. Check the
   published plugin for the candidate's source, and require matching app and
   extension versions in `project.yml` and the regenerated Xcode project.
2. Require a numeric `X.Y.Z`. An explicit `VERSION` may equal the current
   version or advance it after the prior candidate is resolved; it must not
   downgrade it. Without `VERSION`, reuse the current version established by
   the new build-tag flow. Apple's upload eligibility, not a Git version tag,
   decides whether another build of that version can be accepted. If closed,
   stop and require the next intended version explicitly; never auto-bump it.
3. Refuse an unresolved earlier candidate, including a pushed reservation
   whose workflow has not started yet. Allocate one plus the maximum of the
   committed counter and all remote, well-formed `builds/X.Y.Z/N` reservations.
   Migration seeds that counter at least as high as existing Apple usage.
   Failed reserved candidates count too. Never use a per-workflow run number
   or Git commit count.
4. Move current Unreleased entries into a version section, preserving earlier
   entries for that version. Use `## [0.2.0]` without a claimed store-release
   date. New sections describe candidate contents, not App Store status;
   historical dated sections remain unchanged. Refuse ambiguous note merges
   rather than deduplicating similar prose heuristically. An empty Unreleased
   section is allowed for a rebuild or signing-only change; a new train needs
   release notes.
5. Increment all target build settings, regenerate the project, and commit
   only those files and the notes. Annotate `builds/X.Y.Z/N` with the expected
   bundle ID, platform, version, build, and source commit. Push `main` and the
   tag atomically, without force. Competing cuts race on `main`; the loser
   stops and replans instead of rebasing a preallocated number.
6. CI validates exact tag syntax, annotation, source ancestry, all target
   versions, and the test gate. It checks Apple inventory before uploading,
   verifies the IPA, and uploads only an unused eligible build identity.
   An unexpectedly higher Apple build causes a floor-reconciliation failure,
   not an automatic rewrite of the reserved tag or build settings.
7. After Apple processing succeeds, create a GitHub **prerelease** at the
   build tag, titled `0.2.0 (39) - TestFlight`, explicitly excluded from Latest.
   Its body contains the candidate's frozen cumulative version notes. Attach
   a small allowlisted build manifest: version/build, source/tag, CI run/attempt,
   plugin version, toolchain, IPA digest, Apple build ID, and observed state/time.
   Do not attach the IPA, archive, credentials, or raw Apple API responses.

The prerelease is a durable build record, not a second stable release.
"TestFlight" here means a successfully processed candidate; tester-group
assignment or external beta review may still be pending. Retain upload
checkpoints in CI before this record is finalized, so a record-write failure
does not force another upload. The implementation now retains matching dSYMs
as public build-release attachments rather than requiring private storage.

Serialize distribution work with an app-wide concurrency group rather than
the current per-tag group. Do not treat that group as a build-number queue:
[GitHub documents](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
that queue order depends on when jobs start waiting, not dispatch order, and
the default pending queue can replace a waiting run. The CLI's single
unresolved-candidate rule, atomic reservation, and a final stale-candidate
check before upload are still required. Once a newer candidate is reserved,
an older retry can repair records for an existing Apple build but cannot
perform a new upload.

### App Store publication stays in App Store Connect

Select the tested build there, supply the required metadata/compliance
information, and complete App Review and release. The existing build tag
continues to identify the source; no Git action is required afterward.
There is no `verify-store` dispatch, stable-tag push path, publication
attestation, or notes-finalization command in this design.

Use the selected build's frozen notes for store metadata, not the latest
version section on `main`, which may include a later candidate. The repository
does not mirror Apple's release status or dates. A build prerelease remains
a build record even when Apple distributes that build to customers.

After cutover, the signing environment allows `main` and `builds/*/*`, but
no longer `v*`. Historical `v*` tags stay protected and unchanged, while old
tag workflows cannot obtain upload credentials on a rerun. Existing legacy
jobs must finish before switching the policy. Keep the administrator as tag
creator; no new bot bypass or broad PAT is needed.

### Recovery is selected by side effect, not by the red job alone

| Observed outcome | Proposed recovery |
| --- | --- |
| Dry-run or preflight fails | Fix the input or environment; no candidate was reserved. |
| Atomic push fails | Inspect remote refs before claiming nothing landed. If both refs are absent, preserve local work and retry the same push when safe; if another cut won, replan from current `main`. Never force or blindly increment and push again. |
| Candidate test/archive fails before upload | Retry the same tag for a transient failure. For a code fix, resolve the failed candidate as not uploaded and create a new numbered candidate. |
| Upload outcome is unknown | Query Apple and retain the unresolved state while processing/visibility is ambiguous. Do not infer absence from one empty response or automatically re-upload. |
| Apple accepted the build; processing is pending | Resume observation only. Keep the same tag and build. |
| Apple accepted a valid build; GitHub prerelease creation failed | Reconcile the Apple build with the upload checkpoint and finish the prerelease/manifest only. Do not rebuild or upload. |
| Processing rejects the binary | Preserve the tag and failure evidence; fix the cause and create a new build number. |
| Apple no longer accepts builds for the current marketing version | Keep the failed reservation; explicitly choose the next intended version for a new candidate. |

All retry entry points first report whether they will resume tests/building,
observe processing, or repair records. If evidence needed to distinguish
those cases is missing, stop for reconciliation instead of guessing.

## What Heeler does today

| Path | Marketing version | Build | Git and publication effects |
| --- | --- | --- | --- |
| `make bump && make testflight` | Unchanged | Incremented | Regenerates the project, archives locally, and uploads; creates no tag or GitHub release. The bump needs a separate commit. |
| `make publish` | Explicit version or next patch | Incremented | Cuts CHANGELOG, commits version settings, creates annotated `vX.Y.Z`, and pushes commit/tag atomically. CI tests, archives, uploads, then creates a non-prerelease GitHub release. |
| Manual `release.yml` dispatch | Next patch, as build override | Next integer, as override | Rehearsal only: validates but does not upload. |

Baseline sources: [Makefile](https://github.com/ZingerLittleBee/Heeler/blob/148256743e9bfc0765fa59c75e6928b08f1a366c/Makefile#L221-L258),
[publish script](https://github.com/ZingerLittleBee/Heeler/blob/148256743e9bfc0765fa59c75e6928b08f1a366c/scripts/publish.sh#L102-L178),
[workflow](../../.github/workflows/release.yml), and
[release contract](../guides/releasing.md).

The concrete divergence is already visible:

- `v0.1.16` points to commit
  `569487fd3b9308058524c60099c792b66092c4aa`, whose project declares
  **0.1.16 (32)**.
- The research baseline declares **0.1.16 (37)**. Between these commits,
  history contains explicit bumps to 33, 34, 35, 36, and 37.
- The GitHub release for `v0.1.16` is published and not a prerelease. The
  workflow does not select a build for App Review or observe App Store
  availability; its publication gate is the upload command succeeding.

Evidence commands: `git show v0.1.16:project.yml`,
`git log v0.1.16..HEAD -- project.yml`, and
`gh release list --repo ZingerLittleBee/Heeler --limit 8 --json tagName,isPrerelease,isDraft`.

Thus the problem is not that Git cannot tag builds, or that multiple builds
under a version are invalid. The current command contract provides only a
version tag for its CI path and no tag for its interim-build path. It also
uses "release" to mean TestFlight upload plus GitHub publication, not App
Store distribution.

The local archive records a source revision only when HEAD is pushed and
uncommitted tracked changes are limited to build-number changes
([source-revision.sh](../../scripts/source-revision.sh)). That is useful
source provenance, but it is not a persistent build-to-tag index. Export
already disables automatic version/build rewriting
([baseline ExportOptions.plist](https://github.com/ZingerLittleBee/Heeler/blob/148256743e9bfc0765fa59c75e6928b08f1a366c/scripts/ExportOptions.plist#L13-L14)); retain
that invariant when tags identify builds.

## Apple rules, separate from repository policy

| Fact | Primary source |
| --- | --- |
| `CFBundleShortVersionString` is the user-visible version, expressed as three period-separated integers. | [Apple: CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring) |
| `CFBundleVersion` identifies a build iteration. One integer is allowed; the documented form is one to three period-separated integers. | [Apple: CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion) |
| Bundle ID and version associate an upload with its app/version record. Apple processes an upload before it appears in App Store Connect. | [Apple: Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) |
| An app version can have multiple uploaded builds. Select one existing build for submission; it can be changed before submission. | [Apple: Choose a build to submit](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/) |
| A published app update requires an incremental App Store version; rolling back does not mean reusing an old store version. | [Apple: Create a new version](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version) |
| A build uploaded as **TestFlight Internal Only** cannot be submitted for external testing or to customers. This is different from an ordinary distribution build tested by an internal group. | [Apple: Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers) |

Apple's archived [TN2420](https://developer.apple.com/library/archive/technotes/tn2420/_index.html)
(last updated 2017-06-15, explicitly no longer maintained) calls the builds
of one version a "release train". It requires increasing, non-reused build
numbers within that train and says iOS, unlike macOS, can reuse numbers
across trains. Do not turn that older allowance into a dependency of the new
workflow: a globally increasing counter is simpler for Heeler and avoids
cross-version reset assumptions. This is a conservative project policy,
not a claim that Apple requires global uniqueness for every iOS build.

`beta`, `rc`, `builds/`, and `+38` are Git naming choices. Do not put those
suffixes in either Apple bundle-version field. For example,
`builds/0.2.0/38` means marketing version `0.2.0`, build `38`.

## Comparable open-source iOS apps

Repository tags, GitHub release metadata, and checked-in configuration were
read through GitHub's API. These observations are not an audit of private
distribution systems or uploaded IPA metadata. Release labels are mutable;
the source links below pin the inspected commits.

| Project | Observed public convention | What it establishes |
| --- | --- | --- |
| Ice Cubes | Plain version tags, including `2.1.5` and `2.1.6`, with releases titled "App Store 2.1.5" and "App Store 2.1.6". | A marketing-version-oriented public release history; no explicit per-build series in the inspected public tag inventory. |
| Nextcloud iOS | Plain version tags such as `35.2.2`; separate build-only commits under the same marketing version. | Product versions and build iterations are maintained independently. A version tag does not guarantee store distribution. |
| Firefox iOS | `firefox-v140.0b1` through `firefox-v140.0b9`, followed by `firefox-v140.0`; beta releases explicitly marked prerelease. | Multiple beta identities under a numeric marketing version and explicit separation of TestFlight upload from GitHub release publication. |

### Ice Cubes: public release tags, incomplete distribution visibility

The [2.1.6 release](https://github.com/Dimillian/IceCubesApp/releases/tag/2.1.6)
is titled "App Store 2.1.6" and is not a prerelease. Its
[Release configuration](https://github.com/Dimillian/IceCubesApp/blob/c3a852fd9c3cf3fe1c01797f410ba9def098edd3/IceCubesApp.xcodeproj/project.pbxproj#L1142-L1173)
declares marketing version `2.1.6` and build `3066`. The
[2.1.5 configuration](https://github.com/Dimillian/IceCubesApp/blob/5782d683025265da7ba58f5463121c3be2bcdc02/IceCubesApp.xcodeproj/project.pbxproj#L1142-L1173)
also declares build `3066`. These are source settings, not independently
verified uploaded build numbers.

The public [post-build hook](https://github.com/Dimillian/IceCubesApp/blob/98098b9c4b5928f89f338203193c2bf40ab7f38c/ci_scripts/ci_post_xcodebuild.sh#L5-L30)
is gated to an "EmergeTools Upload" workflow. It does not establish the full
App Store build allocator or tag timing. Do not infer an entire TestFlight
policy from the plain version tags.

### Nextcloud: independent build bumps and a withdrawn release

Two source revisions hold marketing version `33.1.0` with different build
numbers: [build 2](https://github.com/nextcloud/ios/blob/f4aec3c69034695b1ddb0ca3bb0020b9035138f6/Nextcloud.xcodeproj/project.pbxproj#L6308-L6333)
and [build 5](https://github.com/nextcloud/ios/blob/b93034677e84b1350f571c3ec83f93bb522efad3/Nextcloud.xcodeproj/project.pbxproj#L6275-L6300).
[PR 4163](https://github.com/nextcloud/ios/pull/4163) increments build 4 to 5
without changing that marketing version. These are build commits, not
evidence of one tag or successful TestFlight upload per build.

The [35.2.0 GitHub release](https://github.com/nextcloud/ios/releases/tag/35.2.0)
is currently titled "Version 35.2.0 (withdrawn)", marked prerelease, and says:

> Withdrawn before App Store distribution. Superseded by 35.2.1

This directly demonstrates why a version tag and GitHub release cannot be
treated as proof of App Store availability. The current flag does not prove
what its classification was when first created.

Historical tags `2.24.4-(1)` and `2.24.4-(2)` also exist in that repository,
but those revisions contain a [kDrive-branded target](https://github.com/nextcloud/ios/blob/21c8fce4f9ec671d2323e1649bb6584aecda0027/kDrive.xcodeproj/project.pbxproj#L4088-L4089).
They are not used here as evidence for the current Nextcloud app's policy.

### Firefox: beta identity is not the binary build number

[140.0b1](https://github.com/mozilla-mobile/firefox-ios/releases/tag/firefox-v140.0b1)
and [140.0b2](https://github.com/mozilla-mobile/firefox-ios/releases/tag/firefox-v140.0b2)
are prereleases; [140.0](https://github.com/mozilla-mobile/firefox-ios/releases/tag/firefox-v140.0)
is not. The [Bitrise workflow](https://github.com/mozilla-mobile/firefox-ios/blob/1929a34894546534229359bdfa5c4261f721b787/bitrise.yml#L1265-L1279)
strips the beta suffix to obtain numeric marketing version `140.0`, then
[sets that plist version](https://github.com/mozilla-mobile/firefox-ios/blob/1929a34894546534229359bdfa5c4261f721b787/bitrise.yml#L2199-L2206).

The build-number step's [1.x default](https://github.com/bitrise-steplib/steps-set-xcode-build-number/blob/f0272f2f509fd80160677d6469703e7f87df05eb/step.yml#L59-L78)
uses `BITRISE_BUILD_NUMBER` for `CFBundleVersion`. Firefox references the
major step version, not an exact patch. Its separate
[Taskcluster rebuild counter](https://github.com/mozilla-mobile/firefox-ios/blob/f47238bc1509d1151cd1681112aaed4801d5f5c7/taskcluster/ffios_taskgraph/release_promotion.py#L41-L49)
starts at one for each release and increments on rebuild. Thus `b2`, the
Apple build number, and the Taskcluster rebuild attempt are distinct.

The [push notification](https://github.com/mozilla-mobile/firefox-ios/blob/f47238bc1509d1151cd1681112aaed4801d5f5c7/taskcluster/kinds/release-notify-push/kind.yml#L18-L28)
explicitly says "has been pushed to TestFlight!"; the
[GitHub release task](https://github.com/mozilla-mobile/firefox-ios/blob/f47238bc1509d1151cd1681112aaed4801d5f5c7/taskcluster/kinds/github-release/kind.yml#L35-L62)
belongs to the separate ship phase. This is strong evidence for stage
separation, not for checking App Store availability from a tag.

FirefoxBeta uses the [separate bundle ID `org.mozilla.ios.FirefoxBeta`](https://github.com/mozilla-mobile/firefox-ios/blob/f47238bc1509d1151cd1681112aaed4801d5f5c7/firefox-ios/Client/Configuration/FirefoxBeta.xcconfig#L9-L12).
Do not infer that its beta binary becomes the production Firefox binary
unchanged. The recommendation to promote Heeler's same-app build instead
comes from Apple's build-selection model and fastlane's explicit support.

Literal build-tag precedent also exists in Firefox's 2016 history:
`v2.0b2001-Beta` and `v2.0b2002-Beta` map to marketing version `2.0` and
builds [2001](https://github.com/mozilla-mobile/firefox-ios/blob/72d4ed2c7a269b6f527d283f53bd7d686ec526a8/Client/Configuration/BaseConfig.xcconfig#L11-L15)
and [2002](https://github.com/mozilla-mobile/firefox-ios/blob/670c0c19944f841d9997ff0398d21d3fdeffecd9/Client/Configuration/BaseConfig.xcconfig#L11-L15).
These establish the mapping, not verified delivery or a current naming rule.

**Synthesis:** no sampled project establishes a universal requirement to tag
every TestFlight upload. Separate version/build identities and publication
stages have clear precedent. Individual build tags are recommended here
because Heeler explicitly needs that audit trail.

## Established tooling separates build tags and promotion

[fastlane's `add_git_tag`](https://docs.fastlane.tools/actions/add_git_tag/)
creates annotated tags with default form
`<grouping>/<lane>/<prefix><build_number><postfix>`, where grouping defaults
to `builds`. Its documented example is `builds/appstore/1234`. This directly
supports a separate namespace for build provenance, without claiming that
the tag proves App Store availability.

[fastlane's `deliver`](https://docs.fastlane.tools/actions/upload_to_app_store/)
documents promotion of an existing build using an explicit `build_number`
and `skip_binary_upload: true`. Heeler does not need to adopt fastlane to
use the same separation; its existing `make`, scripts, and GitHub Actions
can retain their ownership.

## Naming options

| Convention | Assessment for Heeler |
| --- | --- |
| `builds/0.2.0/38` | Selected. Encodes both version and build independently of distribution status. No separate stable tag is required. |
| `builds/0.2.0/38` plus `v0.2.0` | Earlier proposal, superseded by the user's decision to keep App Store publication entirely in App Store Connect. |
| `v0.2.0-beta.38` | Alternative build tag spelling, not selected. Define 38 as the actual Apple build number, not a separate beta counter. |
| `v0.2.0+38` | Legal Git naming and SemVer build metadata, but SemVer ignores `+38` for precedence. Do not rely on it to order builds or imply prerelease status. |
| `v0.2.0.38` | Encodes both numbers but is not a three-component SemVer version. It also tempts callers to confuse build and marketing version. Avoid. |
| `v0.2.0` only, build mapping in CI records | Can work if records are durable, but does not meet the stated need for individual build tags. |

Source for prerelease and build-metadata distinctions:
[SemVer 2.0.0, clauses 9-11](https://semver.org/spec/v2.0.0.html).
Git tag spelling and Apple version validation remain separate concerns.

Illustrative sequence, not actual Heeler uploads:

| Event | Marketing version | Build | Tag and meaning |
| --- | --- | --- | --- |
| First candidate | 0.2.0 | 38 | `builds/0.2.0/38` identifies its committed source/settings. |
| Fix after testing | 0.2.0 | 39 | `builds/0.2.0/39` identifies a new candidate. |
| Final tested candidate | 0.2.0 | 40 | `builds/0.2.0/40` identifies the build selected for App Review. |
| Store publication | 0.2.0 | 40 | Select build 40 in App Store Connect. Keep `builds/0.2.0/40` unchanged; no new tag, Action, or rebuild. |
| Next patch candidate | 0.2.1 | 41 | `make testflight VERSION=0.2.1` creates `builds/0.2.1/41`. |

If review requires a code change, upload build 41 under 0.2.0 before
publication instead, and use 42 or later for the next version. Allocation
must follow actual history, not the illustrative sequence.

## Operational consequences of the proposed policy

1. **Choose the next marketing version once.** TestFlight iterations change
   the build, not the marketing version. An App Store update after a shipped
   version starts a new marketing version.
2. **Use one build allocator.** For the smallest change, keep the committed
   counter and serialize allocation and uploads, not just counter increments;
   reconcile it with App Store Connect and reserved build tags during
   migration. A plain local `+1` on
   multiple machines is not a coordinated allocator. Failed reservations
   may leave harmless gaps. Do not mix local counters with unrelated CI
   counters. GitHub's `GITHUB_RUN_NUMBER` is per workflow and does not change
   on reruns ([GitHub variables reference](https://docs.github.com/en/actions/reference/workflows-and-actions/variables)).
3. **Make build tags immutable.** A pre-upload tag reserves a candidate;
   upload and processing status live in CI/App Store Connect. A tag alone
   does not prove upload success. Fixes create a new numbered candidate,
   not a moved tag. If an upload's outcome is uncertain, inspect App Store
   Connect before attempting it again. Do not re-upload an accepted build
   just to repair a missing GitHub publication step.
4. **Select the tested build in App Store Connect.** Confirm its version,
   build, export compliance, and eligibility for App Review. Git does not
   mirror publication state, and selection requires no repository command.
5. **Keep the mapping durable.** Record marketing version, build, source
   SHA, build tag, and CI run in each build's prerelease record.
   Retain matching dSYMs with that release for crash diagnosis; a source
   tag alone does not preserve debug symbols or guarantee byte-identical
   rebuilding with a different toolchain. Full archive backup is optional.
6. **Freeze notes with each build.** Keep one cumulative section per version
   and snapshot it with each build tag. Store metadata uses the selected
   build's snapshot, not a newer section on `main`. Neither the changelog nor
   GitHub prereleases claim to record App Store dates; no publication-time
   finalization step is needed.

## Proposed migration sequence

Only the design and read-only inspections have happened. None of the
following shared settings changes, pushes, dispatches, or uploads is
authorized by the request to design this migration.

### 1. Reconcile the existing state and preserve history

Temporarily stop legacy release commands and wait for active release runs to
finish. Check App Store Connect for the actual live version, pending version,
all consumed build numbers relevant to the global counter, and any upload
with an uncertain outcome. Record the maximum of Apple usage, checked-in
counter, and reserved build tags; set the committed counter to that maximum
if it is higher than today's 37. The next cut increments it once.

Preserve every historical tag and release, including `v0.1.16` at build 32.
Do not add a new tag to build 37 merely because a bump commit exists.
Choose the intended next marketing version after reconciliation;
`0.2.0` is an example, not a verified available version. No archive needs to
be rebuilt merely to migrate its historical record.

### 2. Implement and validate the new contract locally

| Owner | Proposed change |
| --- | --- |
| `Makefile` and a candidate-cut script | TestFlight cut/retry/status/check entry points; explicit parameters and dry-run; retire publish and independent bump/upload distribution. |
| `scripts/publish.sh` | Reuse its relevant candidate-cut checks in the TestFlight path and remove the obsolete version-release implementation. Do not replace it with an App Store publication command. |
| `.github/workflows/release.yml` | Trigger uploads from build tags only; manual dispatch remains for rehearsal and candidate recovery. Remove the `v*` trigger and stable-release branch; do not add a store-verification operation. Preserve the current manual-dispatch default as rehearsal. |
| `scripts/release-signing.py` and existing test workflows | Preserve signing isolation, pinned dependencies, IPA checks, and the full candidate test gate. Add only metadata/API handling needed for the new release state. |
| `docs/guides/releasing.md`, command help, and release guidance | Describe version/build tags and frozen notes, App Store Connect build selection, build prereleases, and the removal of publish/delete-and-recut steps. |

Use the Actions tag glob `builds/**`, followed by an anchored parser for
exact `builds/X.Y.Z/N`. Remove the old stable-version discovery and its
`v[0-9]*.[0-9]*.[0-9]*` glob. Ordinary `main` pushes still run daily CI,
not distribution. Choosing a build in App Store Connect triggers no Action.

Required acceptance cases include: two builds under one marketing version;
an empty incremental changelog on a rebuild; synchronized extension settings;
competing atomic cuts; a reserved tag whose run has not started; a stale
retry after a newer reservation; ambiguous upload outcomes; accepted upload
with failed record creation; frozen notes unaffected by later candidates;
explicit version advancement without a Git-side formal release; rejected
uploads for a closed version; and no upload/release action on `v*` tags.

Use disposable Git remotes and stub only the external GitHub/Apple boundary
for these behavior tests. Integrate focused script checks into `make test-tools`,
run the repository's workflow validation, and retain `make check-agent-docs`.
Do not execute old `make publish` as a way to test the new design.

### 3. Merge the implementation, then switch GitHub policy

Read-only GitHub API inspection on 2026-11-03 found:

- Environment `release` permits branch `main` and tag pattern `v*`.
- Active tag ruleset `Protect release tags` targets `refs/tags/v*`, restricts
  creation/update/deletion/non-fast-forward, and grants bypass to the Admin role.

After the new workflow is on `main`, and with no legacy release job running,
make these explicitly approved changes before the first new candidate:

| Setting | New policy |
| --- | --- |
| `release` environment | Keep branch `main`; add tag pattern `builds/*/*`; remove tag pattern `v*`. |
| Protected tag targets | Keep `refs/tags/v*`; also protect `refs/tags/builds/*/*` with the existing restrictions and administrator bypass. Do not grant a new bot bypass. |
| Workflow dispatch | Rehearsal and candidate recovery dispatch from protected `main`; any candidate source supplied to recovery is validated, not arbitrary executable input. No formal-release operation. |

The slashes matter: [environment policies](https://docs.github.com/en/rest/deployments/branch-policies)
and [rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)
use patterns whose single `*` does not cross `/`. `builds/*` does not match
`builds/0.2.0/39`. Actions uses its own
[tag-glob syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax),
where `builds/**` covers the namespace. Exact metadata validation still applies.

### 4. Rehearse without consuming a build

Run the new `make release-check VERSION=<chosen-version>` with approval.
Check signing/export/validation, main-ref environment access, and the
read-only Apple API lookup. Rehearsal success does not prove build-tag
environment access or the actual upload path; inspect the policy and verify
those during the first authorized candidate.

### 5. Upload the first new candidate and verify its record

Review `make testflight VERSION=<chosen-version> DRY_RUN=1`, then authorize
the real cut. Its source must include the new workflow; do not point new
tags at pre-migration commits that still run the old release code. Check:
the exact build tag, full test gate, Apple processing, synchronized bundle
versions, prerelease classification, non-Latest status, manifest, and no
new `vX.Y.Z` tag. A subsequent candidate for the same version changes only
the build identity and cumulative version notes, not the marketing version.

### 6. Select a tested build in App Store Connect

Manually select the tested build in App Store Connect and finish review and
release there. Nothing else must run in the repository. The original build
tag and its prerelease remain the source record; do not rename either or
create another tag merely because the build became available in the store.

If cutover fails, stop and repair forward. Re-running legacy upload workflows,
restoring their `v*` credential access, deleting tags, or resetting the counter
is not an automatic rollback. Preserve consumed numbers and accepted builds.
