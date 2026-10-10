import Foundation

/// Drives the Console's Host connections from app activity: the one place
/// that turns a suspension into a teardown and a foreground return into a
/// resume.
///
/// A stream consumer rather than a SwiftUI `onChange` on the coordinator's
/// phase, because the transitions it must not miss happen while the app is
/// in the background and rendering nothing (see `AppActivityEvent`). Every
/// event is handled to completion before the next one starts, so a rapid
/// background→foreground bounce resumes *after* the teardown it raced rather
/// than interleaving with it.
@MainActor
struct ConsoleActivityDriver {
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
        for await event in activity.events {
            guard !Task.isCancelled else { return }
            switch event {
            case .activated:
                await console.reactivate()
                await afterResume?()
            case .suspended:
                // The background assertion is held until this returns, so
                // the SSH teardown finishes before the process freezes.
                await console.suspend()
                await afterSuspend?()
                activity.didFinishSuspending()
            }
        }
    }
}
