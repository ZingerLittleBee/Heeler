import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Background connections")
struct BackgroundConnectionKeeperTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "background-connections-test-\(UUID())")!
    }

    @Test func disabledByDefaultAndNeverPromptsOnLaunch() {
        let location = FakeBackgroundLocationUpdater()
        let keeper = BackgroundConnectionKeeper(defaults: defaults(), location: location)
        keeper.didBecomeActive()
        keeper.setConnectionNeeded(true)
        #expect(!keeper.isEnabled)
        #expect(!keeper.isRunning)
        #expect(location.requests == 0)
        #expect(location.starts == 0)
    }

    @Test func explicitOptInRequestsPermissionThenStartsForAConnection() {
        let location = FakeBackgroundLocationUpdater()
        let keeper = BackgroundConnectionKeeper(defaults: defaults(), location: location)
        keeper.didBecomeActive()
        keeper.setEnabled(true)
        #expect(location.requests == 1)
        #expect(!keeper.isRunning)
        location.authorization = .authorized
        location.onChange?()
        #expect(!keeper.isRunning)
        keeper.setConnectionNeeded(true)
        #expect(keeper.isRunning)
        #expect(location.starts == 1)
        keeper.didEnterBackground()
        keeper.setConnectionNeeded(true)
        #expect(keeper.isRunning)
        #expect(location.starts == 1)
    }

    @Test func noPermissionPromptOrLocationStartInTheBackground() {
        let location = FakeBackgroundLocationUpdater()
        let keeper = BackgroundConnectionKeeper(defaults: defaults(), location: location)
        keeper.didBecomeActive()
        keeper.setConnectionNeeded(true)
        keeper.setEnabled(true)
        keeper.didEnterBackground()
        keeper.setEnabled(true)
        #expect(location.requests == 1)
        location.authorization = .authorized
        location.onChange?()
        #expect(!keeper.isRunning)
        keeper.didBecomeActive()
        #expect(keeper.isRunning)
    }

    @Test func lastConnectionOrOptOutStopsLocationAndPersistsThePreference() {
        let location = FakeBackgroundLocationUpdater()
        location.authorization = .authorized
        let saved = defaults()
        let keeper = BackgroundConnectionKeeper(defaults: saved, location: location)
        keeper.didBecomeActive()
        keeper.setEnabled(true)
        keeper.setConnectionNeeded(true)
        keeper.setConnectionNeeded(false)
        #expect(!keeper.isRunning)
        #expect(location.stops == 1)
        #expect(BackgroundConnectionKeeper(defaults: saved, location: FakeBackgroundLocationUpdater()).isEnabled)
        keeper.setConnectionNeeded(true)
        keeper.setEnabled(false)
        #expect(!keeper.isRunning)
        #expect(location.stops == 2)
        #expect(!BackgroundConnectionKeeper(defaults: saved, location: FakeBackgroundLocationUpdater()).isEnabled)
    }

    @Test func permissionRevocationAndLocationFailureReleaseTheExecutionClaim() {
        let location = FakeBackgroundLocationUpdater()
        location.authorization = .authorized
        let keeper = BackgroundConnectionKeeper(defaults: defaults(), location: location)
        var changes: [Bool] = []
        keeper.onRunningChanged = { changes.append($0) }
        keeper.didBecomeActive()
        keeper.setConnectionNeeded(true)
        keeper.setEnabled(true)
        keeper.didEnterBackground()
        location.authorization = .denied
        location.onChange?()
        #expect(!keeper.isRunning)
        #expect(changes == [true, false])
        location.authorization = .authorized
        keeper.didBecomeActive()
        location.isAvailable = false
        location.onChange?()
        #expect(!keeper.isRunning)
        #expect(changes == [true, false, true, false])
    }

    @Test func aSavedPreferenceDoesNotPromptForAnUndeterminedPermission() {
        let saved = defaults()
        let location = FakeBackgroundLocationUpdater()
        let original = BackgroundConnectionKeeper(defaults: saved, location: location)
        original.setEnabled(true)
        let restored = BackgroundConnectionKeeper(defaults: saved, location: location)
        restored.didBecomeActive()
        restored.setConnectionNeeded(true)
        #expect(restored.isEnabled)
        #expect(!restored.isRunning)
        #expect(location.requests == 0)
    }
}

@MainActor
private final class FakeBackgroundLocationUpdater: BackgroundLocationUpdating {
    var authorization: BackgroundLocationAuthorization = .notDetermined
    var isAvailable = true
    var onChange: (@MainActor () -> Void)?
    var requests = 0
    var starts = 0
    var stops = 0
    func requestAuthorization() { requests += 1 }
    func prepareForForeground() {}
    func start() { starts += 1 }
    func stop() { stops += 1 }
}
