# iOS CI runtime study

Study date: 2026-10-03. Source baseline:
`eefba7d46efe91668a4b5b0f05588732875225a7`.

The app CI can be shortened without removing tests, but the useful changes
are execution and build reuse, rather than deleting suites. Three independent
reviews covered historical timing, coverage and isolation, and execution
mechanisms. The historical analysis below predates implementation. Proposed
savings remain estimates until the hosted experiment described below completes.

The current execution constraint is **GitHub-hosted macOS runners**, preserving
all test coverage. Ten minutes is a preference, not a hard acceptance limit;
a somewhat longer gate is acceptable. Compare the complete first run without
restored dependency or compiled-output caches with subsequent runs separately.
Further independent reviews examined cold compilation, finer sharding, and
the package lane. The earlier ten-minute analysis below is an exploratory
scenario. Its local compilation-cold probe is evidence for that one build,
not a proposed execution environment or a complete replacement CI.

## Implementation experiment

The workflow now uses three independently compiled app workers and the existing
package worker on `macos-26`, with Xcode 26.6 pinned. Compilation starts after
the worker claims its Simulator, while the parent prepares that Simulator and
its fixtures. The ordinary worker provisions no SSH fixtures. Test selection,
mandatory behavior assertions, signing, and destination recovery remain active.
The mandatory package worker runs the watchdog and gate-guard regression checks
once on macOS, while app workers start their builds. Each app worker retains its
own native Simulator and fixture checks, and the aggregate requires the package
worker's checks to pass.

`CI / Build & test (iOS Simulator)` is the stable aggregate check. It requires
every worker to succeed, then validates exported test methods, parameter case
identities, exact fixture counts, and ordinary skip provenance. A completion
record is created only after the runner and its cleanup return successfully.
Missing, cancelled, failed, or inconsistent worker evidence fails the aggregate.
Evidence names include the run and worker, and a rerun replaces that worker's
artifact. Partial reruns can retain successful same-run, same-SHA prerequisites;
the aggregate still requires every worker's current result to succeed.

The serial comparison retains the original test-call order on the same code and
toolchain, with build/preparation overlap disabled. Both layouts explicitly
disable native compilation caching and use fresh DerivedData. Warm mode restores
only dependency sources; cold mode skips both cache restore and save. These
controls distinguish a first dependency-cold run from a compilation-cold run
whose dependency sources were restored.
CI builds also set `GCC_GENERATE_DEBUGGING_SYMBOLS=NO` to avoid DWARF generation
([Apple build settings](https://developer.apple.com/documentation/xcode/build-settings-reference)),
while retaining Debug configuration, `-Onone`, assertions, and testability.
This reduces crash file/line symbolication and LLDB variable information; the
normal Swift Testing failure locations remain available. Local builds retain
their default symbol settings. Hosted performance benefits remain unverified
until a complete run with this policy succeeds.
Cold and warm app runs permit a 20-minute build deadline: hosted compilation
has reached the final embedded-binary validation stage at the former 15-minute
cutoff. This is a safety limit for runner variance, not a performance target.
Test deadlines and the normal PR's 32-minute app step deadline remain unchanged.
The explicit serial comparison has a 45-minute step and 50-minute job safety
limit, allowing its original sequential setup and four test calls to finish.

Local non-native checks use:

```sh
make test-tools test-ci-guards test-ci-watchdog
actionlint .github/workflows/ci.yml
```

The watchdog target also runs the Simulator recovery and shard-dispatch guards;
`make test-ci-recovery` remains available to run those checks directly.

Hosted benchmarks use the pushed implementation branch. Run these sequentially
to avoid competing for the shared macOS concurrency quota:

```sh
gh workflow run ci.yml --ref chore/ci-runtime-study \
  -f layout=serial -f cache_mode=warm
# Wait for the serial run to pass, then use its run ID below.
gh workflow run ci.yml --ref chore/ci-runtime-study \
  -f layout=sharded -f cache_mode=cold -f baseline_run=SERIAL_RUN_ID
```

The sharded aggregate compares the complete passing method and argument-case
union with the same-SHA serial run. Worker artifacts include the checkout SHA,
toolchain identity, per-phase results, and preparation/build/test timing. Report
complete workflow elapsed time, runner execution time, cache mode, and any
queueing separately. Synthetic guard tests and historical result-schema checks
do not establish native equivalence or optimized hosted runtime.

The experiment targets `main` after the navigation/tooling changes in #401.
It keeps app sources and the committed project unchanged. One parameterized
control-sequence test now accepts byte arrays instead of `Data`, then converts
each array to the identical `Data` input. Its three inputs and assertions are
preserved. Coverage export still rejects indistinguishable argument values or
repetitions; the hosted run must verify three distinct case identities.
Hosted results are pending at implementation preparation time. The evidence
recorder retains the native reader's raw reports before its coverage parsing;
re-reading a result bundle with another Xcode version can change that report.

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

## Current recommendation on GitHub-hosted runners

Use the current standard `macos-26` image as the baseline. Favor a smaller
three-worker app topology before the earlier five-worker scenario:

| App worker | Selection and order |
| --- | --- |
| Session and WeakNetwork | Session 13 in its original call, stop the password sshd immediately, then all 10 WeakNetwork tests in a separate process with an exclusive proxy |
| Ordered transport | Direct streamlocal 9, then the six non-Weak shared suites, 106 tests |
| Ordinary regression | The complete ordinary target, retaining fixture skip provenance from the other workers |

Session and WeakNetwork remain separate calls. Static review found no mutual
proxy or stale-socket dependency, but this regrouping requires native mandatory
fixture validation before it is equivalent. Direct remains before
TransportBehavior. Each worker owns its Simulator, fixture state, preferences,
keys and processes. Preserve the full method and parameterized-case union,
exact mandatory counts and every existing behavior assertion in a final gate.
The original package lane runs alongside these three app workers and keeps all
70 tests and five suites.

For the first implementation experiment, compare worker-local compilation
concurrent with fixture preparation against one build followed by artifact
fan-out. Starting three self-contained workers together avoids a separate
post-build preparation barrier and product relocation, but duplicates cold
compilation and dependency downloads. A build-once fan-out saves total build
work while adding product transfer and fresh-worker preparation after the
build. Do not attribute preparation/build overlap to ordinary `needs: build`
scheduling. Measure the user-facing critical path and total runner work before
choosing the final topology.

The modeled prepared tail for the three groups is approximately 283-324,
246-288, and 287-312 seconds respectively. With the observed 499-630-second
build and ideal worker-local build/preparation overlap, this gives roughly
**13-16 minutes plus other overhead**, with a dependency-source cache hit
but no compiled-output reuse. This is a scenario, not an optimized-run result.
Let `D` be the extra first-run dependency fetch and `O` include queueing, checks,
result evidence transfer and aggregation: a completely cache-empty first run
is modeled as `max(build + D, preparation) + test tail + O`. Neither `D` nor
all of `O` has been measured for this topology. A 15-20-minute gate is a useful
initial optimization objective; a truly first-cold run may exceed it.
Compiled-cache benefits on subsequent runs also require a separate benchmark.

GitHub's [Actions limits](https://docs.github.com/en/actions/reference/limits)
currently allow five concurrent macOS jobs on Free, Pro and Team plans. Three
app workers plus package use four slots for one PR, leaving some headroom;
other PRs and workflows still consume the same quota. The earlier five app
workers plus package cannot all run concurrently at that default limit.

Keep initial changes focused on phase attribution, build/preparation overlap,
the three groups above, and CI-only indexing as an independent build
experiment. `COMPILER_INDEX_STORE_ENABLE=NO` can avoid editor index output,
but its hosted savings are unmeasured. Pin and record the actual Xcode 26.6
identity for the comparison; pinning is not itself a speedup.

An independent hosted toolchain experiment is also available:
GitHub's [Xcode 27 image announcement](https://github.com/actions/runner-images/issues/14404)
documents the `xcode-27` public-preview label. The current
[image manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
lists Xcode 27.0 and iOS 27.0 simulators, whereas
[macos-26](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
only has Xcode 26.x. This changes SDK/runtime and requires the complete original
matrix and coverage checks. It is not a hardware upgrade or a confirmed
speedup, and preview availability/queueing needs measurement. Keep it separate
from the workflow-topology experiment and the local probe evidence.

## Earlier ten-minute model: execution environment and topology

Further splitting can shorten the test tail, but the existing cold build is
already 499-630 seconds, with a dependency-source cache hit. A conservative
five-worker app topology preserves suite order and mutable-state ownership:

| Worker | Selection | Modeled time after preparation |
| --- | --- | ---: |
| Session | All 13 Session tests, retaining the Session-only password-server window | 93 s |
| Ordered transport | Direct streamlocal 9, then the six non-Weak shared suites, 106 tests | About 246 s |
| Weak network | All 10 WeakNetwork tests, including Changes extensions, serial with an exclusive proxy | About 185-200 s |
| Ordinary A | Duration-balanced intact suites on an independent UI-capable Simulator | About 130-200 s |
| Ordinary B | The remaining ordinary suites on another independent UI-capable Simulator | About 130-200 s |

These are historical-body and launch-overhead models, not candidate timings.
The two ordinary selections together must execute the entire ordinary target,
including future tests and parameterized cases. Preserve Direct before
TransportBehavior; keep WeakNetwork's proxy and process isolated. Pairing
authorized keys, fixture homes, accounts, sockets, and ports also belong to
their worker. Multiple runners on one physical Mac need separate mutable
fixture state and measured resource contention; separate Simulators alone
are insufficient.

With compilation and worker preparation overlapped, the critical path is
`max(build, preparation) + prepared test tail + overhead`. Even ideal overlap
on the measured standard runner gives `499-630 + 246 = 745-876 seconds`, or
12.4-14.6 minutes before queueing, transfer, and result aggregation. A normal
`needs: build` fan-out instead starts fresh-worker preparation after the build;
the observed 177-285-second preparation then adds to this path. More shards
alone do not establish a ten-minute first run.

The earlier ten-minute scenario combines a faster compatible execution
environment, about five isolated app test workers, and preparation that
overlaps compilation. An illustrative allocation is at most four minutes
for overlapped build/preparation, five minutes for the prepared test tail, and
one minute for queue/transfer/aggregation. These are acceptance budgets, not
predictions. Eager prepared workers waiting for a verified artifact, or
worker-local compilation concurrent with provisioning, require bounded waits,
SHA/toolchain checks, cancellation and owned-child cleanup. The latter also
duplicates compilation. Measure actual capacity before choosing either.

### One measured local compilation-cold probe

The source baseline was built on an Apple M3 Max with 16 logical CPUs and
64 GiB RAM. The probe used fresh project DerivedData,
`COMPILATION_CACHE_ENABLE_CACHING=NO`, the genuine app resources and icon, and
the documented `make test-app` entrypoint. It compiled the app and its complete
test target, then selected
`HerdrSocketLocationTests/defaultSessionLivesUnderConfigDir()`.

| Measurement | Result |
| --- | ---: |
| Complete make invocation | 120.07 s |
| Structured xcresult root build activity | 77.845 s |
| Testing operation, including startup and teardown | 8.743 s |
| Selected tests | 1 executed, 1 passed, 0 skipped; selector verified |
| Actual AppIcon compilation activity | 3.598 s |

This used Xcode 27.0 (27A266a), Simulator SDK 27.0, and iOS 26.5 runtime, whereas
hosted CI used Xcode 26.6 and SDK 26.5. It reused dependency sources and binary
downloads, did not clear machine-wide SDK caches, and ran `test` with one
selector rather than the CI sequence. The local icon task also used
destination-thinning flags absent from the historical hosted invocation.
Hardware, toolchain and task behavior all differ, so the result cannot isolate
their individual effects or prove a dependency-cold run. It does establish a
successful build and one native test without restored project compilation
outputs. It is not full App, real-SSH, package, or optimized-CI validation.
The disposable probe Simulator was shut down and removed after completion.

The structured build log also shows a 46.598-second interval of overlapping
test compilation. Its sixteen batch durations must not be summed as serial
wall time. The 86.598-second testing-action interval includes the test stage;
the 77.845-second build activity is the appropriate build figure.

GitHub's [standard runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
list three CPU cores and 7 GB for the current arm64 macOS runner. Faster
execution is a credible experiment, but the local probe does not prove the
benefit of hardware alone. GitHub's
[larger runners](https://docs.github.com/en/actions/reference/runners/larger-runners)
require an organization on an eligible Team or Enterprise plan. This public
repository is currently owned by an individual, so merely changing its
`runs-on` label is not a deployment path for larger runners. The current
recommendation uses the repository's standard hosted runners. No runner was
registered and no infrastructure or billing was changed.

### The package lane must also fit

In [run 37046551829](https://github.com/ZingerLittleBee/Heeler/actions/runs/37046551829),
the package job passed at the study baseline in **11:05**. Its setup before
build took 279.8 seconds, build 126.3 seconds, post-build environment/boot
15 seconds, and test invocation 196.8 seconds. The actual 70-test, five-suite
body took 133.001 seconds with zero skips. The remaining time includes cleanup
and job overhead. Other recent successful package jobs ranged from 9:22 to
10:55; queueing before job start is additional.

Fully overlapping this package build with independent preparation would have
an arithmetic saving ceiling of 126 seconds in that run, giving about 8:59
before contention changes. This is not a measured candidate or a tail-latency
guarantee. Investigate package-specific fixture provisioning as well, after
tracing every consumer; the existing log cannot attribute its long setup to
individual operations. Keep all 70 tests, five suites, serialized SessionDriver
resource behavior, and every named assertion. Run package work alongside the
app lanes; its duration still limits complete PR completion.

The app job in that same run failed one ordinary UI test,
`aLayoutSwitchKeepsTheTopmostLine()`, at an eight-second `eventually` assertion.
The cause is not established by this timing study. Its failed run is not a
passing coverage baseline and this study does not repair that failure.

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

## Supporting implementation experiments

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
5. Compare complete hosted durations and failure behavior, with at least a
   first run without restored dependency-source or compiled-output caches and
   a warm run, rather than only local compiler timings. Include initial
   dependency downloads, provisioning, queueing, transfer, and aggregation in
   the first-run result, and report it against the ten-minute preference without
   treating that preference as a hard gate. Keep the mandatory
   tests on PRs; do not move them exclusively to nightly runs or replace real
   SSH and Simulator execution with mocks.

Before implementation, evidence consisted of existing GitHub logs/metadata, repository source,
official execution documentation, and the single local compilation-cold
probe described above. At that point, no complete native App/SSH matrix, cache benchmark,
optimized CI, or fully dependency-cold run was performed. No workflow was
dispatched or cancelled; no source/workflow implementation, runner
registration, push, infrastructure, or billing mutation was made.
