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
    def test_handshake_times_tcp_separately_without_changing_the_deadline(self):
        source = block(read("Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift"), "handshake")
        self.assertIn('SSHDiagnosticOperation.current?.step = "TCP connect"', source)
        self.assertLess(source.index('step = "TCP connect"'), source.index("SocketConnector.connect"))
        self.assertLess(source.index('step = ""'), source.index("performHandshake(deadline: deadline)"))
        self.assertIn("ContinuousClock.now.advanced(by: timeout)", source)

    def test_image_preparation_observer_brackets_the_real_preparer(self):
        source = read("Sources/Heeler/Attachments/ComposerStagingStore.swift")
        adapter = source[source.index("private struct ImageAdapter"):source.index("private struct FileAdapter")]
        self.assertIn('preparationObserverForTesting?("started")', adapter)
        self.assertIn('defer { preparationObserverForTesting?("finished") }', adapter)
        self.assertIn("preparer.prepare(selection)", adapter)
        self.assertIn("@Sendable (String) -> Void", adapter)
        self.assertRegex(adapter, r'#if DEBUG\s+preparationObserverForTesting\?\("started"\)')
        test = block(read("Tests/HeelerTests/AgentSurfaceReplacementTests.swift"), "assertPossibleSuspensionRecovery")
        self.assertIn("observeImagePreparationForTesting", test)
        self.assertIn("DataImageSelection(data: Data([0x01]))", test)
        self.assertIn("observeImagePreparationForTesting(nil)", test)

    def test_attach_recovery_cleans_up_on_success_and_thrown_failure(self):
        source = read("Tests/HeelerTests/AgentSurfaceReplacementTests.swift")
        test = block(source, "assertPossibleSuspensionRecovery")
        self.assertIn("withClosingAttachOwner", test)
        cleanup = block(source, "withClosingAttachOwner")
        self.assertEqual(cleanup.count("await tearDown()"), 2)
        self.assertIn("await owner.leave().value", cleanup)
        self.assertIn("window.rootViewController = nil", cleanup)
        self.assertIn("await hideTestWindowWhenSettled(window)", cleanup)
        self.assertIn("throw error", cleanup)
        self.assertIn("timeout: Duration = .seconds(5)", source)
        regression = block(source, "failedRecoveryScopeReleasesAttachOwnerAndWindow")
        self.assertIn("SurfaceCleanupFailure.injected", regression)
        self.assertIn("owner.terminalStatus == .stopped", regression)
        self.assertIn("transport.hasLiveAttachSession == false", regression)
        self.assertEqual(len(re.findall(r"(?m)^\s*@Test\b", source)), 9)
        diagnostic = read("scripts/test-ci-ios-diagnostics.sh")
        self.assertIn("AgentSurfaceReplacementTests HEELER_STAGING_RECOVERY_ITERATIONS 9 20", diagnostic)

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

    def test_terminal_key_fixture_cleans_up_failed_preparation_and_keeps_its_probe_bound(self):
        source = read("Tests/HeelerTests/TerminalKeyModifiersTests.swift")
        make = block(source, "make")
        self.assertIn("catch {", make)
        self.assertIn("fixture.close()", make)
        self.assertIn("throw error", make)
        close = block(source, "close")
        self.assertIn("control.terminal = nil", close)
        self.assertIn("onSend: nil", close)
        self.assertIn("window?.rootViewController = nil", close)
        drain = block(source, "drain")
        self.assertEqual(drain.count('receive("\\u{1B}[c")'), 1)
        self.assertIn("ContinuousClock.now + .seconds(2)", drain)
        self.assertIn("Task.sleep(for: .milliseconds(10))", drain)
        self.assertNotIn("Task.yield()", drain)
        self.assertIn("[terminal-key-test]", source)
        self.assertIn("terminal.viewportRows != nil", source)
        self.assertNotIn("terminal.hasTerminalGridMetrics", source)
        self.assertIn("@Test func failedFixturePreparationDetachesItsWindow()", source)

    def test_package_log_gate_requires_the_new_method_and_both_cases(self):
        source = read("scripts/run-ci-ios-tests.sh")
        self.assertIn("Test run with 71 tests in 5 suites passed", source)
        self.assertIn('Test "one-shot exec resumes owned reads before other exchange operations" with 2 test cases passed', source)
        self.assertNotIn("Test run with 70 tests in 5 suites passed", source)

    def test_one_shot_exchange_resumes_its_own_reads_before_foreign_admission(self):
        source = block(read("Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift"), "exchange")
        self.assertIn("if !resumingRead, inputOffset < input.count", source)
        self.assertIn("else if !resumingRead, !sentEOF", source)
        self.assertIn("if transportSendOwner != stderrOwner", source)
        self.assertIn("if transportSendOwner != stdoutOwner", source)
        self.assertIn("if !ownsSend, libssh2_channel_eof", source)

    def test_full_keyboard_waits_for_visible_geometry_and_cleans_up_on_failure(self):
        source = read("Tests/HeelerTests/TerminalBackspaceButtonTests.swift")
        method = block(source, "fullKeyboardKeepsRepeatingAcrossViewUpdates")
        self.assertIn("withTestWindow(", method)
        self.assertLess(method.index("!button.bounds.isEmpty"), method.index("press.begin()"))
        self.assertLess(method.index("window.bounds.contains("), method.index("press.begin()"))
        self.assertIn("#expect(repeats >= 3", method)
        self.assertIn("within timeout: Duration = .seconds(5)", source)
        self.assertIn("[backspace-test]", method)
        self.assertIn("@MainActor func readyButton()", method)
        self.assertIn("@MainActor func recordState()", method)

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

    def test_window_cleanup_detaches_on_success_and_failure(self):
        scope = block(read("Tests/HeelerTests/Support/TestWindow.swift"), "withTestWindow")
        self.assertEqual(scope.count("await hideTestWindowWhenSettled(window)"), 2)
        self.assertEqual(scope.count("window.rootViewController = nil"), 2)
        self.assertIn("throw error", scope)
        views = read("Tests/HeelerTests/ChangesReferenceViewTests.swift")
        self.assertNotIn("defer { window.isHidden = true }", views)

    def test_native_regressions_use_a_barrier_not_an_arbitrary_sleep(self):
        source = read("Tests/HeelerTests/HostLiveActivityCoordinatorTests.swift")
        test = block(source, "stoppingCancelsAnInFlightTokenWrite")
        self.assertIn("CancellablePhaseGate()", test)
        self.assertIn("notificationRegistrationWriteIsBlocked", test)
        self.assertIn("await coordinator.stop()", test)
        self.assertNotIn("Task.sleep", test)
        block(source, "fixtureTeardownReleasesTheCoordinatorAndSubscriptions")
        block(read("Tests/HeelerTests/ChangesReferenceViewTests.swift"), "failingWindowScopeStillDetachesTheHostingRoot")


if __name__ == "__main__":
    unittest.main()
