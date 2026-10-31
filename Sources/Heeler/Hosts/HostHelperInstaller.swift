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
        self.layout = layout
        self.nodePath = nodePath
        helperFiles = reading.replacesHelper
            ? (bundle.manifest.files.map(\.path) + [HostHelperScript.manifestFileName]) : []
        replacesHelper = reading.replacesHelper
    }

    private let helperFiles: [String]

    /// Files written outside the Helper directory, which the record lists.
    var outsideFiles: [String] { [layout.unit, layout.unitWantsLink] }

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

    func read() async throws -> HostHelperReading {
        if try await host.hostPlatform() == .nativeWindows {
            return HostHelperReading(probe: nil)
        }
        let script = HostHelperScript(.probe, nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        do {
            return HostHelperReading(probe: try HostHelperProbe(stdout: result.stdout, nonce: script.nonce))
        } catch {
            throw HostHelperError.unreadableHost
        }
    }

    /// Puts a Helper in place if the Host needs one, then sets up its service
    /// with the Node.js the Host has now, and returns what the Host then reads.
    func install(over reading: HostHelperReading, bundle: HostHelperBundle) async throws -> HostHelperReading {
        let plan = try HostHelperInstallPlan(reading: reading, bundle: bundle)
        let layout = plan.layout
        let created = try await makeFolders(layout)

        // Written first, so a failure below leaves removal knowing about them.
        let previous = reading.probe?.record.flatMap {
            try? JSONDecoder().decode(HostHelperInstallRecord.self, from: $0)
        }
        let record = (previous ?? HostHelperInstallRecord(files: [], folders: []))
            .merged(files: plan.outsideFiles, folders: created)
        try await write(try Self.encoded(record), to: layout.record, in: layout.directory, step: "Writing the install record")

        if plan.replacesHelper {
            try await placeHelper(bundle, layout: layout)
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
            // With no record, only the two files that are certainly Heeler's.
            ?? HostHelperInstallRecord(files: [layout.unit, layout.unitWantsLink], folders: [])

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

    private func makeFolders(_ layout: HostHelperLayout) async throws -> [String] {
        let script = HostHelperScript(
            .makeFolders(layout.folderChain, privateFolder: layout.directory), nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        guard result.exitStatus == 0 else {
            throw HostHelperError.stepFailed(step: "Creating the folders", detail: Self.detail(of: result))
        }
        do {
            let helperFolder = layout.directory
            return try HostHelperProbe.framedLines(stdout: result.stdout, nonce: script.nonce)
                .filter { $0.hasPrefix("created ") }
                .map { String($0.dropFirst("created ".count)) }
                // The Helper directory goes as a whole, at the end of a removal.
                .filter { $0 != helperFolder }
        } catch {
            throw HostHelperError.unreadableHost
        }
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
            throw HostHelperError.stepFailed(step: step, detail: "\(error)")
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

    private static func deepestFirst(_ first: String, _ second: String) -> Bool {
        let depth = { (path: String) in path.split(separator: "/").count }
        return depth(first) == depth(second) ? first < second : depth(first) > depth(second)
    }
}
