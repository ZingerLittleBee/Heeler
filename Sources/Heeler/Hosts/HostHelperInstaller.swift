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
    /// Names launchd's domain on a Mac.
    let uid: String

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
        uid = reading.probe?.uid ?? ""
        if layout.manager == .launchd, uid.isEmpty { throw HostHelperError.unreadableHost }
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
    var outsideFiles: [String] { layout.serviceFiles + extensionFiles }

    /// Every folder the install needs, parents first.
    var folderChain: [String] { layout.folderChain(reaching: extensionFolders) }

    /// Every file the install leaves on the Host.
    var files: [String] {
        let log = layout.manager == .launchd ? [layout.log] : []
        return (helperFiles.map { "\(layout.app)/\($0)" } + [layout.record] + log + outsideFiles).sorted()
    }

    var unitText: String {
        HostHelperUnit.text(nodePath: nodePath, mainPath: layout.main)
    }

    func launchAgentPropertyList() throws -> Data {
        try HostHelperLaunchAgent.propertyList(nodePath: nodePath, mainPath: layout.main, logPath: layout.log)
    }
}

/// Installs, reads and removes the Host Helper on a Linux or macOS Host (ADR
/// 0033). Every step is one script or one SFTP write through `HostHelperHost`.
struct HostHelperInstaller: Sendable {
    let host: any HostHelperHost
    var nonce: @Sendable () -> String = { UUID().uuidString }
    /// Holds the script a read runs to find the extension folders.
    var bundle: @Sendable () throws -> HostHelperBundle = { try HostHelperBundle.load() }
    /// The wait between two reads of a LaunchAgent's health.
    var healthGap: @Sendable () async throws -> Void = { try await Task.sleep(for: HostHelperLaunchAgent.healthGap) }

    /// What Host detail and the install sheet show: the Helper's health as far
    /// as this Host can tell, which on a Mac takes reads over ten seconds apart.
    func check() async throws -> HostHelperReading {
        try await confirmingHealth(of: try await readLoadingAgent())
    }

    /// One read, after loading a LaunchAgent that a restart of the Mac left out.
    /// A failure to load reads back as what it is, and nothing here asks twice.
    func readLoadingAgent() async throws -> HostHelperReading {
        let reading = try await read()
        guard reading.agentNeedsLoading, let probe = reading.probe, let layout = reading.layout else { return reading }
        _ = try? await run(.launchctl(["bootstrap", HostHelperLaunchAgent.domain(uid: probe.uid), layout.launchAgent]))
        return try await read()
    }

    /// Two reads over ten seconds apart, both `running` with one pid, call a
    /// LaunchAgent running (ADR 0033). A first read caught between two runs says
    /// nothing against the two after it, so a run that has only just begun gets
    /// one more. Anything that dies at start never gets that pair.
    private func confirmingHealth(of reading: HostHelperReading) async throws -> HostHelperReading {
        guard reading.awaitsSecondHealthRead, var probe = reading.probe, var health = probe.health else {
            return reading
        }
        var staysRunning = false
        for _ in 0..<2 {
            try await healthGap()
            let later = try await readLaunchdHealth(uid: probe.uid)
            staysRunning = health.isSameRun(as: later)
            health = later
            if staysRunning || later.activeState != "running" { break }
        }
        if health.launchd != nil { health.launchd?.staysRunning = staysRunning }
        probe.health = health
        return HostHelperReading(probe: probe, bundled: reading.bundled)
    }

    private func readLaunchdHealth(uid: String) async throws -> HostHelperHealth {
        let script = HostHelperScript(.launchctl(["print", HostHelperLaunchAgent.service(uid: uid)]), nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        guard let lines = try? HostHelperProbe.framedLines(stdout: result.stdout, nonce: script.nonce) else {
            throw HostHelperError.unreadableHost
        }
        return HostHelperHealth(launchctlPrint: lines.joined(separator: "\n"), exitStatus: result.exitStatus)
    }

    /// One read that changes nothing on the Host.
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
        var record = (previous ?? HostHelperInstallRecord(files: [], folders: []))
            // The Helper directory goes as a whole, at the end of a removal.
            .merged(files: plan.outsideFiles, folders: created.filter { $0 != layout.directory })
        if layout.manager == .launchd { record.launchAgentLabel = HostHelperLaunchAgent.label }
        do {
            try await write(
                try Self.encoded(record), to: layout.record, in: layout.directory, step: "Writing the install record")
        } catch {
            await takeBack(created)
            throw error
        }

        if plan.replacesHelper {
            try await placeHelper(bundle, plan: plan, over: reading)
        }
        for file in plan.extensionFiles {
            try await write(extensionText, to: file, in: nil, step: "Placing the Pi and Oh My Pi extensions")
        }
        switch layout.manager {
        case .systemd:
            try await write(Data(plan.unitText.utf8), to: layout.unit, in: nil, step: "Writing the service unit")
            try await startService()
        case .launchd:
            try await startLaunchAgent(plan)
        }

        let after = try await read()
        if plan.replacesHelper, after.probe.map({ bundle.manifest.matches($0.hashes) }) != true {
            throw HostHelperError.verificationFailed
        }
        return after
    }

    /// Stops the service, deletes the recorded files and then the created folders
    /// that are now empty, undoes the harness edits that go with the Helper, and
    /// finally deletes the Helper directory with its registrations and seen marks.
    /// Linger stays as it is.
    func remove(
        over reading: HostHelperReading, undoingEdits: @Sendable () async throws -> Void = {}
    ) async throws {
        guard reading.unsupportedPlatform == nil, let probe = reading.probe, let layout = reading.layout else {
            throw HostHelperError.unsupportedPlatform
        }
        let record = probe.record.flatMap { try? JSONDecoder().decode(HostHelperInstallRecord.self, from: $0) }
            // With no record, only the files that are certainly Heeler's.
            ?? HostHelperInstallRecord(
                files: layout.serviceFiles
                    + (probe.extensionFolders ?? []).map { "\($0.path)/\(HostHelperScript.extensionFileName)" },
                folders: [])

        switch layout.manager {
        case .systemd:
            // No user manager means nothing runs, and nothing can be asked to stop.
            if let health = probe.health, health.isLoaded {
                try await systemctl(["disable", "--now", HostHelperScript.unitName], step: "Stopping the service")
            }
            try await check(.removeFiles(record.safeFiles), step: "Deleting the files")
            if probe.health != nil {
                _ = try await run(.systemctl(["daemon-reload"]))
                _ = try await run(.systemctl(["reset-failed", HostHelperScript.unitName]))
            }
        case .launchd:
            guard !probe.uid.isEmpty else { throw HostHelperError.unreadableHost }
            let label = record.launchAgentLabel ?? HostHelperLaunchAgent.label
            try await checkBootOut(
                .bootOutAndRemove(
                    service: "\(HostHelperLaunchAgent.domain(uid: probe.uid))/\(label)",
                    propertyList: layout.launchAgent))
            try await check(.removeFiles(record.safeFiles), step: "Deleting the files")
        }
        let folders = record.safeFolders.sorted(by: Self.deepestFirst)
        try await check(
            .removeEmptyFolders(folders.filter { !layout.holdsDirectory($0) }), step: "Deleting the folders")
        try await undoingEdits()
        try await check(.removeTree(layout.directory), step: "Deleting the Host Helper directory")
        // Those above the Helper directory only empty once it has gone.
        try await check(
            .removeEmptyFolders(folders.filter { layout.holdsDirectory($0) }), step: "Deleting the folders")
    }

    /// Asks once and never waits for a password: a Host that wants an
    /// administrator refuses here, and the user reads why.
    func turnOnLinger(over reading: HostHelperReading) async throws {
        guard let probe = reading.probe, probe.manager == .systemd else { throw HostHelperError.unsupportedPlatform }
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

    /// Uploads into a staging directory, checks the manifest there, stops what is
    /// running and renames into place, so a Host never runs a half-written Helper.
    private func placeHelper(
        _ bundle: HostHelperBundle, plan: HostHelperInstallPlan, over reading: HostHelperReading
    ) async throws {
        let layout = plan.layout
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
            try await stopRunningCopy(plan, over: reading)
        } catch {
            _ = try? await run(.removeTree(staging))
            throw error
        }
        try await check(.promote(staging: staging, app: layout.app), step: "Putting the Host Helper in place")
    }

    /// A process goes on running the code it loaded, and the next read would call
    /// the new files on disk its version. Stopped before they land, whatever cuts
    /// this install short leaves a state with a way out: launchd holding no agent
    /// loads the new code at the next read, and a stopped unit offers Repair.
    private func stopRunningCopy(_ plan: HostHelperInstallPlan, over reading: HostHelperReading) async throws {
        guard reading.probe?.health?.isLoaded == true else { return }
        switch plan.layout.manager {
        case .systemd:
            try await systemctl(["stop", HostHelperScript.unitName], step: "Stopping the service")
        case .launchd:
            try await checkBootOut(.launchctl(["bootout", HostHelperLaunchAgent.service(uid: plan.uid)]))
        }
    }

    private func startService() async throws {
        try await systemctl(["daemon-reload"], step: "Reloading systemd")
        // A unit that failed for good refuses to start until this clears it.
        _ = try await run(.systemctl(["reset-failed", HostHelperScript.unitName]))
        try await systemctl(["enable", HostHelperScript.unitName], step: "Enabling the service")
        try await systemctl(["restart", HostHelperScript.unitName], step: "Starting the service")
    }

    /// The property list with the Node.js the Host has now, and an empty log
    /// that is private from the start and stays so as launchd appends to it.
    /// `bootout` then `bootstrap`, and never `kickstart`, which blocked for minutes
    /// in the VM when the agent could not run (ADR 0033). The `bootout` has nothing
    /// to stop on a first install, and whatever else keeps a copy loaded shows in
    /// the `bootstrap`'s answer.
    private func startLaunchAgent(_ plan: HostHelperInstallPlan) async throws {
        let layout = plan.layout
        try await write(Data(), to: layout.log, in: layout.directory, step: "Creating the log")
        let list: Data
        do {
            list = try plan.launchAgentPropertyList()
        } catch {
            throw HostHelperError.stepFailed(step: "Writing the property list", detail: "\(error)")
        }
        try await write(list, to: layout.launchAgent, in: nil, step: "Writing the property list")
        _ = try await run(.launchctl(["bootout", HostHelperLaunchAgent.service(uid: plan.uid)]))
        let result = try await run(
            .launchctl(["bootstrap", HostHelperLaunchAgent.domain(uid: plan.uid), layout.launchAgent]))
        guard result.exitStatus == 0 else {
            var detail = Self.detail(of: result)
            if result.exitStatus == Self.bootstrapRefused {
                detail += " launchd answers this for more than one cause, such as another copy already loaded."
            }
            throw HostHelperError.stepFailed(step: "Starting the service", detail: detail)
        }
    }

    /// A LaunchAgent already gone is what this asked for. Other answers stop before
    /// anything is replaced or deleted, since launchd would go on restarting an
    /// agent whose files have gone.
    private func checkBootOut(_ step: HostHelperScript.Step) async throws {
        let result = try await run(step)
        guard HostHelperLaunchAgent.bootoutDone.contains(result.exitStatus) else {
            throw HostHelperError.stepFailed(step: "Stopping the service", detail: Self.detail(of: result))
        }
    }

    /// `launchctl bootstrap`'s "Input/output error", which has several causes.
    private static let bootstrapRefused: Int32 = 5

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
