import Foundation
import Observation
import UIKit

/// The app's *effective* activity, which is deliberately not `scenePhase`.
///
/// Backgrounding opens a grace period: the app keeps running under a UIKit
/// background-execution assertion and holds its Host connections, so glancing
/// at another app, pulling down the notification shade, or answering a
/// message costs nothing on return. Only when the grace period elapses — or
/// the system reclaims its time — does the app consider itself suspended and
/// tear the connections down (the deliberate teardown of ADR 0002; iOS
/// freezes the sockets anyway once the process is suspended).
enum AppActivityPhase: Sendable, Equatable {
    case active
    case suspended
}

/// A UIKit background-execution assertion, reduced to what the coordinator
/// needs so it can be tested without a running `UIApplication`.
struct BackgroundExecutionToken: Hashable, Sendable {
    let rawValue: Int
}

@MainActor
protocol BackgroundExecutionGranting: AnyObject {
    /// Asks the system for background execution time. Returns nil when the
    /// request is refused, in which case there is no grace period to be had.
    /// `onExpiration` runs on the main actor shortly before the system takes
    /// the time back; the assertion must be ended from it or the app is
    /// killed.
    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken?

    func end(_ token: BackgroundExecutionToken)
}

@MainActor
final class UIKitBackgroundExecutionGranter: BackgroundExecutionGranting {
    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "dev.bybee.heeler.background-grace"
        ) {
            // UIKit calls this on the main thread but the API is not
            // annotated for it, so hop deliberately instead of asserting an
            // isolation the compiler cannot check.
            Task { @MainActor in onExpiration() }
        }
        guard identifier != .invalid else { return nil }
        return BackgroundExecutionToken(rawValue: identifier.rawValue)
    }

    func end(_ token: BackgroundExecutionToken) {
        UIApplication.shared.endBackgroundTask(
            UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }
}

/// Turns scene-phase edges into `AppActivityPhase`, holding a background
/// execution assertion for the length of the grace period.
///
/// The assertion outlives the phase change on purpose: it is released only
/// once the observer reports its teardown finished (`didFinishSuspending()`),
/// so the SSH connections close cleanly instead of being frozen mid-close.
/// The one exception is expiration, where the system wants its time back
/// immediately and holding on any longer would kill the app.
@MainActor
@Observable
final class AppActivityCoordinator {
    /// iOS grants a background-execution assertion on the order of 30
    /// seconds. Stopping well short of that keeps the deliberate teardown
    /// inside our own budget rather than racing the expiration handler.
    static let defaultGracePeriod: Duration = .seconds(20)

    private(set) var phase: AppActivityPhase = .active

    @ObservationIgnored private let gracePeriod: Duration
    @ObservationIgnored private let granter: any BackgroundExecutionGranting
    @ObservationIgnored private var token: BackgroundExecutionToken?
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    init(
        gracePeriod: Duration = AppActivityCoordinator.defaultGracePeriod,
        granter: any BackgroundExecutionGranting = UIKitBackgroundExecutionGranter()
    ) {
        self.gracePeriod = gracePeriod
        self.granter = granter
    }

    func didBecomeActive() {
        graceTask?.cancel()
        graceTask = nil
        releaseBackgroundExecution()
        phase = .active
    }

    func didEnterBackground() {
        guard phase == .active, graceTask == nil else { return }
        token = granter.begin { [weak self] in self?.backgroundTimeDidExpire() }
        guard token != nil else {
            // Without background time the process is about to freeze, so a
            // later teardown would never run. Tear down now instead.
            suspend()
            return
        }
        graceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: gracePeriod)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            suspend()
        }
    }

    /// The teardown that `.suspended` asked for has finished; the app no
    /// longer needs to stay awake. No-op after a foreground bounce beat the
    /// teardown home, or when expiration already took the assertion back.
    func didFinishSuspending() {
        guard phase == .suspended else { return }
        releaseBackgroundExecution()
    }

    private func suspend() {
        graceTask = nil
        guard phase != .suspended else { return }
        phase = .suspended
    }

    private func backgroundTimeDidExpire() {
        // Give the assertion back before anything else: the teardown then
        // races the process being frozen, which is the best outcome
        // available — the Host sees the TCP connection drop either way.
        graceTask?.cancel()
        releaseBackgroundExecution()
        suspend()
    }

    private func releaseBackgroundExecution() {
        guard let token else { return }
        self.token = nil
        granter.end(token)
    }
}
