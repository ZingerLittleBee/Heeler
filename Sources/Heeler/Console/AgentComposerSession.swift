import Foundation
import Observation

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
    /// The core this Composer's Agent runs on, which the details showing it keep to.
    let corePin: TerminalCorePin
    /// Chat's confirmed status-line switches, which every Chat showing this
    /// Agent reads, and a rebuilt one keeps.
    let settingOverrides = AgentSettingOverrides()
    /// The details showing this Agent, one key per window.
    private var presence: Set<UUID> = []
    private var leaveTask: Task<Void, Never>?
    private var leaveGeneration: UInt64 = 0

    init(
        composer: AgentComposerStore,
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager,
        corePin: TerminalCorePin = TerminalCorePin(),
        saysTransportFailures: Bool = false,
        filePreparer: any FilePreparing = FilePreparer()
    ) {
        self.composer = composer
        self.corePin = corePin
        staging = ComposerStagingStore(
            filePreparer: filePreparer, stageImage: stageImage, stageFile: stageFile, composer: composer,
            saysTransportFailures: saysTransportFailures)
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
    /// latest lets drops start, so one still ahead of it cannot. Voice Input
    /// is dropped too: its text would land in a draft nobody is looking at.
    @discardableResult
    func leaveStaging() -> Task<Void, Never> {
        composer.voice.cancel()
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

/// The mode, model and effort a status-line switch confirmed, each over the
/// transcript's value for it when it was made: once the transcript records
/// another, the transcript's stands again.
@MainActor
@Observable
final class AgentSettingOverrides {
    enum Setting: Int { case permissionMode, model, effort }

    private var values: [String?] = [nil, nil, nil]
    private var recorded: [String?] = [nil, nil, nil]
    /// A switch's paste or key got no answer, so it may still reach the
    /// Agent's input; the next input waits until the Host answers a read.
    var lastSwitchHasNoAnswer = false
    /// Shared by all Chat windows while a menu reads or changes the terminal.
    var switchingSetting: Setting?

    private(set) var permissionLaunch: ClaudePermissionMode.Launch?
    private var livePermissionMode: String?
    private var bypassMissingFromCycle: ClaudePermissionMode.ProcessIdentity?

    var allowsBypassPermissions: Bool {
        if livePermissionMode == "bypassPermissions" { return true }
        guard let permissionLaunch, permissionLaunch.process != bypassMissingFromCycle else { return false }
        return permissionLaunch.optsIntoBypass
    }

    func refreshPermissionLaunch(_ launch: ClaudePermissionMode.Launch?, liveMode: String?) {
        if let launch, let previous = permissionLaunch, launch.process != previous.process {
            bypassMissingFromCycle = nil
        }
        permissionLaunch = launch
        livePermissionMode = liveMode
    }

    func bypassWasMissingFromCycle() {
        bypassMissingFromCycle = permissionLaunch?.process
        livePermissionMode = nil
    }

    func value(_ setting: Setting, over now: [String?]) -> String? {
        recorded[setting.rawValue] == now[setting.rawValue] ? values[setting.rawValue] : nil
    }

    func set(_ setting: Setting, _ value: String?, over now: [String?]) {
        values[setting.rawValue] = value
        recorded[setting.rawValue] = now[setting.rawValue]
    }
}
