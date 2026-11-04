# Xcode Cloud feasibility for Heeler

Research date: 2026-11-03. This is a read-only feasibility study, not an
implementation or authorization to connect GitHub, enable Xcode Cloud,
start a build, change signing, or upload an app.

Subsequent decision: retain GitHub Actions and implement the
[TestFlight build-tag proposal](app-store-build-tags.md). The
[release contract](../guides/releasing.md) owns the current implementation and
migration steps. This study records why Cloud was not selected; it is not an
active migration plan. App Store publication selects an existing build in
App Store Connect, without a separate formal-release command.

## Assessment

Xcode Cloud is a credible candidate for Heeler's archive, managed signing,
and TestFlight distribution. It supports GitHub sources, Swift packages,
tag/manual/API triggers, and App Store-eligible archives. It is not a
drop-in replacement for the current full verification or the recorded
tag-authoritative build-number contract.

Two constraints determine the recommendation:

1. **Keep the full native test gate on GitHub for now.** Apple's
   [custom-script documentation][scripts] explicitly says, "You can't obtain
   administrator privileges by using `sudo` in your custom build scripts."
   Heeler's real-password SSH fixture requires those privileges. Moving the
   complete suite would require changing its fixture topology, not changing
   a runner label, and skipping this coverage is not an acceptable migration.
2. **Choose one build-number owner before adopting Cloud distribution.**
   Apple's [numbering documentation][numbering] says, "App Store Connect
   uses the build number of the Xcode Cloud build." No supported per-run
   override or preserve-source-number switch was found in the inspected
   documentation/API schema. The existing proposal instead allocates `N`
   before building and uses `builds/X.Y.Z/N` as the upload trigger.

Recommendation: retain the recorded GitHub-only plan until the owner chooses
whether Cloud should own build numbers. If simplifying signing is worth that
contract change, evaluate a hybrid: GitHub verifies the exact candidate,
then Xcode Cloud archives and distributes it. Do not migrate the full CI or
run two independent upload paths. This is a recommendation for a later pilot,
not a decision to implement the hybrid now.

## What Apple's documented service supports

| Capability | Primary source and finding | Heeler consequence |
| --- | --- | --- |
| Tag starts | [Start conditions][starts] start builds on tag creation or update. [Tag patterns][tag-patterns] support case-sensitive prefixes or exact names. | A `builds/` prefix is supported; GitHub's `builds/**` glob is not the Cloud configuration syntax. Strict format checking and immutable-ref policy remain ours. |
| Manual/API starts | Manual Start can target tags. [Create build run][create-run] uses workflow and source branch/tag resource relationships, a PR, or an existing run. | Hybrid orchestration is possible. The published schema does not expose arbitrary commit-SHA input; use an immutable source ref and verify the checkout SHA. |
| Managed signing | [Project setup][setup] requires "Allow Xcode to manage signing for you." | Avoid copying the existing P12/profile installation pipeline into Cloud; validate the app and both extensions with Apple-managed signing. |
| Distribution | [Distribution workflow][distribution] offers **TestFlight and App Store**, describing the binary as eligible for both public testing and App Store release. | Select this archive mode even if initial testing is internal. **TestFlight Internal Only** binaries cannot later be submitted to customers. |
| Store release | [Choose a build][choose-build] selects one of the builds already uploaded for the version. | Fully compatible with the user's decision: no separate formal-release command or second upload. |
| Dependencies | [Dependency documentation][dependencies] supports public Swift packages and relies on committed `Package.resolved`; private sources need access grants. Homebrew is available. | Existing package structure is compatible on paper; test exact binary downloads, checksums, tool versions, and proxy-aware network access in a pilot. |
| Hooks | [Custom scripts][scripts] recognizes executable `ci_post_clone.sh`, `ci_pre_xcodebuild.sh`, and `ci_post_xcodebuild.sh` beside the project in `ci_scripts/`. | Reuse artifact/provenance checks at the appropriate archive phase, but do not assume all phases share a filesystem or running fixture processes. |
| Test isolation | [Actions documentation][actions] uses separate temporary action environments and a test-execution phase without the source checkout. | A local sshd started during preparation is not proven reachable from the managed test-execution environment. This is another reason not to equate a default Cloud Test action with Heeler's custom runner. |
| Monitoring | [Build-run APIs][runs], [artifact APIs][artifacts], and [webhooks][webhooks] expose run state, related builds, artifacts, and create/start/finish events. | A controller can reconcile outcomes and export records. GitHub prerelease creation would remain custom integration, not an established built-in Cloud action. |
| GitHub checks | [PR requirements][pr-checks] documents whole-build and action status checks on GitHub PRs. | Useful for PR feedback, but it does not establish that a Cloud tag build waits for Heeler's GitHub test gate. |
| Retention | [First-workflow documentation][first-workflow] says artifacts are stored for **up to 30 days**. | Export archives/dSYMs and required evidence to durable private storage. Do not confuse artifact retention with TestFlight build expiry. |

For tester-group automation, use the explicitly configured Cloud TestFlight
post-action. Apple [Cloud distribution documentation][testflight] describes
that automation, whereas [internal-tester help][internal-testers] warns that
Cloud builds need manual group addition. Do not assume the generic group's
automatic-distribution checkbox handles Cloud builds; verify the configured
post-action's account behavior in the pilot. External beta review and App
Review are separate gates.

### Build numbers require an explicit design change

Apple documents an integer counter increasing for each Cloud build, starting
at 1. `CI_BUILD_NUMBER` exposes the number. Admins or App Managers can change
the app's **Next Build Number** in Cloud settings. The documentation presents
this primarily as a migration tool for existing Mac apps; it does not describe
atomic per-tag assignment or keeping a number through retries.

The inspected [create-run attributes schema][run-attributes] exposes `clean`,
not a build-number override. The documented Rebuild operation starts from
the same source commit, not a documented guarantee of the same build number.
Treat a rebuild as potentially producing a different numbered candidate;
do not promise that a failed `builds/0.2.0/39` can be rebuilt as Apple build 39.
This does not establish that every unsupported workaround is impossible.

The choices are therefore:

| Choice | Build-number authority | Meaning of `builds/X.Y.Z/N` |
| --- | --- | --- |
| Keep the saved GitHub-only proposal | The coordinated repository release command | Pre-build immutable reservation and trigger, with `N` checked against the uploaded binary. |
| Adopt Cloud-native distribution | Xcode Cloud | A record created after the actual Cloud number and source are known, rather than predicting `N` before dispatch. A separate source selection and test gate starts the build. |

The second choice changes command behavior, tag timing, failure recovery,
and project-version validation. Build tags must not retrigger the distribution
workflow when they are written as receipts. No stable `vX.Y.Z` tag or formal
release step is needed in either choice. This study does not select a new
source-ref naming convention or authorize tag-writing credentials.

Do not synchronize a guessed next number before every run: concurrent builds,
manual runs, failures, and retries invalidate that assumption. If adopting
Cloud, reconcile existing Apple usage during migration and seed the counter
appropriately for Heeler's chosen increasing-number policy, then keep one
allocator. Resetting to 1 within an already-used version is not justified by
Apple allowing lower numbers for a **new** iOS marketing version.

## Repository evidence

Local source baseline: `148256743e9bfc0765fa59c75e6928b08f1a366c`.
The read-only GitHub check found remote `main` at
`b33143440c1a6344d303103e7ec063927c1f1eb1`, 19 commits ahead. Comparing those
revisions found no changes to the assessed release/full-test workflows,
Makefile, project.yml, package manifests, test runner, or signing helper.
The Xcode project change adds source membership, not release settings.
The worktree was not rebased or updated for this study.

| Area | Evidence | Implication |
| --- | --- | --- |
| Native project | Committed [Xcode project](../../Heeler.xcodeproj/project.pbxproj) and [shared Heeler scheme](../../Heeler.xcodeproj/xcshareddata/xcschemes/Heeler.xcscheme); iOS 18 minimum | A Cloud archive need not install XcodeGen or regenerate the project. |
| Swift packages | [HeelerSSH](../../Packages/HeelerSSH/Package.swift) and [HeelerOverlay](../../Packages/HeelerOverlay/Package.swift) use Swift tools 6.2; [Package.resolved](../../Heeler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) pins the remote dependencies | Select a compatible Cloud Xcode environment and preserve exact dependency resolution. |
| Native libraries | HeelerSSH commits its XCFrameworks; overlay and Ghostty use pinned external packages | The app archive consumes native artifacts; it does not build OpenSSL, libssh2, or the overlay runtimes from source. Network access and binary checksums still need validation. |
| Supply-chain checks | [verify-native.sh](../../Packages/HeelerSSH/Scripts/verify-native.sh) verifies hashes, slices, minimum OS, signature, provenance, and algorithm policy | Preserve `make verify-ssh-artifacts`; successful SwiftPM resolution alone does not replace it. |
| Signing | [project.yml](../../project.yml) uses automatic signing, but [release.yml](../../.github/workflows/release.yml) overrides it with manual distribution signing | Migrating distribution can remove the manual CI signing-material lifecycle only after Apple-managed signing is validated for all signed targets. |
| Capabilities | Main app, Notification Service, and Widgets share `group.dev.bybee.heeler.shared`; the main app uses APNs | Validate all bundle IDs, entitlements, production push, and extension versions in the exported artifact, not merely a successful archive. |
| Source provenance | Release archive explicitly sets `HEELER_SOURCE_REVISION`; [Info.plist](../../Sources/Heeler/Info.plist) consumes it | Cloud must inject the actual checked-out SHA. Otherwise About can lose its source link. |
| Full tests | [ci-full.yml](../../.github/workflows/ci-full.yml) uses three app shards and a separate package lane, then aggregates exact coverage evidence | A green default Cloud Test action is not equivalent to the existing release test gate. |
| Privileged fixture | [run-ci-ios-tests.sh](../../scripts/run-ci-ios-tests.sh#L1865-L1940) creates a temporary macOS account and runs root-owned sshd; mandatory mode fails without passwordless sudo | Moving the full gate requires host permissions and fixture topology compatible with these real-password tests. Do not silently skip them. |
| Other deliverables | Node/plugin/relay/site jobs are separate; [plugin publication check](../../scripts/check-plugin-published.sh) verifies the published `plugin` branch | Cloud app distribution does not replace these jobs or plugin publication ordering. |

The current release archive waits for the complete native gate through
`needs: [meta, test]` in [release.yml](../../.github/workflows/release.yml).
Two services responding independently to the same tag would lose that ordering
unless a new explicit gate is implemented.

The release guide's earlier rejection of cloud-managed signing describes
certificate/API-key management on clean external runners. It is not evidence
that Apple's own Xcode Cloud service cannot manage signing for this app.
The two execution models should be evaluated separately.

## Environment and cost constraints

Apple's [workflow reference][workflow] allows selection from available Xcode
and macOS versions, but warns that those available versions change and a
workflow may need updating. The existing full-test gate pins Xcode 26.6;
public desktop Xcode availability does not prove that the same image and
Simulator runtime are available in this team's Cloud settings. That remains
an account-specific check, not an established compatibility result.

The same reference says external TestFlight distribution requires a clean
build. Do not use a cached internal build's timing to predict that path.
It also documents auto-cancellation as enabled by default for start conditions;
an immutable distribution candidate needs an explicit cancellation policy.

The read-only GitHub repository API reports Heeler as public. GitHub's
[billing documentation][github-billing] says standard hosted runners in public
repositories are free, including the current standard `macos-26` jobs.
Larger runners and storage have separate charging rules. Xcode Cloud therefore
does not have an established compute-cost saving over the existing setup.
Its potential benefits are signing maintenance and Apple-native distribution,
not a measured price or speed improvement.

Apple's [current pricing][pricing], checked on the research date:

| Monthly compute allocation | US monthly price |
| --- | ---: |
| 25 hours | Included with Apple Developer Program membership |
| 100 hours | $49.99 |
| 250 hours | $99.99 |
| 1,000 hours | $399.99 |
| 10,000 hours | $3,999.99 |

Usage is across the team and sums task time, including parallel tasks. Apple
gives five 12-minute tests as one compute hour. Unused hours do not roll over.
No Heeler Cloud timing or quota-fit measurement was performed; GitHub timing
cannot establish Cloud speed or how many uploads fit in 25 hours.

## A bounded pilot, only after approval

1. Confirm team access, agreements, repository connection permissions, Cloud
   quota, selected Xcode/macOS image, and App Store-capable signing for every
   target. Initial setup uses Xcode and changes shared Apple/GitHub state.
2. Start with manual-only, nondistributing validation. Archive the committed
   project, resolve exact dependencies, run native artifact checks, and inspect
   the artifact's versions, source revision, entitlements, and symbols. Even a
   nondistributing Cloud build can consume Cloud compute and a Cloud run number;
   it is not equivalent to the old no-number-consumption rehearsal contract.
3. Keep the full GitHub gate on the exact candidate. If adopting the hybrid,
   dispatch Cloud only after that gate passes, using an immutable source ref;
   verify the resulting checkout and run identity rather than selecting today's
   `main`. Do not turn on an independent auto-distribution tag trigger as well.
4. Exercise a same-source rebuild without distribution and observe numbering.
   Choose whether to accept Cloud ownership; do not make the old design claim
   tag/build equality before observing the real service behavior.
5. Only with separate upload approval, enable **TestFlight and App Store**
   distribution and validate processing, tester delivery, exported symbols,
   and a durable mapping of source SHA, marketing version, Cloud run/build
   number, Apple build ID, and build-tag record. Confirm App Store eligibility
   without actually submitting or publishing the app.
6. Retire the old upload path only after acceptance. Keep record repair separate
   from rebuilding or uploading, and ensure receipt-tag creation cannot loop
   back into another build. Existing tests and plugin publication remain on
   GitHub unless separately redesigned and validated.

Apple also documents [infrastructure validation builds][infrastructure], which
can execute custom scripts again, including duplicate external requests, while
not distributing through the managed TestFlight/App Store path or consuming
build minutes. Hooks that publish tags, upload binaries, or mutate external
systems require special care. Do not bypass managed delivery with an upload
script merely to force the old numbering contract; that introduces additional
idempotency and signing obligations rather than proving compatibility.

## Verification boundary

This study inspects source and official documentation. It does not prove a
Cloud build, dependency download, signature, test result, TestFlight upload,
elapsed-time improvement, or successful App Store submission. Team enrollment,
account roles, selected Cloud environment, quotas, and existing Apple build
inventory were not inspected.

[workflow]: https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference
[github-billing]: https://docs.github.com/en/billing/concepts/product-billing/github-actions
[scripts]: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
[numbering]: https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds
[starts]: https://developer.apple.com/documentation/xcode/configuring-start-conditions
[tag-patterns]: https://developer.apple.com/documentation/appstoreconnectapi/citagpatterns/patterns-data.dictionary
[create-run]: https://developer.apple.com/documentation/appstoreconnectapi/post-v1-cibuildruns
[run-attributes]: https://developer.apple.com/tutorials/data/documentation/appstoreconnectapi/cibuildruncreaterequest/data-data.dictionary/attributes-data.dictionary.json
[setup]: https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud
[distribution]: https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution
[choose-build]: https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/
[dependencies]: https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud
[actions]: https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions
[runs]: https://developer.apple.com/documentation/appstoreconnectapi/build-runs
[artifacts]: https://developer.apple.com/documentation/appstoreconnectapi/get-v1-cibuildactions-_id_-artifacts
[webhooks]: https://developer.apple.com/documentation/xcode/configuring-webhooks-in-xcode-cloud
[pr-checks]: https://developer.apple.com/documentation/xcode/configuring-requirements-for-merging-a-pull-request
[first-workflow]: https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow
[testflight]: https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight
[internal-testers]: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
[pricing]: https://developer.apple.com/xcode-cloud/get-started/
[infrastructure]: https://developer.apple.com/documentation/xcode/understanding-infrastructure-validation-builds
