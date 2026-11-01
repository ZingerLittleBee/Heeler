import Foundation

/// What the Helper needs of an SSH connection. Real SSH is `HeelerSSHTransport`;
/// tests script the Host.
protocol HostHelperHost: Sendable {
    func hostPlatform() async throws -> HostPlatform

    /// Runs one step's script in one bounded exec.
    func runHostHelperScript(_ script: HostHelperScript) async throws -> GitExecResult

    /// Reads one file of the Helper's over SFTP, keeping it and its private
    /// directory private to the user; nil when the file does not exist.
    func readHostHelperFile(at path: String, privateDirectory: String) async throws -> Data?

    /// Writes one file over SFTP: a 0600 temporary file renamed into place.
    /// With a `privateDirectory`, that directory is made 0700 first; the unit's
    /// folder is not Heeler's to change, so it passes none.
    func replaceHostHelperFile(_ contents: Data, at path: String, privateDirectory: String?) async throws
}

/// What an install is going to write, which the install sheet lists. It is the
/// only description of the install: the installer works from it.
struct HostHelperInstallPlan: Sendable, Equatable {
    let layout: HostHelperLayout
    let replacesHelper: Bool
    let nodePath: String

    init(reading: HostHelperReading, bundle: HostHelperBundle) throws {
        if case .newer(let version) = reading.integrity {
            throw HostHelperError.newerInstalled(version: version)
        }
        guard reading.unsupportedPlatform == nil, let layout = reading.layout else {
            throw HostHelperError.unsupportedPlatform
        }
        guard let nodePath = reading.nodePath else { throw HostHelperError.nodeMissing }
        guard let extensionFolders = reading.probe?.extensionFolders else {
            throw HostHelperError.extensionFoldersUnreadable
        }
        self.layout = layout
        self.nodePath = nodePath
        self.extensionFolders = extensionFolders.map(\.path)
        helperFiles = reading.replacesHelper
            ? (bundle.manifest.files.map(\.path) + [HostHelperScript.manifestFileName]) : []
        replacesHelper = reading.replacesHelper
    }

    private let helperFiles: [String]
    private let extensionFolders: [String]

    /// Heeler's extension in each folder Pi and Oh My Pi load extensions from.
    var extensionFiles: [String] {
        extensionFolders.map { "\($0)/\(HostHelperScript.extensionFileName)" }
    }

    /// Files written outside the Helper directory, which the record lists.
    var outsideFiles: [String] { [layout.unit, layout.unitWantsLink] + extensionFiles }

    /// Every folder the install needs, parents first.
    var folderChain: [String] { layout.folderChain(reaching: extensionFolders) }

    /// Every file the install leaves on the Host.
    var files: [String] {
        (helperFiles.map { "\(layout.app)/\($0)" } + [layout.record] + outsideFiles).sorted()
    }

    var unitText: String {
        HostHelperUnit.text(nodePath: nodePath, mainPath: layout.main)
    }
}

/// Installs, reads and removes the Host Helper on a Linux Host (ADR 0033). Every
/// step is one script or one SFTP write through `HostHelperHost`.
struct HostHelperInstaller: Sendable {
    let host: any HostHelperHost
    var nonce: @Sendable () -> String = { UUID().uuidString }
    /// Holds the script a read runs to find the extension folders.
    var bundle: @Sendable () throws -> HostHelperBundle = { try HostHelperBundle.load() }

    func read() async throws -> HostHelperReading {
        if try await host.hostPlatform() == .nativeWindows {
            return HostHelperReading(probe: nil)
        }
        let script = HostHelperScript(.probe, nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        var probe: HostHelperProbe
        do {
            probe = try HostHelperProbe(stdout: result.stdout, nonce: script.nonce)
        } catch {
            throw HostHelperError.unreadableHost
        }
        probe.extensionFolders = await extensionFolders(probe)
        return HostHelperReading(probe: probe)
    }

    /// Asks only a Host that could take an install. Not being able to say
    /// stands in the way of an install, which then says so, but not of a read
    /// or a removal.
    private func extensionFolders(_ probe: HostHelperProbe) async -> [HostHelperProbe.ExtensionFolder]? {
        guard HostHelperReading(probe: probe).unsupportedPlatform == nil, case .found(let node) = probe.node,
            let lister = (try? bundle())?.files[HostHelperScript.extensionFoldersPath]
        else { return nil }
        let script = HostHelperScript(
            .listExtensionFolders(
                node: node, lister: String(decoding: lister, as: UTF8.self), home: probe.locations.home),
            nonce: nonce())
        guard let result = try? await host.runHostHelperScript(script), result.exitStatus == 0 else { return nil }
        return try? HostHelperProbe.parseExtensionFolders(stdout: result.stdout, nonce: script.nonce)
    }

    /// Puts a Helper in place if the Host needs one, then sets up its service
    /// with the Node.js the Host has now, and returns what the Host then reads.
    func install(over reading: HostHelperReading, bundle: HostHelperBundle) async throws -> HostHelperReading {
        let plan = try HostHelperInstallPlan(reading: reading, bundle: bundle)
        let layout = plan.layout
        guard let extensionText = bundle.files[HostHelperScript.extensionPath] else {
            throw HostHelperError.bundleUnavailable
        }
        let created = try await makeFolders(plan)

        // Written first, so a failure below leaves removal knowing about them.
        // Until it is, nothing else does, so a failure here takes them back.
        let previous = reading.probe?.record.flatMap {
            try? JSONDecoder().decode(HostHelperInstallRecord.self, from: $0)
        }
        let record = (previous ?? HostHelperInstallRecord(files: [], folders: []))
            // The Helper directory goes as a whole, at the end of a removal.
            .merged(files: plan.outsideFiles, folders: created.filter { $0 != layout.directory })
        do {
            try await write(
                try Self.encoded(record), to: layout.record, in: layout.directory, step: "Writing the install record")
        } catch {
            await takeBack(created)
            throw error
        }

        if plan.replacesHelper {
            try await placeHelper(bundle, layout: layout)
        }
        for file in plan.extensionFiles {
            try await write(extensionText, to: file, in: nil, step: "Placing the Pi and Oh My Pi extensions")
        }
        try await write(Data(plan.unitText.utf8), to: layout.unit, in: nil, step: "Writing the service unit")
        try await startService()

        let after = try await read()
        if plan.replacesHelper, after.probe.map({ bundle.manifest.matches($0.hashes) }) != true {
            throw HostHelperError.verificationFailed
        }
        return after
    }

    /// Disables and stops the service, deletes the recorded files and then the
    /// created folders that are now empty, and finally the Helper directory with
    /// its registrations and seen marks. Linger stays as it is.
    func remove(over reading: HostHelperReading) async throws {
        guard reading.unsupportedPlatform == nil, let probe = reading.probe, let layout = reading.layout else {
            throw HostHelperError.unsupportedPlatform
        }
        let record = probe.record.flatMap { try? JSONDecoder().decode(HostHelperInstallRecord.self, from: $0) }
            // With no record, only the files that are certainly Heeler's.
            ?? HostHelperInstallRecord(
                files: [layout.unit, layout.unitWantsLink]
                    + (probe.extensionFolders ?? []).map { "\($0.path)/\(HostHelperScript.extensionFileName)" },
                folders: [])

        // No user manager means nothing runs, and nothing can be asked to stop.
        if let health = probe.health, health.isLoaded {
            try await systemctl(["disable", "--now", HostHelperScript.unitName], step: "Stopping the service")
        }
        try await check(.removeFiles(record.safeFiles), step: "Deleting the files")
        if probe.health != nil {
            _ = try await run(.systemctl(["daemon-reload"]))
            _ = try await run(.systemctl(["reset-failed", HostHelperScript.unitName]))
        }
        let folders = record.safeFolders.sorted(by: Self.deepestFirst)
        try await check(
            .removeEmptyFolders(folders.filter { !layout.holdsDirectory($0) }), step: "Deleting the folders")
        try await check(.removeTree(layout.directory), step: "Deleting the Host Helper directory")
        // Those above the Helper directory only empty once it has gone.
        try await check(
            .removeEmptyFolders(folders.filter { layout.holdsDirectory($0) }), step: "Deleting the folders")
    }

    /// Asks once and never waits for a password: a Host that wants an
    /// administrator refuses here, and the user reads why.
    func turnOnLinger(over reading: HostHelperReading) async throws {
        guard let probe = reading.probe else { throw HostHelperError.unsupportedPlatform }
        let result = try await run(.enableLinger(user: probe.user))
        guard result.exitStatus == 0 else {
            throw HostHelperError.lingerRefused(user: probe.user, detail: Self.detail(of: result))
        }
    }

    /// Every folder this run created, parents first. A failure takes back those
    /// it got to, since no record names them yet.
    private func makeFolders(_ plan: HostHelperInstallPlan) async throws -> [String] {
        let script = HostHelperScript(
            .makeFolders(plan.folderChain, privateFolder: plan.layout.directory), nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        let lines = try? HostHelperProbe.framedLines(stdout: result.stdout, nonce: script.nonce)
        let created = (lines ?? [])
            .filter { $0.hasPrefix("created ") }
            .map { String($0.dropFirst("created ".count)) }
        guard result.exitStatus == 0 else {
            await takeBack(created)
            throw HostHelperError.stepFailed(step: "Creating the folders", detail: Self.detail(of: result))
        }
        guard lines != nil else { throw HostHelperError.unreadableHost }
        return created
    }

    /// Only ever removes what is still empty. A connection that has gone cannot
    /// do even that, and the install's failure is what the user needs to read.
    private func takeBack(_ folders: [String]) async {
        guard !folders.isEmpty else { return }
        _ = try? await run(.removeEmptyFolders(folders.sorted(by: Self.deepestFirst)))
    }

    /// Uploads into a staging directory, checks the manifest there, and renames
    /// into place, so a Host never runs a half-written Helper.
    private func placeHelper(_ bundle: HostHelperBundle, layout: HostHelperLayout) async throws {
        let staging = "\(layout.directory)/\(HostHelperScript.stagingPrefix)\(nonce())"
        try await check(
            .prepareStaging(
                directory: layout.directory, staging: staging,
                folders: bundle.folders.map { "\(staging)/\($0)" }),
            step: "Preparing the upload")
        do {
            for file in bundle.manifest.files {
                guard let contents = bundle.files[file.path] else { throw HostHelperError.bundleUnavailable }
                try await write(contents, to: "\(staging)/\(file.path)", in: nil, step: "Uploading the Host Helper")
            }
            try await write(
                bundle.manifestData, to: "\(staging)/\(HostHelperScript.manifestFileName)", in: nil,
                step: "Uploading the Host Helper")
            let script = HostHelperScript(.hashTree(root: staging), nonce: nonce())
            let result = try await host.runHostHelperScript(script)
            let hashes: [String: String]?
            do {
                hashes = try HostHelperProbe.parseHashes(stdout: result.stdout, nonce: script.nonce)
            } catch {
                throw HostHelperError.unreadableHost
            }
            guard let hashes else { throw HostHelperError.noHashTool }
            guard bundle.manifest.matches(hashes) else { throw HostHelperError.verificationFailed }
        } catch {
            _ = try? await run(.removeTree(staging))
            throw error
        }
        try await check(.promote(staging: staging, app: layout.app), step: "Putting the Host Helper in place")
    }

    private func startService() async throws {
        try await systemctl(["daemon-reload"], step: "Reloading systemd")
        // A unit that failed for good refuses to start until this clears it.
        _ = try await run(.systemctl(["reset-failed", HostHelperScript.unitName]))
        try await systemctl(["enable", HostHelperScript.unitName], step: "Enabling the service")
        try await systemctl(["restart", HostHelperScript.unitName], step: "Starting the service")
    }

    private func systemctl(_ arguments: [String], step: String) async throws {
        try await check(.systemctl(arguments), step: step)
    }

    private func check(_ step: HostHelperScript.Step, step name: String) async throws {
        let result = try await run(step)
        guard result.exitStatus == 0 else {
            throw HostHelperError.stepFailed(step: name, detail: Self.detail(of: result))
        }
    }

    private func run(_ step: HostHelperScript.Step) async throws -> GitExecResult {
        try await host.runHostHelperScript(HostHelperScript(step, nonce: nonce()))
    }

    private func write(_ contents: Data, to path: String, in directory: String?, step: String) async throws {
        do {
            try await host.replaceHostHelperFile(contents, at: path, privateDirectory: directory)
        } catch let error as HostHelperError {
            throw error
        } catch {
            throw HostHelperError.stepFailed(step: step, detail: Self.detail(of: error))
        }
    }

    private static func encoded(_ record: HostHelperInstallRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record) + Data([0x0A])
    }

    private static func detail(of result: GitExecResult) -> String {
        String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// In words a person can read. What has none says nothing, not its type's name.
    private static func detail(of error: any Error) -> String {
        switch error {
        case NotificationRegistrationError.writeFailed(let detail): detail
        case let error as TransportError: error.presentation.message
        default: ""
        }
    }

    private static func deepestFirst(_ first: String, _ second: String) -> Bool {
        let depth = { (path: String) in path.split(separator: "/").count }
        return depth(first) == depth(second) ? first < second : depth(first) > depth(second)
    }
}
