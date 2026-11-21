#!/usr/bin/env python3
"""Source-contract guards only; Swift lifecycle behavior is verified by native tests."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent


def read(path: str) -> str:
    return (ROOT / path).read_text()


def block(source: str, name: str) -> str:
    match = re.search(r"\bfunc " + re.escape(name) + r"\b", source)
    assert match is not None, name
    start = source.index("{", match.end())
    depth = 1
    for index in range(start + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start + 1:index]
    raise AssertionError(f"unterminated function {name}")


class LifecycleContracts(unittest.TestCase):
    def test_foreground_failure_waits_for_the_live_pane_stream_before_closing(self):
        source = read("Tests/HeelerTests/AppForegroundRecoveryTests.swift")
        body = block(source, "aFailedHostIsAskedAgainWhicheverNonRetryableClassStoppedIt")
        self.assertIn("waitUntilPaneResubscribeSettles(on: stopped)", body)
        self.assertLess(body.index("waitUntilPaneResubscribeSettles(on: stopped)"),
                        body.index("try await stopped.close()"))
        self.assertIn("withClosingRecoveryDriver", body)
        self.assertNotIn("store.setHosts([])", body)
        cleanup = block(source, "withClosingRecoveryDriver")
        self.assertEqual(cleanup.count("await tearDown()"), 2)
        self.assertIn("driver.cancel()", cleanup)
        self.assertIn("await driver.value", cleanup)
        self.assertIn("await store.suspend()", cleanup)
        self.assertLess(cleanup.index("await driver.value"),
                        cleanup.index("await store.suspend()"))
        self.assertLess(cleanup.index("await store.suspend()"),
                        cleanup.index("store.setHosts([])"))
        self.assertIn("throw error", cleanup)
        self.assertIn("timeout: Duration = .seconds(5)", source)

    def test_handshake_times_tcp_separately_without_changing_the_deadline(self):
        source = block(read("Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift"), "handshake")
        self.assertIn('SSHDiagnosticOperation.current?.step = "TCP connect"', source)
        self.assertLess(source.index('step = "TCP connect"'), source.index("SocketConnector.connect"))
        self.assertLess(source.index('step = ""'), source.index("performHandshake(deadline: deadline)"))
        self.assertIn("ContinuousClock.now.advanced(by: timeout)", source)

    def test_starvation_recovers_at_the_timeout_boundary_without_changing_deadlines(self):
        source = read("Tests/HeelerTests/WeakNetworkE2ETests.swift")
        method = block(source, "starvedLinkTimesOutAndRecovers")
        self.assertIn("settings.requestTimeout = .seconds(4)", method)
        self.assertIn("await transport.runNextStreamLocalTimeoutHookForTesting", method)
        self.assertIn("started.duration(to: .now) >= .seconds(4)", method)
        self.assertIn("await recovery.record()", method)
        self.assertIn("#require(await recovery.count == 1)", method)
        self.assertIn("#expect(await transport.oneShotChannelCountForTesting() == 0)", method)
        self.assertIn("await #expect(throws: TransportError.timedOut)", method)
        self.assertIn("started.duration(to: .now) < .seconds(20)", method)
        self.assertEqual(method.count("transport.ping().protocolVersion == 17"), 2)
        self.assertLess(method.index("runNextStreamLocalTimeoutHookForTesting"),
                        method.index("await #expect(throws:"))
        self.assertNotIn("Task.sleep", method)

    def test_timeout_hook_precedes_both_owned_send_drain_paths_and_is_one_shot(self):
        source = read("Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift")
        method = block(source, "exchangeResponseLine")
        for match in re.finditer(r"await drainOwnedSends\(requestOffset:", method):
            prefix = method[:match.start()]
            self.assertRegex(prefix, r"#if DEBUG\s+try await runStreamLocalTimeoutHookForTestingIfNeeded\(error\)\s+#endif\s+$")
        self.assertEqual(method.count("runStreamLocalTimeoutHookForTestingIfNeeded(error)"), 2)
        hook = block(source, "runStreamLocalTimeoutHookForTestingIfNeeded")
        self.assertIn("failure == .timedOut || failure == .cancelled", hook)
        self.assertLess(hook.index("nextStreamLocalTimeoutHookForTesting = nil"),
                        hook.index("try await hook()"))
        exchange = block(source, "exchangeStreamLocal")
        self.assertIn("nextStreamLocalTimeoutHookForTesting = nil", exchange)
        self.assertIn("deadline: ContinuousClock.now.advanced(by: .seconds(2))", exchange)
        self.assertIn("catch {\n                        invalidateResources()", exchange)

    def test_inventory_counter_is_captured_after_initial_subscription_resync(self):
        source = read("Tests/HeelerTests/ConsoleTerminalInventoryTests.swift")
        method = block(source, "frequentPaneUpdatesRefreshMetadataWithoutSnapshotRequests")
        self.assertIn("await transport.gateNextSnapshot(using: snapshotGate)", method)
        self.assertIn("await transport.gateNextSubscription(using: subscriptionGate)", method)
        self.assertIn("await transport.snapshotFetchCount > initialCount", method)
        self.assertLess(method.index("await store.refreshSidebarLayouts()"),
                        method.index("let count = await transport.snapshotFetchCount"))
        self.assertLess(method.index("let count = await transport.snapshotFetchCount"),
                        method.index("for index in 0..<20"))
        self.assertIn("#expect(await transport.snapshotFetchCount == count)", method)
        self.assertIn('store.terminals.first?.cwd == "/work/19"', method)

    def test_one_shot_exchange_resumes_its_own_reads_before_foreign_admission(self):
        source = block(read("Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift"), "exchange")
        self.assertIn("if !resumingRead, inputOffset < input.count", source)
        self.assertIn("else if !resumingRead, !sentEOF", source)
        self.assertIn("if transportSendOwner != stderrOwner", source)
        self.assertIn("if transportSendOwner != stdoutOwner", source)
        self.assertIn("if readOwnsSend, !sessionReportsOutbound(try requireSession())", source)
        self.assertLess(
            source.index("if readOwnsSend, !sessionReportsOutbound"),
            source.index("if resumingRead, transportSendOwner != stdoutOwner"))
        self.assertIn("if !ownsSend, libssh2_channel_eof", source)

    def test_streams_are_registered_before_consumer_tasks(self):
        source = block(read("Sources/Heeler/LiveActivities/HostLiveActivityCoordinator.swift"), "beginSession")
        self.assertLess(source.index("controller.pushTokenUpdates"), source.index("Task {"))
        self.assertLess(source.index("controller.stateUpdates"), source.index("Task {"))
        self.assertNotIn("guard let self", source)
        self.assertEqual(source.count("guard !Task.isCancelled"), 2)

    def test_writer_is_owned_and_cannot_pump_after_cancellation(self):
        source = block(read("Sources/Heeler/LiveActivities/HostLiveActivityCoordinator.swift"), "pump")
        self.assertIn("writerTasks[hostID] = Task", source)
        self.assertLess(source.index("guard !Task.isCancelled"), source.index("self.pump(hostID)"))

    def test_stop_cancels_and_joins_owned_work(self):
        source = block(read("Sources/Heeler/LiveActivities/HostLiveActivityCoordinator.swift"), "stop")
        for owner in ("settleTasks", "writerTasks", "sessions"):
            self.assertIn(owner + ".values", source)
            self.assertIn(owner + ".removeAll()", source)
        self.assertLess(source.index("task.cancel()"), source.index("await task.value"))

    def test_fixture_teardown_runs_on_success_and_thrown_failure(self):
        source = read("Tests/HeelerTests/HostLiveActivityCoordinatorTests.swift")
        scope = block(source, "withFixture")
        self.assertEqual(scope.count("await tearDown()"), 2)
        self.assertIn("throw error", scope)
        for name in re.findall(r"@Test func (\w+)", source):
            if "makeCoordinator(" in block(source, name):
                self.assertIn("try await withFixture", block(source, name), name)

    def test_native_regressions_use_a_barrier_not_an_arbitrary_sleep(self):
        source = read("Tests/HeelerTests/HostLiveActivityCoordinatorTests.swift")
        test = block(source, "stoppingCancelsAnInFlightTokenWrite")
        self.assertIn("CancellablePhaseGate()", test)
        self.assertIn("notificationRegistrationWriteIsBlocked", test)
        self.assertLess(test.index("try await stopWithDeadline(coordinator)"), test.index("await gate.release()"))
        self.assertNotIn("Task.sleep", test)
        self.assertIn("await coordinator.stop()", block(source, "stopWithDeadline"))
        block(source, "fixtureTeardownReleasesTheCoordinatorAndSubscriptions")


if __name__ == "__main__":
    unittest.main()
