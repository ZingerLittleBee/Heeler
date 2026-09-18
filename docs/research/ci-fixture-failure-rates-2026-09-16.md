# CI fixture failure measurement, 2026-09-16

Follow-up to [#332](https://github.com/ZingerLittleBee/Heeler/issues/332), part of
[#327](https://github.com/ZingerLittleBee/Heeler/issues/327).

## Decision

The observed failure rate per completed fixture suite is materially higher than
for other suites, enough to prioritize a focused investigation of fixture
provisioning/readiness and connection-phase diagnostics. It does **not** establish
that fixtures cause the failures or dominate failed CI runs. Do not add blanket
connect retries, widen Host exec timeouts, or weaken product assertions on this
evidence. A handshake-only retry needs evidence that a transient connection phase
is responsible and that retrying preserves the error classification.

Keep #332 as a measurement/re-triage item until this finding is reviewed. The next
bounded investigation should preserve the failing phase and sshd/provisioning
logs, distinguish pre-test provisioning exits from test failures, and compare
same-tree outcomes. No tests or production connection behavior change in this
measurement.

## Window and coverage

- Snapshot: the newest 100 completed `ci.yml` runs retrieved on 2026-09-16.
- Run creation window, inclusive: **2026-09-09 13:31:41 UTC through
  2026-09-15 17:42:56 UTC**. This is a fixed run-count sample, not a complete
  calendar-week census.
- Metadata: 43 success, 39 failure, 10 cancelled, 8 action-required runs.
- Exclude cancelled/action-required runs. Of the remaining 82, **74 log archives
  were available** (43 success, 31 failure). Eight failed-run archives returned
  HTTP 404; their outcomes cannot be classified from these logs. They are listed
  in the appendix, not treated as passes. All missing archives are failures, so
  the available-log rates are subject to selection bias.
- Use each run's **latest attempt only**, as pinned in the appendix. The available
  set contains 65 first attempts, seven second attempts, and two third attempts.
  These archives contain 142 app/package job logs. Successful jobs retained from
  earlier attempts are not silently added to the latest-attempt archive.
- 73 available runs contain completed suite outcomes in each comparison group.
  One run failed compilation in both jobs and contributes no suite denominator.

## Results

An observation is one explicit Swift Testing suite completion (`Suite … passed`
or `Suite … failed`), not a job conclusion, test registration, or skipped suite.

| Group | Passed suite executions | Failed suite executions | Completed executions | Failure share |
| --- | ---: | ---: | ---: | ---: |
| Disposable-fixture suites | 547 | 8 | 555 | 1.44% |
| Other suites | 8,267 | 12 | 8,279 | 0.145% |

The descriptive ratio is about **9.9x**. Suite sizes, execution duration, test mix,
and branch changes differ; these are clustered observations, not independent
Bernoulli trials or a causal estimate of flakiness.

| Run-level cross-check | Runs with a failed suite | Runs with an observed suite | Share |
| --- | ---: | ---: | ---: |
| Fixture group | 8 | 73 | 10.96% |
| Other group | 11 | 73 | 15.07% |

Two runs fail in both groups. Thus the high per-suite ratio does **not** mean
fixtures account for most failed runs. The other group includes actual branch
regressions; these are observed failure rates, not proven flake rates.

The fixture group is the nine fixture-gated suites below. All other explicitly
completed suites form the comparison group; DNS lifecycle and socket-candidate
fallback belong there, despite running in the package job.

| Fixture suite | Passed | Failed |
| --- | ---: | ---: |
| HeelerSSH session e2e | 61 | 0 |
| HeelerSSH PTY e2e | 61 | 0 |
| HeelerSSH direct-streamlocal e2e | 61 | 0 |
| HeelerSSH Jump Host gate e2e | 60 | 1 |
| HeelerSSH Transport behavior e2e | 60 | 1 |
| Image staging e2e | 61 | 0 |
| Pairing ceremony e2e | 59 | 2 |
| Weak network e2e | 60 | 1 |
| Session driver resource e2e | 64 | 3 |

Fixture classification follows the suite gates and mandatory selectors in
`Tests/HeelerTests/*E2ETests.swift`,
`Packages/HeelerSSH/Tests/HeelerSSHTests/SessionDriverE2ETests.swift`, and
`scripts/run-ci-ios-tests.sh` at local base `3014e61`, rather than inferring it
from job names. The nine names are observed in the archived logs. Test counts
vary across the window, so no fixed 49/53-test denominator is assumed.

## Failure evidence and boundaries

The eight fixture suite failures cover nine failing test executions:

| Run | Fixture suite | Observed failure |
| --- | --- | --- |
| [34943488357](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943488357) | Pairing ceremony | Cancellation test expected `CancellationError`, got `hostUnreachable(connectionFailed)`. |
| [34827623740](https://github.com/ZingerLittleBee/Heeler/actions/runs/34827623740) | Transport behavior | Host exec discovery threw `timedOut` after about 15.17s. |
| [34824689671](https://github.com/ZingerLittleBee/Heeler/actions/runs/34824689671) | Session driver | Post-quantum handshake threw `connectionFailed` after about 0.63s. |
| [34755297503](https://github.com/ZingerLittleBee/Heeler/actions/runs/34755297503) | Pairing ceremony | Enrollment verification recorded an issue; this is not evidence of a connection-only failure. |
| [34754031074](https://github.com/ZingerLittleBee/Heeler/actions/runs/34754031074) | Weak network | Bandwidth-starvation test got an unusable SSH connection error. |
| [34681836916](https://github.com/ZingerLittleBee/Heeler/actions/runs/34681836916) | Jump Host gate | Forwarding-denial assertion got `connectionFailed` instead of `tcpForwardingUnavailable`. |
| [34680345784](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680345784) | Session driver | Raw-writer launch timed out. The app job also has a Keys keyboard assertion failure. |
| [34507483296](https://github.com/ZingerLittleBee/Heeler/actions/runs/34507483296) | Session driver | Both post-quantum and Curve25519 handshakes timed out. DNS timing also failed in the other group. |

Other failed suites: DNS lifecycle (2), Agent Direct Input (1), Keys keyboard (2),
ContentView activity driver (4), Agent surface replacement (1), Last-known agents
(1), and Host session switcher store (1). In particular, the keyboard and session
selectability assertions must not be relabelled as infrastructure flakes.

The five original same-tree controls were independently rechecked with GitHub's
Git commits API. Runs 34820452662, 34824689671, 34826906866, 34827623740, and
34829350342 all resolve to tree
`11404ad4485e2d2e0ba2619c6f22324f2cd1acad`; the last passes both jobs. This confirms
non-deterministic outcomes on that tree, but does not exclude a product race.
Only two fixture failures in this table have that same-tree control.

Failures outside suite denominators:

- Nine job logs across eight runs contain Swift compilation errors. None becomes
  a failed fixture suite or a flake in this analysis.
- Run [34826906866](https://github.com/ZingerLittleBee/Heeler/actions/runs/34826906866)
  fails destination discovery before app tests. Keep it under #331.
- Four app jobs exit 1 during fixture setup before any app suite runs:
  [34972265695](https://github.com/ZingerLittleBee/Heeler/actions/runs/34972265695),
  [34943119262](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943119262),
  [34510047194](https://github.com/ZingerLittleBee/Heeler/actions/runs/34510047194),
  and [34485830686](https://github.com/ZingerLittleBee/Heeler/actions/runs/34485830686).
  The logs show device claims followed by password-account cleanup without
  reaching xcodebuild; the precise failed provisioning command is not established.
  These are additional provisioning investigation candidates, not suite failures
  or evidence of password-account lock contention.
- Run [34502810856](https://github.com/ZingerLittleBee/Heeler/actions/runs/34502810856)
  passes its executed fixture suites, then fails the gate's expected-count check
  (`SharedFixtureE2ETests did not execute all 94 tests`). Count the explicit
  passing suites as passes and retain the job's separate gate failure.
- Two suite starts have no matching completion line in the retrieved log:
  `Notification config file (notify.json)` in 34754125324 and `Agent switcher` in
  34682883910. Exclude those two observations instead of inventing an outcome.
  The latter run is successful, so a missing line is not proof of a hung suite.
- Freestanding tests without a suite completion are outside this suite-based
  denominator. All recorded test failures in the available sample were reviewed
  alongside their failing suite.

The available `main` subset has 10 successful and three failed runs. The three
failures are two pre-test provisioning exits and one ContentView activity-driver
assertion failure. The original report's historical "last eight main runs green"
statement is not a current premise of this measurement.

## Reproduction

The appendix freezes the run IDs and attempts; querying "latest 100" again will
produce a different sample. Initial metadata query:

```sh
gh api 'repos/ZingerLittleBee/Heeler/actions/workflows/ci.yml/runs?status=completed&per_page=100'
```

For each eligible appendix row, download its pinned archive:

```sh
gh api "repos/ZingerLittleBee/Heeler/actions/runs/$run_id/attempts/$attempt/logs" > "$run_id-$attempt.zip"
```

Read only the top-level app/package `*.txt` entries in each archive, not the
`*/system.txt` entries. Extract `[✔✘] Suite (.+?) (passed|failed) after`, strip the
optional quotes around the suite name, and classify by the nine-name table.
Ignore skipped lines and test-run summaries. Count each completion once; sum
failed and total executions by group, then separately deduplicate run IDs for
the run-level cross-check. Compare suite starts with completions and inspect all
failed-test lines to identify missing or misattributed results. The report's
appendix provides per-run totals so the aggregates can be checked without access
to raw runner logs. No credentials or raw fixture logs are committed.

## Frozen sample

`F` and `O` are **failed/completed suite executions**, for fixture and other suites.
A dash means excluded/unavailable; `0/0` means the available archive contains no
completed suite in that group. "Available" describes log retrieval, not whether
the run succeeded. Attempts refer only to the archive counted here.

| Run | Created (UTC) | Attempt | Conclusion | F | O | Evidence |
| --- | --- | ---: | --- | ---: | ---: | --- |
| [35002986312](https://github.com/ZingerLittleBee/Heeler/actions/runs/35002986312) | 2026-09-15 17:42:56 | 1 | success | 0/9 | 0/165 | Available |
| [35002756835](https://github.com/ZingerLittleBee/Heeler/actions/runs/35002756835) | 2026-09-15 17:40:41 | 2 | success | 0/8 | 0/163 | Available |
| [35002243641](https://github.com/ZingerLittleBee/Heeler/actions/runs/35002243641) | 2026-09-15 17:35:41 | 1 | cancelled | — | — | Excluded |
| [34997943736](https://github.com/ZingerLittleBee/Heeler/actions/runs/34997943736) | 2026-09-15 16:54:37 | 1 | success | 0/9 | 0/164 | Available |
| [34996521333](https://github.com/ZingerLittleBee/Heeler/actions/runs/34996521333) | 2026-09-15 16:40:52 | 1 | success | 0/9 | 0/164 | Available |
| [34972265695](https://github.com/ZingerLittleBee/Heeler/actions/runs/34972265695) | 2026-09-15 13:00:23 | 1 | failure | 0/1 | 0/2 | Available |
| [34947884098](https://github.com/ZingerLittleBee/Heeler/actions/runs/34947884098) | 2026-09-15 08:36:23 | 1 | success | 0/9 | 0/163 | Available |
| [34945947061](https://github.com/ZingerLittleBee/Heeler/actions/runs/34945947061) | 2026-09-15 08:15:17 | 1 | success | 0/9 | 0/164 | Available |
| [34943488357](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943488357) | 2026-09-15 07:47:14 | 1 | failure | 1/9 | 0/2 | Available |
| [34943377285](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943377285) | 2026-09-15 07:45:55 | 1 | success | 0/9 | 0/164 | Available |
| [34943119262](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943119262) | 2026-09-15 07:43:00 | 1 | failure | 0/1 | 0/2 | Available |
| [34943097233](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943097233) | 2026-09-15 07:42:44 | 1 | success | 0/9 | 0/164 | Available |
| [34943023252](https://github.com/ZingerLittleBee/Heeler/actions/runs/34943023252) | 2026-09-15 07:41:53 | 1 | success | 0/9 | 0/164 | Available |
| [34942979299](https://github.com/ZingerLittleBee/Heeler/actions/runs/34942979299) | 2026-09-15 07:41:22 | 1 | cancelled | — | — | Excluded |
| [34829350342](https://github.com/ZingerLittleBee/Heeler/actions/runs/34829350342) | 2026-09-14 09:42:03 | 1 | success | 0/9 | 0/166 | Available |
| [34827623740](https://github.com/ZingerLittleBee/Heeler/actions/runs/34827623740) | 2026-09-14 09:22:47 | 1 | failure | 1/9 | 0/2 | Available |
| [34826906866](https://github.com/ZingerLittleBee/Heeler/actions/runs/34826906866) | 2026-09-14 09:15:01 | 1 | failure | 0/1 | 0/2 | Available; missing simulator |
| [34824689671](https://github.com/ZingerLittleBee/Heeler/actions/runs/34824689671) | 2026-09-14 08:49:32 | 1 | failure | 1/9 | 0/166 | Available |
| [34820452662](https://github.com/ZingerLittleBee/Heeler/actions/runs/34820452662) | 2026-09-14 07:59:42 | 1 | failure | 0/9 | 1/166 | Available |
| [34818809188](https://github.com/ZingerLittleBee/Heeler/actions/runs/34818809188) | 2026-09-14 07:38:39 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34818741164](https://github.com/ZingerLittleBee/Heeler/actions/runs/34818741164) | 2026-09-14 07:37:45 | 1 | cancelled | — | — | Excluded |
| [34765617472](https://github.com/ZingerLittleBee/Heeler/actions/runs/34765617472) | 2026-09-13 15:26:42 | 2 | success | 0/8 | 0/161 | Available |
| [34763587105](https://github.com/ZingerLittleBee/Heeler/actions/runs/34763587105) | 2026-09-13 14:45:32 | 1 | success | 0/9 | 0/163 | Available |
| [34761144371](https://github.com/ZingerLittleBee/Heeler/actions/runs/34761144371) | 2026-09-13 13:54:36 | 2 | success | 0/8 | 0/161 | Available |
| [34761112357](https://github.com/ZingerLittleBee/Heeler/actions/runs/34761112357) | 2026-09-13 13:53:52 | 1 | cancelled | — | — | Excluded |
| [34756257959](https://github.com/ZingerLittleBee/Heeler/actions/runs/34756257959) | 2026-09-13 12:08:05 | 1 | success | 0/9 | 0/147 | Available |
| [34755376236](https://github.com/ZingerLittleBee/Heeler/actions/runs/34755376236) | 2026-09-13 11:48:01 | 1 | success | 0/9 | 0/147 | Available |
| [34755299097](https://github.com/ZingerLittleBee/Heeler/actions/runs/34755299097) | 2026-09-13 11:46:15 | 1 | success | 0/9 | 0/146 | Available |
| [34755297503](https://github.com/ZingerLittleBee/Heeler/actions/runs/34755297503) | 2026-09-13 11:46:12 | 1 | failure | 1/9 | 0/2 | Available |
| [34754125324](https://github.com/ZingerLittleBee/Heeler/actions/runs/34754125324) | 2026-09-13 11:19:09 | 1 | failure | 0/9 | 1/145 | Available |
| [34754045491](https://github.com/ZingerLittleBee/Heeler/actions/runs/34754045491) | 2026-09-13 11:17:16 | 1 | success | 0/9 | 0/147 | Available |
| [34754031074](https://github.com/ZingerLittleBee/Heeler/actions/runs/34754031074) | 2026-09-13 11:16:57 | 1 | failure | 1/9 | 0/2 | Available |
| [34754024168](https://github.com/ZingerLittleBee/Heeler/actions/runs/34754024168) | 2026-09-13 11:16:49 | 1 | success | 0/9 | 0/147 | Available |
| [34753865238](https://github.com/ZingerLittleBee/Heeler/actions/runs/34753865238) | 2026-09-13 11:13:12 | 1 | cancelled | — | — | Excluded |
| [34742535073](https://github.com/ZingerLittleBee/Heeler/actions/runs/34742535073) | 2026-09-13 06:21:12 | 1 | success | 0/9 | 0/146 | Available |
| [34741129189](https://github.com/ZingerLittleBee/Heeler/actions/runs/34741129189) | 2026-09-13 05:46:36 | 2 | success | 0/8 | 0/144 | Available |
| [34741116110](https://github.com/ZingerLittleBee/Heeler/actions/runs/34741116110) | 2026-09-13 05:46:19 | 1 | cancelled | — | — | Excluded |
| [34703397036](https://github.com/ZingerLittleBee/Heeler/actions/runs/34703397036) | 2026-09-12 15:49:38 | 1 | success | 0/9 | 0/146 | Available |
| [34699063956](https://github.com/ZingerLittleBee/Heeler/actions/runs/34699063956) | 2026-09-12 14:21:44 | 1 | success | 0/9 | 0/146 | Available |
| [34697975015](https://github.com/ZingerLittleBee/Heeler/actions/runs/34697975015) | 2026-09-12 13:59:56 | 2 | success | 0/9 | 0/146 | Available |
| [34694224738](https://github.com/ZingerLittleBee/Heeler/actions/runs/34694224738) | 2026-09-12 12:38:28 | 1 | success | 0/9 | 0/146 | Available |
| [34692731877](https://github.com/ZingerLittleBee/Heeler/actions/runs/34692731877) | 2026-09-12 12:05:33 | 2 | success | 0/9 | 0/146 | Available |
| [34689865191](https://github.com/ZingerLittleBee/Heeler/actions/runs/34689865191) | 2026-09-12 10:59:31 | 1 | success | 0/9 | 0/146 | Available |
| [34682883910](https://github.com/ZingerLittleBee/Heeler/actions/runs/34682883910) | 2026-09-12 08:17:21 | 1 | success | 0/9 | 0/144 | Available |
| [34682884109](https://github.com/ZingerLittleBee/Heeler/actions/runs/34682884109) | 2026-09-12 08:17:21 | 1 | success | 0/9 | 0/145 | Available |
| [34681836916](https://github.com/ZingerLittleBee/Heeler/actions/runs/34681836916) | 2026-09-12 07:52:21 | 1 | failure | 1/9 | 0/2 | Available |
| [34681835366](https://github.com/ZingerLittleBee/Heeler/actions/runs/34681835366) | 2026-09-12 07:52:19 | 1 | success | 0/9 | 0/145 | Available |
| [34681835084](https://github.com/ZingerLittleBee/Heeler/actions/runs/34681835084) | 2026-09-12 07:52:18 | 1 | failure | 0/9 | 1/145 | Available |
| [34680467924](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680467924) | 2026-09-12 07:20:21 | 1 | success | 0/9 | 0/144 | Available |
| [34680442173](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680442173) | 2026-09-12 07:19:50 | 1 | success | 0/9 | 0/144 | Available |
| [34680429024](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680429024) | 2026-09-12 07:19:31 | 1 | success | 0/9 | 0/145 | Available |
| [34680418394](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680418394) | 2026-09-12 07:19:15 | 1 | success | 0/9 | 0/145 | Available |
| [34680360384](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680360384) | 2026-09-12 07:17:56 | 1 | failure | 0/9 | 1/145 | Available |
| [34680358480](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680358480) | 2026-09-12 07:17:53 | 1 | failure | 0/9 | 1/145 | Available |
| [34680345784](https://github.com/ZingerLittleBee/Heeler/actions/runs/34680345784) | 2026-09-12 07:17:36 | 1 | failure | 1/9 | 1/145 | Available |
| [34671958890](https://github.com/ZingerLittleBee/Heeler/actions/runs/34671958890) | 2026-09-12 04:02:41 | 1 | success | 0/9 | 0/144 | Available |
| [34510061498](https://github.com/ZingerLittleBee/Heeler/actions/runs/34510061498) | 2026-09-10 17:44:34 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34510047194](https://github.com/ZingerLittleBee/Heeler/actions/runs/34510047194) | 2026-09-10 17:44:26 | 1 | failure | 0/1 | 0/2 | Available |
| [34510048095](https://github.com/ZingerLittleBee/Heeler/actions/runs/34510048095) | 2026-09-10 17:44:26 | 1 | failure | 0/9 | 1/144 | Available |
| [34507483296](https://github.com/ZingerLittleBee/Heeler/actions/runs/34507483296) | 2026-09-10 17:19:16 | 1 | failure | 1/9 | 1/144 | Available |
| [34507236121](https://github.com/ZingerLittleBee/Heeler/actions/runs/34507236121) | 2026-09-10 17:16:51 | 1 | cancelled | — | — | Excluded |
| [34507182166](https://github.com/ZingerLittleBee/Heeler/actions/runs/34507182166) | 2026-09-10 17:16:20 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34507176887](https://github.com/ZingerLittleBee/Heeler/actions/runs/34507176887) | 2026-09-10 17:16:17 | 1 | success | 0/9 | 0/143 | Available |
| [34506961577](https://github.com/ZingerLittleBee/Heeler/actions/runs/34506961577) | 2026-09-10 17:14:15 | 1 | failure | 0/9 | 1/144 | Available |
| [34506957853](https://github.com/ZingerLittleBee/Heeler/actions/runs/34506957853) | 2026-09-10 17:14:13 | 1 | cancelled | — | — | Excluded |
| [34506956406](https://github.com/ZingerLittleBee/Heeler/actions/runs/34506956406) | 2026-09-10 17:14:12 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34503321948](https://github.com/ZingerLittleBee/Heeler/actions/runs/34503321948) | 2026-09-10 16:38:18 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34503320141](https://github.com/ZingerLittleBee/Heeler/actions/runs/34503320141) | 2026-09-10 16:38:17 | 1 | failure | 0/0 | 0/0 | Available; compile error |
| [34503318092](https://github.com/ZingerLittleBee/Heeler/actions/runs/34503318092) | 2026-09-10 16:38:16 | 1 | success | 0/9 | 0/144 | Available |
| [34503312589](https://github.com/ZingerLittleBee/Heeler/actions/runs/34503312589) | 2026-09-10 16:38:12 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34503311439](https://github.com/ZingerLittleBee/Heeler/actions/runs/34503311439) | 2026-09-10 16:38:11 | 1 | success | 0/9 | 0/144 | Available |
| [34502810856](https://github.com/ZingerLittleBee/Heeler/actions/runs/34502810856) | 2026-09-10 16:33:17 | 1 | failure | 0/9 | 0/2 | Available |
| [34502488188](https://github.com/ZingerLittleBee/Heeler/actions/runs/34502488188) | 2026-09-10 16:30:09 | 1 | cancelled | — | — | Excluded |
| [34502027441](https://github.com/ZingerLittleBee/Heeler/actions/runs/34502027441) | 2026-09-10 16:25:44 | 1 | failure | 0/1 | 0/2 | Available; compile error |
| [34502003446](https://github.com/ZingerLittleBee/Heeler/actions/runs/34502003446) | 2026-09-10 16:25:31 | 1 | failure | 0/9 | 2/144 | Available |
| [34501153298](https://github.com/ZingerLittleBee/Heeler/actions/runs/34501153298) | 2026-09-10 16:17:29 | 1 | success | 0/9 | 0/143 | Available |
| [34498419509](https://github.com/ZingerLittleBee/Heeler/actions/runs/34498419509) | 2026-09-10 15:51:52 | 2 | success | 0/9 | 0/143 | Available |
| [34496928382](https://github.com/ZingerLittleBee/Heeler/actions/runs/34496928382) | 2026-09-10 15:38:11 | 1 | failure | — | — | Archive HTTP 404 |
| [34495772943](https://github.com/ZingerLittleBee/Heeler/actions/runs/34495772943) | 2026-09-10 15:27:39 | 1 | action_required | — | — | Excluded |
| [34495045361](https://github.com/ZingerLittleBee/Heeler/actions/runs/34495045361) | 2026-09-10 15:20:56 | 1 | action_required | — | — | Excluded |
| [34495032262](https://github.com/ZingerLittleBee/Heeler/actions/runs/34495032262) | 2026-09-10 15:20:48 | 1 | action_required | — | — | Excluded |
| [34485830686](https://github.com/ZingerLittleBee/Heeler/actions/runs/34485830686) | 2026-09-10 13:56:44 | 1 | failure | 0/1 | 0/2 | Available |
| [34483525310](https://github.com/ZingerLittleBee/Heeler/actions/runs/34483525310) | 2026-09-10 13:34:51 | 1 | success | 0/9 | 0/143 | Available |
| [34450202156](https://github.com/ZingerLittleBee/Heeler/actions/runs/34450202156) | 2026-09-10 07:29:22 | 1 | failure | — | — | Archive HTTP 404 |
| [34410967707](https://github.com/ZingerLittleBee/Heeler/actions/runs/34410967707) | 2026-09-09 22:11:49 | 1 | action_required | — | — | Excluded |
| [34409905464](https://github.com/ZingerLittleBee/Heeler/actions/runs/34409905464) | 2026-09-09 21:59:53 | 1 | action_required | — | — | Excluded |
| [34407225409](https://github.com/ZingerLittleBee/Heeler/actions/runs/34407225409) | 2026-09-09 21:29:40 | 1 | failure | — | — | Archive HTTP 404 |
| [34406844724](https://github.com/ZingerLittleBee/Heeler/actions/runs/34406844724) | 2026-09-09 21:25:32 | 1 | action_required | — | — | Excluded |
| [34406437075](https://github.com/ZingerLittleBee/Heeler/actions/runs/34406437075) | 2026-09-09 21:21:13 | 1 | action_required | — | — | Excluded |
| [34405291457](https://github.com/ZingerLittleBee/Heeler/actions/runs/34405291457) | 2026-09-09 21:09:18 | 1 | action_required | — | — | Excluded |
| [34403889922](https://github.com/ZingerLittleBee/Heeler/actions/runs/34403889922) | 2026-09-09 20:55:00 | 1 | failure | — | — | Archive HTTP 404 |
| [34401572907](https://github.com/ZingerLittleBee/Heeler/actions/runs/34401572907) | 2026-09-09 20:31:44 | 1 | failure | — | — | Archive HTTP 404 |
| [34399489320](https://github.com/ZingerLittleBee/Heeler/actions/runs/34399489320) | 2026-09-09 20:11:00 | 1 | failure | — | — | Archive HTTP 404 |
| [34391747781](https://github.com/ZingerLittleBee/Heeler/actions/runs/34391747781) | 2026-09-09 18:53:18 | 1 | failure | — | — | Archive HTTP 404 |
| [34390086266](https://github.com/ZingerLittleBee/Heeler/actions/runs/34390086266) | 2026-09-09 18:36:54 | 1 | failure | — | — | Archive HTTP 404 |
| [34382600676](https://github.com/ZingerLittleBee/Heeler/actions/runs/34382600676) | 2026-09-09 17:23:24 | 1 | success | 0/9 | 0/143 | Available |
| [34382575192](https://github.com/ZingerLittleBee/Heeler/actions/runs/34382575192) | 2026-09-09 17:23:09 | 1 | cancelled | — | — | Excluded |
| [34364639697](https://github.com/ZingerLittleBee/Heeler/actions/runs/34364639697) | 2026-09-09 14:35:43 | 3 | failure | 0/8 | 1/141 | Available |
| [34357888348](https://github.com/ZingerLittleBee/Heeler/actions/runs/34357888348) | 2026-09-09 13:34:00 | 3 | success | 0/8 | 0/141 | Available |
| [34357639493](https://github.com/ZingerLittleBee/Heeler/actions/runs/34357639493) | 2026-09-09 13:31:41 | 1 | success | 0/9 | 0/143 | Available |
