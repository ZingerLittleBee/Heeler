import Foundation

/// One Agent's Composer and the staging its picks and drops upload through.
///
/// The Console owns one per Agent, above every view that shows it: a rebuilt
/// detail, a retained terminal's release or eviction, a reconnect, Changes
/// pushed over the detail and Chat in the terminal's place all leave an
/// upload alone. The last detail leaving the Agent cancels it; suspension
/// interrupts it, for Retry once the app is back.
@MainActor
final class AgentComposerSession {
    let composer: AgentComposerStore
    /// Holds the Composer strongly; the Composer holds it weakly.
    let staging: ComposerStagingStore
    /// The details showing this Agent, one key per window.
    private var presence: Set<UUID> = []
    private var leaveTask: Task<Void, Never>?
    private var leaveGeneration: UInt64 = 0

    init(
        composer: AgentComposerStore,
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager
    ) {
        self.composer = composer
        staging = ComposerStagingStore(
            stageImage: stageImage, stageFile: stageFile, composer: composer)
        composer.bindStaging(staging)
    }

    func detailDidAppear(_ key: UUID) {
        presence.insert(key)
    }

    /// The last detail to leave cancels the staging; returns that leave.
    @discardableResult
    func detailDidDisappear(_ key: UUID) -> Task<Void, Never>? {
        guard presence.remove(key) != nil, presence.isEmpty else { return nil }
        return leaveStaging()
    }

    /// Cancels the upload and the drops still queued, then lets drops start
    /// again once the staging has settled. Leaves run in order, and only the
    /// latest lets drops start, so one still ahead of it cannot.
    @discardableResult
    func leaveStaging() -> Task<Void, Never> {
        composer.abandonDroppedImagesForTeardown()
        leaveGeneration &+= 1
        let generation = leaveGeneration
        let previous = leaveTask
        let task = Task { @MainActor [weak self, composer, staging] in
            await previous?.value
            await staging.leave()
            guard self?.leaveGeneration == generation else { return }
            composer.resumeDroppedImages()
        }
        leaveTask = task
        return task
    }

    /// The app is suspending: an upload in flight stops as interrupted and
    /// keeps what Retry needs. Only once the grace period has run out: an
    /// upload is exactly the work worth finishing while the app is briefly
    /// out of sight.
    func didSuspend() {
        staging.didEnterBackground()
    }
}
