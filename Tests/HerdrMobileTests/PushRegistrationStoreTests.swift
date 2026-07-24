import Foundation
import Synchronization
import Testing
import UserNotifications

@testable import HerdrMobile

/// State machine of the app-side push bootstrap (#71): permission request,
/// APNs registration, and token capture, driven through a scripted stand-in
/// for the UNUserNotificationCenter/UIApplication boundary (the only part
/// that cannot run for real in tests).
@MainActor
@Suite("Push registration store")
struct PushRegistrationStoreTests {
    private let client = ScriptedPushRegistrationClient()

    private func makeStore(environment: APNSEnvironment = .sandbox) -> PushRegistrationStore {
        PushRegistrationStore(client: client, environment: environment)
    }

    @Test func enableRequestsPermissionThenRegistersForAToken() async {
        client.grantResult = .success(true)
        let store = makeStore()

        await store.enable()

        #expect(store.state == .waitingForToken)
        #expect(client.registerCallCount == 1)
    }

    @Test func deviceTokenArrivalCapturesLowercaseHexAndEnvironment() async {
        client.grantResult = .success(true)
        let store = makeStore(environment: .sandbox)
        await store.enable()

        store.deviceTokenDidArrive(Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let token = APNSDeviceToken(hex: "deadbeef", environment: .sandbox)
        #expect(store.state == .registered(token))
        #expect(store.deviceToken == token)
    }

    @Test func refusedPermissionReadsAsDenied() async {
        client.grantResult = .success(false)
        let store = makeStore()

        await store.enable()

        #expect(store.state == .denied)
        #expect(client.registerCallCount == 0)
    }

    @Test func permissionRequestFailureSurfaces() async {
        client.grantResult = .failure(ScriptedPushRegistrationClient.Failure())
        let store = makeStore()

        await store.enable()

        guard case .failed = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
    }

    @Test func registrationFailureSurfaces() async {
        client.grantResult = .success(true)
        let store = makeStore()
        await store.enable()

        store.registrationDidFail(ScriptedPushRegistrationClient.Failure())

        guard case .failed = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
    }

    /// APNs tokens can change between launches, so an already-authorized app
    /// silently re-registers on refresh instead of waiting for the user to
    /// tap anything again.
    @Test func refreshWhenAuthorizedRegistersSilently() async {
        client.status = .authorized
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .waitingForToken)
        #expect(client.registerCallCount == 1)
    }

    @Test func refreshWhenUndeterminedAsksForThePermissionStep() async {
        client.status = .notDetermined
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .needsPermission)
        #expect(client.registerCallCount == 0)
    }

    @Test func refreshWhenDeniedReadsAsDenied() async {
        client.status = .denied
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .denied)
    }

    /// A foreground refresh must not throw away a token that already arrived
    /// this launch.
    @Test func refreshKeepsAnAlreadyCapturedToken() async {
        client.status = .authorized
        client.grantResult = .success(true)
        let store = makeStore()
        await store.enable()
        store.deviceTokenDidArrive(Data([0x01]))

        await store.refresh()

        #expect(store.state == .registered(APNSDeviceToken(hex: "01", environment: .sandbox)))
        #expect(client.registerCallCount == 1)
    }
}

/// Scripted stand-in for the system push boundary.
final class ScriptedPushRegistrationClient: PushRegistrationClient {
    struct Failure: Error {}

    private let scriptedStatus = Mutex<UNAuthorizationStatus>(.notDetermined)
    private let scriptedGrant = Mutex<Result<Bool, any Error>>(.success(false))
    private let registerCalls = Mutex<Int>(0)

    var status: UNAuthorizationStatus {
        get { scriptedStatus.withLock { $0 } }
        set { scriptedStatus.withLock { $0 = newValue } }
    }

    var grantResult: Result<Bool, any Error> {
        get { scriptedGrant.withLock { $0 } }
        set { scriptedGrant.withLock { $0 = newValue } }
    }

    var registerCallCount: Int {
        registerCalls.withLock { $0 }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        try grantResult.get()
    }

    func registerForRemoteNotifications() {
        registerCalls.withLock { $0 += 1 }
    }
}
