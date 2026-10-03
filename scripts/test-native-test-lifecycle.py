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
