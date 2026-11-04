import Foundation
import OSLog

/// Drives the Console's Host connections from app activity: the one place
/// that turns a suspension into a teardown and a foreground return into a
/// resume.
///
/// A stream consumer rather than a SwiftUI `onChange` on the coordinator's
/// phase, because the transitions it must not miss happen while the app is
/// in the background and rendering nothing (see `AppActivityEvent`). Every
/// event's Console work is handled to completion before the next one starts,
/// so a rapid background→foreground bounce resumes *after* the teardown it
/// raced rather than interleaving with it.
///
/// Overlay work runs on its own chain, in event order but off this loop.
/// Stopping a node is a native call with no deadline; holding the loop on one
/// that never returns left every Host Paused after the app came back (#474).
@MainActor
struct ConsoleActivityDriver {
    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "Activity")

    let activity: AppActivityCoordinator
    let console: ConsoleStore
    /// Runs after the Console's teardown, still under the background
    /// assertion: the Overlay Network runtime stops its nodes here.
    var afterSuspend: (@Sendable () async -> Void)? = nil
    /// Runs after Console reactivation on every foreground return, including
    /// one inside the grace period. Pending browser sign-ins resume here so
    /// their nodes cannot race the preceding suspension teardown.
    var afterResume: (@Sendable () async -> Void)? = nil

    /// Consumes activity events until the app ends. Cancellation ends it.
    func run() async {
        let overlay = OverlayLifecycle()
        for await event in activity.events {
            guard !Task.isCancelled else { return }
            switch event {
            case .activated:
                Self.log.notice("Reactivating the Console")
                await console.reactivate()
                Self.log.notice("Reactivated the Console")
                if let afterResume {
                    overlay.enqueue { await afterResume() }
                }
            case .suspended:
                // The background assertion is held until overlay teardown
                // also finishes, so the SSH and node teardown both complete
                // before the process freezes. A later suspension's assertion
                // is that suspension's to release.
                Self.log.notice("Suspending the Console")
                await console.suspend()
                Self.log.notice("Suspended the Console")
                let suspension = overlay.beginSuspension()
                let activity = activity
                let afterSuspend = afterSuspend
                overlay.enqueue {
                    await afterSuspend?()
                    Self.log.notice("Finished overlay suspension \(suspension, privacy: .public)")
                    guard overlay.isLatestSuspension(suspension) else { return }
                    activity.didFinishSuspending()
                }
            }
        }
    }
}

/// Serializes the driver's Overlay Network work. Nodes must stop before any
/// sign-in resumes them, but the Console must not wait for either.
@MainActor
private final class OverlayLifecycle {
    private var tail: Task<Void, Never>?
    private var suspensions: UInt64 = 0

    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    func beginSuspension() -> UInt64 {
        suspensions &+= 1
        return suspensions
    }

    func isLatestSuspension(_ suspension: UInt64) -> Bool {
        suspensions == suspension
    }
}
