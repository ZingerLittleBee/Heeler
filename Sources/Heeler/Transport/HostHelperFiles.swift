import Foundation

/// Notification and Usage files on a herdr-core or tmux Host, rooted at the Host
/// Helper's directory and never at the plugin's configuration directory (ADRs
/// 0033 and 0046). Each file call finds the directory afresh, in one small exec,
/// and a Usage read runs the Helper's own query in one bounded exec.
struct HostHelperFiles: HostNotificationFiles {
    enum Target: Sendable, Equatable {
        case coreSession(String)
        case tmuxSocket(String, TmuxPaths?)
    }

    let host: any HostHelperHost
    var target: Target = .coreSession("")
    var nonce: @Sendable () -> String = { UUID().uuidString }

    init(
        host: any HostHelperHost, session: String = "",
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.host = host
        target = .coreSession(session)
        self.nonce = nonce
    }

    init(
        host: any HostHelperHost, tmuxSocket: String, tmuxPaths: TmuxPaths? = nil,
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.host = host
        target = .tmuxSocket(tmuxSocket, tmuxPaths)
        self.nonce = nonce
    }

    /// The Helper's report for this target. Throws `AgentUsageHostHelperNeed`
    /// when no Helper here can answer.
    func readUsage(timeZone: String, claudeLimits: Bool) async throws -> AgentUsageReport {
        guard AgentUsageProbe.isQueryableTimeZone(timeZone) else {
            throw TransportError.malformedResponse(String(localized: "The Usage query arguments are invalid."))
        }
        let step: HostHelperScript.Step
        switch target {
        case .coreSession(let session):
            step = .usageQuery(
                timeZone: timeZone, claudeLimits: claudeLimits,
                session: HerdrCoreSessionName.normalized(session))
        case .tmuxSocket(let socket, let paths):
            let normalized = TmuxSocketName.normalized(socket)
            let storedPaths = paths.flatMap {
                $0.serves(socketName: normalized)
                    ? String(decoding: TmuxClaudeCodeHooks.storedPaths($0), as: UTF8.self)
                    : nil
            }
            step = .tmuxUsageQuery(
                timeZone: timeZone, claudeLimits: claudeLimits,
                socket: normalized, storedPaths: storedPaths)
        }
        let script = HostHelperScript(step, nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        return try AgentUsageProbe.parseHelper(stdout: result.stdout, nonce: script.nonce)
    }

    /// The query is the Helper's own, wherever a plugin would sit.
    func readAgentUsage(
        timeZone: String, claudeLimits: Bool, pluginRoot: String
    ) async throws -> AgentUsageReport {
        try await readUsage(timeZone: timeZone, claudeLimits: claudeLimits)
    }

    func readNotificationRegistration() async throws -> Data? {
        try await read(HeelerSSHTransport.notificationRegistrationFileName)
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        try await replace(HeelerSSHTransport.notificationRegistrationFileName, contents)
        if case .tmuxSocket(let socket, let paths?) = target {
            let normalized = TmuxSocketName.normalized(socket)
            if paths.serves(socketName: normalized),
                let file = try? NotificationRegistrationFile.decode(contents),
                file.devices.contains(where: { $0["session"] == .string("tmux/\(normalized)") })
            {
                let stored = String(decoding: TmuxClaudeCodeHooks.storedPaths(paths), as: UTF8.self)
                let script = HostHelperScript(
                    .refreshTmuxPaths(socket: normalized, storedPaths: stored), nonce: nonce())
                _ = try? await host.runHostHelperScript(script)
            }
        }
    }

    func readNotificationConfig() async throws -> Data? {
        try await read(HeelerSSHTransport.notificationConfigFileName)
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await replace(HeelerSSHTransport.notificationConfigFileName, contents)
    }

    func readUsageAccountFile() async throws -> Data? {
        try await read(UsageAccountFile.fileName)
    }

    func replaceUsageAccountFile(_ contents: Data) async throws {
        try await replace(UsageAccountFile.fileName, contents)
    }

    /// One read of the Helper, without the Node.js run that finds the extension
    /// folders: only an install's list needs those. This is how notifications and
    /// banners come to know a Host, so on a Mac it also loads an agent a restart
    /// left out. It takes no second health read: a user waiting on a switch gets
    /// what launchd says now, and Host detail is where health is settled.
    func readHostHelper() async throws -> HostHelperReading? {
        try await HostHelperInstaller(
            host: host, nonce: nonce, bundle: { throw HostHelperBundle.LoadError.missing }
        ).readLoadingAgent()
    }

    func replaceSeenMarks(_ contents: Data, keyID: String) async throws {
        try await replace(HerdrCoreSeenMarkFile.fileName(keyID: keyID), contents)
    }

    func removeSeenMarks(keyID: String) async throws {
        let path = try await layout().file(named: HerdrCoreSeenMarkFile.fileName(keyID: keyID))
        let result = try await host.runHostHelperScript(HostHelperScript(.removeFiles([path]), nonce: nonce()))
        guard result.exitStatus == 0 else {
            throw NotificationRegistrationError.writeFailed(detail: String(decoding: result.stderr, as: UTF8.self))
        }
    }

    private func read(_ name: String) async throws -> Data? {
        let layout = try await layout()
        return try await host.readHostHelperFile(at: layout.file(named: name), privateDirectory: layout.directory)
    }

    private func replace(_ name: String, _ contents: Data) async throws {
        let layout = try await layout()
        try await host.replaceHostHelperFile(
            contents, at: layout.file(named: name), privateDirectory: layout.directory)
    }

    private func layout() async throws -> HostHelperLayout {
        let script = HostHelperScript(.locate, nonce: nonce())
        let result = try await host.runHostHelperScript(script)
        do {
            let lines = try HostHelperProbe.framedLines(stdout: result.stdout, nonce: script.nonce)
            return HostHelperLayout(locations: try HostHelperProbe.parseLocations(lines))
        } catch {
            throw HostHelperError.unreadableHost
        }
    }
}

/// A core Host as Usage's Account changes see it: the Helper's Account file, and
/// the Host's own file services for checking and browsing directories.
struct HostHelperUsageHost: HostServices, HostNotificationFiles {
    let services: any HostServices
    let files: any HostNotificationFiles

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        try await services.fileStatus(atPath: path)
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        try await services.listFiles(request)
    }

    func hostHomeDirectory() async throws -> String {
        try await services.hostHomeDirectory()
    }

    func readUsageAccountFile() async throws -> Data? {
        try await files.readUsageAccountFile()
    }

    func replaceUsageAccountFile(_ contents: Data) async throws {
        try await files.replaceUsageAccountFile(contents)
    }
}
