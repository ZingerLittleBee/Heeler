import Foundation
import Observation
import UIKit
import UserNotifications

/// Which APNs environment this build's device tokens belong to — the `env`
/// field of the Notification Registration file contract. Debug builds run
/// under development provisioning, whose tokens only exist on the sandbox
/// APNs host; Release builds (TestFlight, App Store) get production tokens.
enum APNSEnvironment: String, Sendable, Codable {
    case sandbox
    case production

    static var current: APNSEnvironment {
        #if DEBUG
            .sandbox
        #else
            .production
        #endif
    }
}

/// A captured APNs device token in the wire form the registration file
/// wants: lowercase hex plus the environment it belongs to.
struct APNSDeviceToken: Sendable, Equatable {
    let hex: String
    let environment: APNSEnvironment

    init(hex: String, environment: APNSEnvironment) {
        self.hex = hex
        self.environment = environment
    }

    init(tokenData: Data, environment: APNSEnvironment) {
        self.init(
            hex: tokenData.map { String(format: "%02x", $0) }.joined(),
            environment: environment)
    }
}

/// The system boundary of push bootstrap: iOS permission state and APNs
/// registration. A protocol so the store's state machine is testable; the
/// token itself still arrives through `UIApplicationDelegate` callbacks,
/// which `PushRegistrationDelegate` forwards into the store.
protocol PushRegistrationClient: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    @MainActor func registerForRemoteNotifications()
}

struct SystemPushRegistrationClient: PushRegistrationClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// App-side push bootstrap (#71): asks for notification permission, registers
/// with APNs, and captures the device token that Notification Registration
/// (#72) will write to a Host. Apple says tokens can change between
/// launches, so `refresh` silently re-registers whenever permission already
/// exists instead of caching a token across runs.
@MainActor
@Observable
final class PushRegistrationStore {
    enum State: Equatable {
        /// Not probed yet this launch.
        case unknown
        /// iOS has never asked; the permission prompt is still available.
        case needsPermission
        case denied
        /// Registration is in flight; the token callback has not fired yet.
        case waitingForToken
        case registered(APNSDeviceToken)
        case failed(String)
    }

    private(set) var state: State = .unknown

    private let client: any PushRegistrationClient
    private let environment: APNSEnvironment

    init(
        client: any PushRegistrationClient = SystemPushRegistrationClient(),
        environment: APNSEnvironment = .current
    ) {
        self.client = client
        self.environment = environment
    }

    /// The captured token, once APNs has answered.
    var deviceToken: APNSDeviceToken? {
        if case .registered(let token) = state { return token }
        return nil
    }

    /// Launch/foreground sync: re-register silently when permission already
    /// exists, otherwise just reflect where the user left the permission.
    func refresh() async {
        if case .registered = state { return }
        switch await client.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            state = .waitingForToken
            client.registerForRemoteNotifications()
        case .denied:
            state = .denied
        case .notDetermined:
            state = .needsPermission
        @unknown default:
            state = .needsPermission
        }
    }

    /// The user-initiated step: show the iOS permission prompt, then register.
    func enable() async {
        do {
            if try await client.requestAuthorization() {
                state = .waitingForToken
                client.registerForRemoteNotifications()
            } else {
                state = .denied
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func deviceTokenDidArrive(_ tokenData: Data) {
        state = .registered(APNSDeviceToken(tokenData: tokenData, environment: environment))
    }

    func registrationDidFail(_ error: any Error) {
        state = .failed(error.localizedDescription)
    }
}

/// UIKit shim: APNs delivers the device token only through
/// `UIApplicationDelegate` callbacks, so the SwiftUI app installs this via
/// `@UIApplicationDelegateAdaptor`. It owns the store so the callbacks have
/// somewhere to land before any view exists.
@MainActor
final class PushRegistrationDelegate: NSObject, UIApplicationDelegate {
    let registration = PushRegistrationStore()

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        registration.deviceTokenDidArrive(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        registration.registrationDidFail(error)
    }
}
