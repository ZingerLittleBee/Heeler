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
/// tear the connections down (the deliberate teardown of ADR 0011; iOS
/// freezes the sockets anyway once the process is suspended).
enum AppActivityPhase: Sendable, Equatable {
    case active
    case suspended
}

/// What the coordinator hands whoever drives the Host connections.
///
/// Deliberately a stream of events rather than an observation of `phase`.
/// The suspension is produced by a timer *while the app is in the background
/// and drawing nothing*, and the foreground return that follows can land in
/// the same update cycle, so a consumer that only compares the value it last
/// saw can miss the round trip entirely — and with it both the teardown and
/// the resume. That is #142: the app came back holding a connection nothing
/// had torn down and nothing had asked whether it was still alive, so a
/// session whose link died while the app was away kept rendering as
/// connected — no reconnect, no error — until the keepalive got round to
/// noticing, up to its interval plus a request timeout later.
///
/// `activated` is reported on *every* return to the foreground, not only
/// after a suspension: a connection frozen along with the process may have
/// died in the meantime without anything having asked it.
enum AppActivityEvent: Sendable, Equatable {
    case activated
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

    /// Increments on every foreground return, whether or not the grace period
    /// ever reached `.suspended`.
    ///
    /// `phase` cannot carry that signal. A background→foreground round trip
    /// the grace period absorbs never leaves `.active`, so a SwiftUI
    /// `onChange` on the phase observes nothing and the return goes unnoticed
    /// — the same coalescing `events` exists to defeat. `events` has a single
    /// consumer by construction; screens that come and go need a value they
    /// can observe instead, and a monotonic counter is one no `onChange` can
    /// miss.
    private(set) var activationCount: UInt64 = 0

    /// Whether the absence that ended in the most recent activation lasted at
    /// least the grace period.
    ///
    /// Measured on a clock rather than inferred from `phase`, because the
    /// process is frozen for exactly the absences that matter. When iOS
    /// suspends us before the grace timer fires, no `.suspended` is ever
    /// published and the app comes back believing it never left — yet the
    /// wall clock says it was gone for minutes. This is the only signal that
    /// survives that freeze, and it is what tells a glance at a notification
    /// apart from an absence long enough to have cost the Attach terminal its
    /// surface (#141).
    private(set) var lastAbsenceOutlastedGrace = false

    /// Every transition, in order and exactly once each. Buffered rather than
    /// latest-value: a background→foreground round trip that completes before
    /// the consumer gets to run must still produce both the teardown and the
    /// activation.
    @ObservationIgnored nonisolated let events: AsyncStream<AppActivityEvent>
    @ObservationIgnored
    private nonisolated let eventsContinuation: AsyncStream<AppActivityEvent>.Continuation
    @ObservationIgnored private let gracePeriod: Duration
    @ObservationIgnored private let granter: any BackgroundExecutionGranting
    /// Injected so a test can state an absence instead of sleeping one.
    /// `ContinuousClock` on purpose: it keeps counting while the process is
    /// suspended, which `SuspendingClock` does not.
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var token: BackgroundExecutionToken?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var leftForegroundAt: ContinuousClock.Instant?

    init(
        gracePeriod: Duration = AppActivityCoordinator.defaultGracePeriod,
        granter: any BackgroundExecutionGranting = UIKitBackgroundExecutionGranter(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.gracePeriod = gracePeriod
        self.granter = granter
        self.now = now
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: AppActivityEvent.self, bufferingPolicy: .unbounded)
    }

    func didBecomeActive() {
        graceTask?.cancel()
        graceTask = nil
        releaseBackgroundExecution()
        phase = .active
        // Reported before `activationCount`, which is what observers key off:
        // the counter is the edge, and the flag must already be true when it
        // is read.
        lastAbsenceOutlastedGrace = leftForegroundAt.map { now() - $0 >= gracePeriod } ?? false
        leftForegroundAt = nil
        activationCount &+= 1
        eventsContinuation.yield(.activated)
    }

    func didEnterBackground() {
        guard phase == .active, graceTask == nil else { return }
        leftForegroundAt = now()
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
        eventsContinuation.yield(.suspended)
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
