import Foundation

/// The Host Helper version this app build bundles.
enum HostHelperCompatibility {
    /// `plugin/helper/version.json` when this app was built. The shared
    /// `plugin/test-vectors/host-helper-version-v1.json` pins both sides, so a
    /// Helper release must update this constant too.
    static let bundled = PluginVersion(0, 5, 4)
    /// The first Helper that sends Agent Notifications.
    static let firstWithNotifications = PluginVersion(0, 4, 0)
    /// The first Helper that drives a Live Activity through the Push Relay.
    static let firstWithLiveActivities = PluginVersion(0, 5, 0)
}

/// `plugin/helper/manifest.json`: the version and every other file's SHA-256,
/// written and checked by `scripts/generate-host-helper-manifest.mjs`.
struct HostHelperManifest: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        let path: String
        let sha256: String
    }

    let version: String
    let files: [File]

    /// True when a tree's hashes are exactly this manifest's: nothing changed,
    /// nothing missing, and nothing added.
    func matches(_ hashes: [String: String]) -> Bool {
        hashes == Dictionary(files.map { ($0.path, $0.sha256) }) { first, _ in first }
    }
}

/// The Helper's files as the app carries them, a folder resource of the bundle.
struct HostHelperBundle: Sendable, Equatable {
    static let resourceName = "helper"

    enum LoadError: Error, Equatable {
        case missing
        case unreadable(String)
    }

    let manifest: HostHelperManifest
    let manifestData: Data
    let files: [String: Data]

    init(manifest: HostHelperManifest, manifestData: Data, files: [String: Data]) {
        self.manifest = manifest
        self.manifestData = manifestData
        self.files = files
    }

    static func load(from bundle: Bundle = .main) throws -> HostHelperBundle {
        guard let root = bundle.url(forResource: resourceName, withExtension: nil) else {
            throw LoadError.missing
        }
        let manifestData: Data
        let manifest: HostHelperManifest
        do {
            manifestData = try Data(contentsOf: root.appendingPathComponent(HostHelperScript.manifestFileName))
            manifest = try JSONDecoder().decode(HostHelperManifest.self, from: manifestData)
        } catch {
            throw LoadError.unreadable(HostHelperScript.manifestFileName)
        }
        var files: [String: Data] = [:]
        for file in manifest.files {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(file.path)) else {
                throw LoadError.unreadable(file.path)
            }
            files[file.path] = data
        }
        return HostHelperBundle(manifest: manifest, manifestData: manifestData, files: files)
    }

    /// The subfolders the files sit in, relative to the Helper's root.
    var folders: [String] {
        var folders = Set<String>()
        for path in files.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                folders.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return folders.sorted()
    }
}

/// Where everything of the Helper's sits on a Host. Notification and Usage files
/// live in `directory`, whose `app` folder alone gets replaced.
struct HostHelperLayout: Sendable, Equatable {
    static let recordFileName = HostHelperScript.recordFileName

    let directory: String
    let manager: HostHelperServiceManager
    let unitDirectory: String
    let launchAgentDirectory: String

    init(locations: HostHelperProbe.Locations, manager: HostHelperServiceManager = .systemd) {
        directory = "\(locations.dataHome)/\(HostHelperScript.helperDirectorySuffix)"
        self.manager = manager
        unitDirectory = "\(locations.configHome)/systemd/user"
        launchAgentDirectory = "\(locations.home)/Library/LaunchAgents"
    }

    var app: String { "\(directory)/\(HostHelperScript.appFolderName)" }
    var record: String { "\(directory)/\(Self.recordFileName)" }
    var unit: String { "\(unitDirectory)/\(HostHelperScript.unitName)" }
    var main: String { "\(app)/main.js" }
    var unitWantsDirectory: String { "\(unitDirectory)/default.target.wants" }
    /// The link `systemctl enable` makes.
    var unitWantsLink: String { "\(unitWantsDirectory)/\(HostHelperScript.unitName)" }
    var launchAgent: String { "\(launchAgentDirectory)/\(HostHelperLaunchAgent.fileName)" }
    /// launchd keeps no journal, so the agent logs here. It goes with the directory.
    var log: String { file(named: HostHelperLaunchAgent.logFileName) }

    /// What registers the service, outside the Helper directory.
    var serviceFiles: [String] {
        switch manager {
        case .systemd: [unit, unitWantsLink]
        case .launchd: [launchAgent]
        }
    }

    func file(named name: String) -> String { "\(directory)/\(name)" }

    /// Every folder down to the deepest ones the install needs, parents first.
    func folderChain(reaching extensionFolders: [String]) -> [String] {
        let serviceFolder = manager == .systemd ? unitWantsDirectory : launchAgentDirectory
        var chain: [String] = []
        for deepest in [directory, serviceFolder] + extensionFolders {
            var path = ""
            for component in deepest.split(separator: "/") {
                path += "/\(component)"
                if !chain.contains(path) { chain.append(path) }
            }
        }
        return chain
    }

    /// Whether `folder` contains the Helper directory, so it cannot be empty
    /// until that is gone.
    func holdsDirectory(_ folder: String) -> Bool {
        directory.hasPrefix(folder + "/")
    }
}

/// `installed.json`: what removal may delete. It lists every file written
/// outside the Helper directory and every folder the install created, and on a
/// Mac the label of the LaunchAgent to boot out first.
struct HostHelperInstallRecord: Codable, Sendable, Equatable {
    var version = 1
    var files: [String]
    var folders: [String]
    var launchAgentLabel: String?

    init(files: [String], folders: [String], launchAgentLabel: String? = nil) {
        self.files = files
        self.folders = folders
        self.launchAgentLabel = launchAgentLabel
    }

    /// Paths this record may name for deletion.
    private static func isSafe(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count > 1
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    var safeFiles: [String] { files.filter(Self.isSafe) }
    var safeFolders: [String] { folders.filter(Self.isSafe) }

    func merged(files newFiles: [String], folders newFolders: [String]) -> HostHelperInstallRecord {
        HostHelperInstallRecord(
            files: Array(Set(files).union(newFiles)).sorted(),
            folders: Array(Set(folders).union(newFolders)).sorted(),
            launchAgentLabel: launchAgentLabel)
    }
}

/// Why a Host cannot run the Helper.
enum HostHelperUnsupportedPlatform: Sendable, Equatable {
    case nativeWindows
    /// A Unix other than Linux and macOS, by its kernel's name.
    case other(String)
    /// Linux without systemd, which registers the service.
    case noSystemd
}

enum HostHelperStatus: Sendable, Equatable {
    case notInstalled
    case installed(version: PluginVersion, updateAvailable: Bool)
    /// Another device installed a newer one, which this build never replaces.
    case newer(version: PluginVersion)
    case damaged
    /// `tooOld` is the version the Host has, when it has one.
    case nodeMissing(tooOld: String?)
    case lingerOff
    /// Running, on a Node.js that has since gone from where the service names it,
    /// so it would not start again and Usage has nothing to run.
    case serviceNodeGone
    /// `health` is nil when systemd's user manager could not be reached. On a
    /// Mac it also stands for an agent that is not staying up, or not loaded.
    case serviceFailed(HostHelperHealth?)
    case unsupportedPlatform(HostHelperUnsupportedPlatform)
}

enum HostHelperInstallAction: Sendable, Equatable {
    case install
    case update
    case repair

    var title: String {
        switch self {
        case .install: String(localized: "Install")
        case .update: String(localized: "Update")
        case .repair: String(localized: "Repair")
        }
    }
}

/// What one read of a Host established about its Helper.
struct HostHelperReading: Sendable, Equatable {
    enum Integrity: Sendable, Equatable {
        case absent
        case intact(version: PluginVersion)
        case newer(version: PluginVersion)
        case damaged
    }

    /// Nil only on native Windows, which has no POSIX shell to probe.
    let probe: HostHelperProbe?
    let bundled: PluginVersion

    init(probe: HostHelperProbe?, bundled: PluginVersion = HostHelperCompatibility.bundled) {
        self.probe = probe
        self.bundled = bundled
    }

    var layout: HostHelperLayout? {
        probe.map { HostHelperLayout(locations: $0.locations, manager: $0.manager) }
    }

    var unsupportedPlatform: HostHelperUnsupportedPlatform? {
        guard let probe else { return .nativeWindows }
        switch probe.kernel {
        case HerdrCoreLocator.linuxKernel: return probe.hasSystemd ? nil : .noSystemd
        case HerdrCoreLocator.macOSKernel: return nil
        default: return .other(probe.kernel)
        }
    }

    /// One read cannot say a LaunchAgent stays up (ADR 0033): this one has to be
    /// followed by another.
    var awaitsSecondHealthRead: Bool {
        guard let health = probe?.health, let launchd = health.launchd else { return false }
        return health.isLoaded && launchd.staysRunning == nil
    }

    /// Nothing loads the property list back after a restart of the Mac, as far as
    /// a VM of macOS 26.5 showed (ADR 0033). The install is all still there and
    /// launchd simply does not hold it, so no one has to be asked to load it again.
    var agentNeedsLoading: Bool {
        guard let probe, unsupportedPlatform == nil, probe.manager == .launchd, probe.launchAgentFilePresent,
            probe.record != nil, probe.health?.loadState == HostHelperHealth.launchdNotFound, nodeProblem == nil
        else { return false }
        switch integrity {
        case .intact, .newer: return true
        case .absent, .damaged: return false
        }
    }

    var integrity: Integrity {
        guard let probe, probe.appPresent else { return .absent }
        guard let data = probe.manifest,
            let manifest = try? JSONDecoder().decode(HostHelperManifest.self, from: data),
            let version = PluginVersion(manifest.version)
        else { return .damaged }
        // Never replaced from here, whatever state its files are in.
        if version > bundled { return .newer(version: version) }
        // Nothing here could hash the files, which says nothing against them.
        if probe.hashToolMissing { return .intact(version: version) }
        return manifest.matches(probe.hashes) ? .intact(version: version) : .damaged
    }

    var status: HostHelperStatus {
        if let unsupportedPlatform { return .unsupportedPlatform(unsupportedPlatform) }
        guard let probe else { return .unsupportedPlatform(.nativeWindows) }
        switch integrity {
        case .newer(let version):
            // A newer Helper is left as it is, but that says nothing of whether it runs.
            guard let health = probe.health, health.isLoaded, health.isUp else {
                return nodeProblem ?? .serviceFailed(probe.health)
            }
            return .newer(version: version)
        case .damaged:
            return nodeProblem ?? .damaged
        case .absent:
            return nodeProblem ?? .notInstalled
        case .intact(let version):
            guard let health = probe.health else { return nodeProblem ?? .serviceFailed(nil) }
            if !health.isLoaded {
                // Files all there and launchd not holding them is launchd's side.
                let filesInPlace = probe.manager == .launchd && probe.launchAgentFilePresent
                return nodeProblem ?? (filesInPlace ? .serviceFailed(health) : .damaged)
            }
            if !health.isUp { return nodeProblem ?? .serviceFailed(health) }
            // An older Helper's Update sets the service up again too.
            if probe.serviceNodeGone, version >= bundled { return nodeProblem ?? .serviceNodeGone }
            if probe.manager == .systemd, !probe.lingerOn { return .lingerOff }
            return .installed(version: version, updateAvailable: version < bundled)
        }
    }

    private var nodeProblem: HostHelperStatus? {
        switch probe?.node {
        case .found, nil: nil
        case .tooOld(let version): .nodeMissing(tooOld: version)
        case .missing: .nodeMissing(tooOld: nil)
        }
    }

    /// The Node.js the service would name, when the Host has one to name.
    var nodePath: String? {
        if case .found(let path) = probe?.node { path } else { nil }
    }

    /// True when an install would put new Helper files in place. An older
    /// device never does over a newer Helper.
    var replacesHelper: Bool {
        switch integrity {
        case .absent, .damaged: true
        case .intact(let version): version < bundled
        case .newer: false
        }
    }

    /// What the install sheet offers. Nothing on a Host that cannot run it, or
    /// that has nothing to fix.
    var installAction: HostHelperInstallAction? {
        guard unsupportedPlatform == nil, nodePath != nil else { return nil }
        switch integrity {
        case .absent: return .install
        case .damaged: return .repair
        case .newer: return nil
        case .intact(let version):
            if version < bundled { return .update }
            switch status {
            case .damaged, .serviceFailed, .serviceNodeGone: return .repair
            default: return lacksAnExtension ? .repair : nil
            }
        }
    }

    /// An Oh My Pi profile made since the install has no extension yet, and the
    /// Helper itself is fine, so this offers a repair without calling it damage.
    private var lacksAnExtension: Bool {
        probe?.extensionFolders?.contains { !$0.installed } ?? false
    }

    /// What an install that stopped partway leaves: a staging folder or half-written
    /// file in the Helper directory, or a record with no Helper beside it.
    var leftInterruptedInstall: Bool {
        guard unsupportedPlatform == nil, let probe else { return false }
        return probe.leftovers || (probe.record != nil && !probe.appPresent)
    }

    /// Whether there is anything of the Helper's on this Host to remove.
    var offersRemoval: Bool {
        guard unsupportedPlatform == nil, let probe else { return false }
        return probe.appPresent || probe.record != nil
    }

    /// Whether to offer turning linger on, which the Helper needs to run while
    /// nobody is logged in.
    var offersLinger: Bool {
        guard unsupportedPlatform == nil, let probe, probe.manager == .systemd else { return false }
        return !probe.lingerOn
    }

    /// How this reading's status shows on Host detail and in the install sheet.
    var presentation: HostHelperPresentation {
        HostHelperPresentation(status, canRepair: installAction != nil)
    }

    var notificationStanding: HostHelperNotificationStanding {
        HostHelperNotificationStanding(self)
    }
}

/// What a core Host's Helper means for its Agent Notifications, where the user
/// turns them on.
struct HostHelperNotificationStanding: Sendable, Equatable {
    /// Whether this device can register with the Helper now.
    let canRegister: Bool
    /// The Helper's status as what notifications need of it. Nil when they need
    /// nothing more.
    let requirement: String?
    /// Whether it keeps a Live Activity current once the app has suspended.
    let drivesLiveActivity: Bool

    init(_ reading: HostHelperReading) {
        let status = reading.status
        let presentation = reading.presentation
        let action = String(localized: "See this Host's page in Hosts.")
        let asRequirement = String(localized: "Host Helper: \(presentation.value). \(presentation.detail) \(action)")
        var installedVersion: PluginVersion?
        if case .intact(let version) = reading.integrity { installedVersion = version }
        if let installedVersion, installedVersion < HostHelperCompatibility.firstWithNotifications {
            canRegister = false
            requirement = String(localized: "Host Helper: \(presentation.value). Notifications need a newer Host Helper. \(action)")
            drivesLiveActivity = false
            return
        }
        let lacksLiveActivity = installedVersion.map { $0 < HostHelperCompatibility.firstWithLiveActivities } ?? false
        switch status {
        case .installed, .newer:
            canRegister = true
            requirement =
                lacksLiveActivity
                ? String(localized: "Host Helper: \(presentation.value). Live Activity needs a newer Host Helper. \(action)") : nil
            drivesLiveActivity = !lacksLiveActivity
        case .lingerOff, .serviceNodeGone:
            // It runs now, so it notifies, only not once the last login has ended
            // or once this process ends.
            canRegister = true
            requirement = asRequirement
            drivesLiveActivity = !lacksLiveActivity
        case .notInstalled, .damaged, .nodeMissing, .serviceFailed:
            canRegister = false
            requirement = asRequirement
            drivesLiveActivity = false
        case .unsupportedPlatform:
            // Nothing on the Host's page changes this.
            canRegister = false
            requirement = presentation.detail
            drivesLiveActivity = false
        }
    }
}

/// How a status reads on Host detail and in the install sheet.
struct HostHelperPresentation: Sendable, Equatable {
    let value: String
    let detail: String
    /// Asks for attention on the row.
    let needsAttention: Bool

    static let featuresSentence =
        String(localized: "Agent Notifications, Live Activity and Usage on this Host come with the Host Helper.")

    /// `canRepair` is false when this device offers no Repair for that status,
    /// so the copy names what does change it.
    init(_ status: HostHelperStatus, canRepair: Bool = true) {
        switch status {
        case .notInstalled:
            value = String(localized: "Not Installed")
            detail = Self.featuresSentence
            needsAttention = false
        case .installed(let version, let updateAvailable):
            value = "\(version)"
            detail = updateAvailable
                ? String(localized: "This app carries a newer Host Helper.")
                : String(localized: "The Host Helper is running.")
            needsAttention = updateAvailable
        case .newer(let version):
            value = "\(version)"
            detail = String(localized: "A newer version of Heeler installed this Host Helper. Update the app to change it.")
            needsAttention = false
        case .damaged:
            value = String(localized: "Damaged")
            detail = String(localized: "Files of the Host Helper are missing or changed. Repair puts them back.")
            needsAttention = true
        case .nodeMissing(let tooOld):
            value = String(localized: "Node.js Missing")
            let minimum = NodeToolchainProbe.minimumMajorVersion
            detail = tooOld.map { String(localized: "The Host Helper needs Node.js \(minimum) or newer, and this Host has \($0).") }
                ?? String(localized: "The Host Helper needs Node.js \(minimum) or newer, and Heeler could not find it on this Host.")
            needsAttention = true
        case .lingerOff:
            value = String(localized: "Linger Off")
            detail = String(localized: "The Host Helper stops about ten seconds after your last login to this Host ends, unless systemd linger is on.")
            needsAttention = true
        case .serviceNodeGone:
            value = String(localized: "Node.js Moved")
            detail = String(localized: "The Host Helper is running, but the Node.js it was set up with has gone from this Host, so Usage cannot read and the Helper would not start again. Repair sets it up again with the Node.js this Host has now.")
            needsAttention = true
        case .serviceFailed(let health):
            value = String(localized: "Service Failed")
            detail = Self.failure(health, canRepair: canRepair)
            needsAttention = true
        case .unsupportedPlatform(.nativeWindows):
            value = String(localized: "Not Available")
            detail = String(localized: "Agent Notifications (in-app banners included), Live Activity and Usage are not available on native Windows yet because they come with the Host Helper.")
            needsAttention = false
        case .unsupportedPlatform(.other(let kernel)):
            value = String(localized: "Not Available")
            detail = String(localized: "The Host Helper does not run on \(kernel).")
            needsAttention = false
        case .unsupportedPlatform(.noSystemd):
            value = String(localized: "Not Available")
            detail = String(localized: "The Host Helper runs as a systemd user service, and this Host has no systemd.")
            needsAttention = false
        }
    }

    private static func failure(_ health: HostHelperHealth?, canRepair: Bool) -> String {
        let remedy = canRepair
            ? String(localized: "Repair sets it up again with the Node.js this Host has now.")
            : String(localized: "A newer version of Heeler installed this Host Helper. Update the app to change it.")
        guard let health else {
            return String(localized: "Heeler could not reach this Host's systemd user manager to ask about the service. \(remedy)")
        }
        let restarts = health.restarts == 1 ? String(localized: "1 restart") : String(localized: "\(health.restarts) restarts")
        guard health.launchd != nil else {
            return String(localized: "The service stopped and will not start again by itself (\(health.activeState), result \(health.result), \(restarts)). \(remedy)")
        }
        if health.loadState == HostHelperHealth.launchdNotFound {
            return String(localized: "launchd does not have the service loaded. \(remedy)")
        }
        if !health.isLoaded {
            return String(localized: "launchd did not say how the service is (\(health.result)). \(remedy)")
        }
        let facts = [health.activeState, health.result, restarts].filter { !$0.isEmpty }
            .joined(separator: ", ")
        return String(localized: "The service is not staying up (\(facts)). \(remedy)")
    }
}

enum HostHelperError: Error, Equatable {
    case bundleUnavailable
    case newerInstalled(version: PluginVersion)
    case nodeMissing
    case unsupportedPlatform
    case unreadableHost
    case extensionFoldersUnreadable
    case noHashTool
    case verificationFailed
    case stepFailed(step: String, detail: String)
    case lingerRefused(user: String, detail: String)

    var message: String {
        switch self {
        case .bundleUnavailable:
            String(localized: "This build of Heeler does not carry the Host Helper.")
        case .newerInstalled(let version):
            String(localized: "This Host has Host Helper \(String(describing: version)), newer than this app's. Update the app to change it.")
        case .nodeMissing:
            String(localized: "The Host Helper needs Node.js \(NodeToolchainProbe.minimumMajorVersion) or newer on this Host.")
        case .unsupportedPlatform:
            String(localized: "This Host cannot run the Host Helper yet.")
        case .unreadableHost:
            String(localized: "Could not read this Host's answer about the Host Helper.")
        case .extensionFoldersUnreadable:
            String(localized: "Heeler could not find where this Host's Pi and Oh My Pi load extensions from.")
        case .noHashTool:
            String(localized: "This Host has neither sha256sum nor shasum, so Heeler cannot check the Host Helper's files.")
        case .verificationFailed:
            String(localized: "The Host Helper's files did not match after the upload, so it was not put in place.")
        case .stepFailed(let step, let detail):
            detail.isEmpty ? String(localized: "\(step) failed.") : String(localized: "\(step) failed: \(detail)")
        case .lingerRefused(let user, let detail):
            detail.isEmpty
                ? String(localized: "This Host did not let Heeler turn on linger. An administrator can run: sudo loginctl enable-linger \(user)")
                : String(localized: "This Host did not let Heeler turn on linger: \(detail) An administrator can run: sudo loginctl enable-linger \(user)")
        }
    }
}
