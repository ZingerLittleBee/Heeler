# herdr 0.9.0 lifecycle compatibility

Issue: [#288](https://github.com/ZingerLittleBee/Heeler/issues/288).
Reviewed on 2026-09-09. This is maintenance following a reported working
upgrade; no missed-lifecycle-event regression has been demonstrated.

## Evidence and provenance

The official annotated `v0.9.0` tag resolves through tag object
`cca4af8dfad160bc5fb5ae133b70882b5fe28f61` to commit
`b99002ac99b09e00b4ca692436cb15a6b0d676f1`, verified using GitHub's API.
The following conclusions come from reading that release's sources, not from
running an upstream server or its tests:

- The [socket API guide](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/socket-api.mdx#L118-L127)
  specifies subscription acknowledgement before the bootstrap snapshot,
  consumption/buffering during the request, and a new snapshot after reconnect.
  Its [subscription section](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/website/src/content/docs/socket-api.mdx#L812-L814)
  identifies lifecycle subscriptions as live-only from request acceptance.
- In [stream_subscriptions](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/api/server.rs#L700-L742),
  the server captures the current event sequence before constructing the
  subscription set and acknowledging it. [ActiveSubscription::new](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/api/subscriptions.rs#L106-L120)
  initializes lifecycle subscriptions from that shared sequence. Consequently,
  retained events preceding it are excluded, while setup-window events remain
  eligible. The upstream test
  `lifecycle_subscription_skips_history_but_keeps_setup_window_events` records
  this boundary in the same file. That test was read, not run.
- This lifecycle rule does not assert that pane-scoped predicate subscriptions
  never produce initial state. Those have separate implementations in
  `subscriptions.rs`.
- The [release schema](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/docs/next/api/herdr-api.schema.json)
  declares protocol 22. Schema refresh, generated wire types and advisory
  constants belong to the separate wire package; their checks are not evidence
  from this lifecycle review. Preserve minimum-protocol admission rather than
  adding version equality.

## Heeler ordering, inspected statically

1. `HeelerSSHTransport.openEventsChannel` reads and decodes the subscription
   acknowledgement before returning its buffered `HerdrEventStream`.
2. `EventsSession.run` awaits `subscribeToEvents`, installs the stream, emits
   `.connected`, then forwards its events. Initial connection and reconnect use
   this same path. Terminal readiness may precede it; terminal readiness is not
   the Console bootstrap signal.
3. `HostConsoleProjection.handle` schedules `sessionSnapshot()` on every
   `.connected`. Lifecycle events arriving during a snapshot set a coalesced
   follow-up resync; status deltas use revisions so an older response cannot
   overwrite a newer status. This projection converges through authoritative
   re-reads rather than reconstructing all membership from event payloads.
4. Applying the snapshot installs the current pane subscriptions. A changed
   set ends and replaces the channel. Its next `.connected` schedules another
   snapshot, covering the replacement gap without retained-event replay.
5. Disconnect invalidates the projection's snapshot epoch. The session drops
   snapshot-derived pane and protocol-dependent subscriptions before recovery;
   a new snapshot restores the set. Late responses crossing a disconnected
   epoch cannot restore stale Agents. `events.dropped` also requests resync.

These paths already implement the required ordering. Production behavior is
unchanged; comments now state acknowledgement and replacement requirements.
The older 0.7.5 replay observation in AGENTS.md remains historical evidence,
not a claim about 0.9.0.

## Focused coverage and execution boundary

Two missing explicit guarantees now have scripted tests in
`Tests/HeelerTests/ConsoleStoreTests.swift`:

- `initialAndReconnectSnapshotsFollowSubscriptionAcknowledgement` holds both
  acknowledgements, checks snapshot counts at those boundaries, then checks
  that both snapshot requests observed an installed subscription.
- `lifecycleEventDuringInitialSnapshotSchedulesAuthoritativeFollowup` holds
  an empty initial snapshot, emits a live Agent-detected event, and requires
  the Console to converge to the new Agent after the stale response returns.

Existing coverage includes status changes during a stale snapshot,
reconnect resnapshotting, disconnect during initial sync, subscription changes,
and dead-pane recovery (`ConsoleStoreTests` and
`EventsSessionSubscriptionsTests`). Scripted streams do not replay history.
These tests describe client behavior, not real SSH or server proof.

This review itself ran no builds or tests. CI on PR #297 at `b43c69e`
(workflow run 34382600676) later executed the full `HeelerTests` plan: 1,563
tests in 149 suites passed, including both tests above. Wire codegen drift and
lower-version/advisory tests belong to the wire package and passed in the same
PR's CI.

## Physical-device report and architectural limits

The maintainer reports that tested functionality in the current Heeler version
works with herdr 0.9.0 on a physical phone. Device model, exact build and
individual scenarios are unknown. This is a bounded maintainer report, not
exhaustive acceptance or a device test performed during this package.
Multi-client sizing, takeover and scrolling on 0.9.0 remain **UNVERIFIED**.
Historical 0.8.2 Attach/scroll experiments have not been repeated here.

[ADR 0011](../adr/0011-libssh2-direct-streamlocal-transport.md) remains the
transport decision: API RPCs use direct-streamlocal channels and interactive
Attach uses SSH PTY exec. ADRs 0013 (Composer), 0015 (Shell Terminal) and 0016
(Direct Input) retain their historical rationale and scoped exceptions. This
review does not infer concurrent writable direct attaches, API recovery of
Agent history, or new remote installation/restart behavior from release notes.
