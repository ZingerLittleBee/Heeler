# iOS CI runtime study

Study date: 2026-10-03. Source baseline:
`eefba7d46efe91668a4b5b0f05588732875225a7`.

The app CI can be shortened without removing tests, but the useful changes
are execution and build reuse, rather than deleting suites. Three independent
reviews covered historical timing, coverage and isolation, and execution
mechanisms. This study changes no workflow or test implementation. Proposed
savings are estimates, not measurements of an optimized candidate.

## Measured baseline

These are completed successful runs preceding the study baseline. Their results
are timing evidence, not runtime validation of `eefba7d4`.

| Run | SHA | App job | Fixture setup | Build | Fixture test calls | Full app call |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| [37040027795](https://github.com/ZingerLittleBee/Heeler/actions/runs/37040027795) | `ad36289e` | 28:54 | 248 s | 630 s | 479 s | 289 s |
| [37035750637](https://github.com/ZingerLittleBee/Heeler/actions/runs/37035750637) | `3a4d4676` | 28:06 | 177 s | 576 s | 532 s | 312 s |
| [37028697176](https://github.com/ZingerLittleBee/Heeler/actions/runs/37028697176) | `9b8be2d9` | 27:56 | 285 s | 499 s | 529 s | 287 s |

In the first run, the build-and-test step took 1,675 seconds. Setup, build,
four test calls, and the final six-second boot wait account for 1,652 seconds.
The remaining approximately 23 seconds contain environment work, assertions,
server start/stop, and cleanup. Everything outside that step took 59 seconds.
None of the three successful logs contains destination-recovery retries.

The hosted toolchain was Xcode 26.6 (17F113). The SwiftPM cache hit exactly;
there were no new dependency downloads. Every build uses a fresh
`/tmp/heeler-ci.XXXXXX/AppDerivedData`, so the dependency checkout cache does
not preserve the compiled app, test bundle, or asset intermediates.

Two areas need better attribution:

- Setup takes 177-285 seconds, with few successful-operation timestamps.
  `simctl boot` is called synchronously before the build and discards output
  ([runner](../../scripts/run-ci-ios-tests.sh), line 1213). The later 4-6 second
  boot wait does not establish that initial boot was fully overlapped.
  The package job has a similar silent setup interval without a password
  fixture, so account creation is not an established sole cause.
- AppIcon asset compilation to results spans 193-215 seconds. Xcode buffers
  output and tasks can overlap; this is a hotspot to time, not a guaranteed
  three-minute saving. App and test compilation also occupy much of the build.

The four test calls in the first run took approximately 768 seconds, while
their reported Swift Testing bodies took 506 seconds. About 262 seconds is
preparation, installation, host startup, result handling, and restoration
combined. Repeated package-graph resolution accounts for only 7.19 seconds of
that gap. Existing logs cannot assign the remaining gap to one mechanism.
These historical runs also predate the new xcresult selector verifier.

## Coverage that must remain

The app already builds once, then makes four `test-without-building` calls:

| Call | Current contract |
| --- | --- |
| Session | 13 tests, 1 suite, no skips in mandatory CI |
| Direct streamlocal | 9 tests, 1 suite, no skips |
| Shared fixtures | 116 tests, 7 suites, no skips |
| Full app | All app tests selected; fixture skips require passing evidence elsewhere |

The measured full app runs registered 2,466 tests, executed 2,328, and skipped
138. Those skips correspond to the 13 + 9 + 116 fixture tests already proved
by the earlier calls. Their bodies are not executed twice. Removing their
discovery and skip lines is not a demonstrated large saving.

Preserve the exact fixture counts, named behavior assertions, nonzero result
and selector checks, and skip provenance in the
[runner](../../scripts/run-ci-ios-tests.sh). The current full-app floor is 769;
it is a historical lower bound, not proof that a refactor still executes every
current test. Hosted CI must continue failing when required fixtures are
missing. Keep authentication, Jump Host, Events, Attach, resize, PTY, SFTP,
Pairing, Changes, cancellation, teardown, and weak-network coverage, plus the
full-app admission, Keychain, TOFU, algorithm, and signing assertions.

Direct streamlocal must finish before TransportBehavior, which recreates and
links the stale socket that the former expects to remain stale. Weak-network
tests share an impairment proxy and measure process-wide descriptor counts.
Pairing shares a disposable authorized-keys file. A Simulator owns fixture
environment variables, accessibility preferences, app data, and Keychain state.
Different ports and DerivedData do not make one shared Simulator safe for
concurrent lanes. Blanket parallel execution is therefore inappropriate.

The separate package job proves 70 tests in 5 suites and already runs alongside
the app job. It covers lower-level SessionDriver behavior and is not redundant
with the product-level app suite. Removing that job would not shorten the
current app critical path.

## Recommended changes, in order

### 1. Attribute setup and build, then overlap independent work

Add start/end durations around initial simulator boot, key generation, password
account creation and preflight, and fixture readiness. Collect a build timing
summary or build trace for compilation and assets. Do not print credentials,
private key material, or fixture configuration.

Evaluate running compilation while independent fixture preparation completes.
The measured setup interval gives a 177-285 second upper bound on overlap,
not a guaranteed saving: boot, compilation, and setup may compete for resources.
Preserve readiness checks, password preflight, locks, destination recovery,
watchdogs, diagnostics, and cancellation cleanup. The runner deliberately keeps
`run_xcodebuild` in its calling shell so recovery can update the active UDID;
naively backgrounding that function would lose those updates.

This is the first implementation experiment because it keeps the existing test
topology and coverage contracts intact. It changes failure timing, so cancel
and reap an in-flight build if provisioning fails, and vice versa.

### 2. Test compiled-output reuse independently

Benchmark a stable DerivedData path or toolchain-supported compilation cache,
with a cold-cache fallback. Include Xcode build/SDK/architecture, project and
scheme inputs, resolved packages and binary artifacts in invalidation; preserve
correct incremental rebuilding for changed sources, resources, and tests.
Do not substitute a cached test result for execution on the candidate.

[Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
document opt-in native compilation caching. Evaluate
`COMPILATION_CACHE_ENABLE_CACHING=YES` with
`COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES`, and identify the actual hosted
cache location rather than assuming the local Xcode 27 layout. These settings
are described in [Apple's build-settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference).

A warm-cache experiment must report restore/save overhead and build time,
including asset work. The existing source cache already hits, so enlarging it
alone is not the useful experiment. No compiled-output cache saving has been
measured in this study.

### 3. Parallelize full app and real-SSH execution on separate runners

For a larger change, build the committed project once and transfer complete
test products to two isolated runners: full app regression and the ordered
real-SSH fixture lane. Preserve app signing and Keychain entitlements, framework
contents, architecture, and relocatable test-manifest paths. Each runner owns
its Simulator and mutable state. A stable final gate requires both results and
retains all count, named-behavior, and skip-provenance checks.

Apple documents separate build and test machines in
[Testing in Xcode](https://developer.apple.com/videos/play/wwdc2019/413/).
Archive the products before upload to preserve executable permissions and
symlinks; raw files uploaded with
[upload-artifact v4](https://github.com/actions/upload-artifact/blob/v4/README.md)
do not preserve executable permissions. Verify exact toolchain compatibility
and artifact provenance before running them.

Using the first run as a simple model, the test/setup portion changes from
`248 + 479 + 289 = 1,016 s` to `max(248 + 479, 289) = 727 s`, before artifact,
queue, and startup costs. This removes at most about 4.8 minutes from that
critical path. It does not make setup overlap the preceding build by itself;
do not add both savings without modeling the actual topology. Extra runners
can shorten waiting while increasing total runner work.

If testing from `.xctestrun`, preserve phase-specific environment semantics:
the scheme's `HEELER_SSH_E2E_REQUIRED` value is frozen into the built manifest,
while fixture execution requires `1` and full app execution requires `0`.
Separate phase manifests or a verified equivalent are needed. Reusing one
unchanged manifest can alter missing-fixture behavior. The observed graph
resolution cost is small, so manifest use is primarily an artifact/scheduling
mechanism, not a demonstrated multi-minute speedup.
The supported build/test manifest commands are documented in
[Apple's command-line testing note](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

### 4. Consider merging the two short fixture calls

Session and Direct streamlocal have no identified mutual state conflict in the
static review. Combining their selections may remove one host launch. Keep
SharedFixture separate so Direct finishes before TransportBehavior. Independently
verify 13 and 9 passed tests with zero skips, rather than only the total 22 or
two nonempty selectors. Preserve named assertions and coverage provenance.

This extends the privileged password sshd's active window to the combined call
unless a reliable boundary is introduced. Retain separate calls if the current
Session-only window must remain exact. Native mandatory-fixture validation is
required before treating the combination as equivalent. Savings are a subset
of the measured launch overhead and have not been benchmarked.

Dependency-aware job routing can avoid unrelated package runs, but that job is
already parallel and does not explain the app's 30-minute duration. Moving
small shell checks also cannot recover the main delay. Keep those checks and
their macOS-specific process/recovery behavior. If routing changes, use a stable
aggregate result with explicit handling of failed, missing, and intentionally
skipped prerequisites. GitHub documents the difference between workflow filters
and conditional skipped jobs in
[required-check troubleshooting](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks).

## Acceptance for an implementation

1. Pin a passing baseline at the implementation base SHA. Preserve all fixture
   and full-app result bundles, executed function and parameterized-case
   identities, skips, named behavior evidence, Xcode, and destination metadata.
2. Compare candidate lane unions with the baseline, including argument-case
   children and passing status. Matching totals alone can hide substitutions.
   If tests are added during a rebase, enumerate the complete candidate target
   and require every added function and case to execute; test removal is out
   of scope. Keep the original fixture-only skip provenance.
3. The existing wrapper normalizes parameter URL queries for selector matching;
   it cannot alone prove parameterized-case equivalence. Use a migration
   verifier that preserves stable case identity and validate it against two
   unchanged passing captures.
4. Keep negative checks for zero tests, partial suites, wrong selectors,
   unexpected skips, missing/cancelled shard evidence, signing, cancellation,
   recovery, and cleanup. Update topology-specific guard fixtures without
   weakening their safety and behavior assertions.
5. Compare complete hosted durations and failure behavior, with at least a cold
   and a warm build, rather than only local compiler timings. Keep the mandatory
   tests on PRs; do not move them exclusively to nightly runs or replace real
   SSH and Simulator execution with mocks.

Only existing GitHub logs/metadata, repository source, and official execution
documentation were inspected. No workflow was dispatched or cancelled, and no
new native build, test run, cache benchmark, or optimized CI run was performed.
