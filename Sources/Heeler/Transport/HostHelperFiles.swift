import Foundation

/// Notification and Usage files on a herdr-core Host, rooted at the Host Helper's
/// directory and never at the plugin's configuration directory (ADR 0033). Each
/// file call finds the directory afresh, in one small exec, and a Usage read runs
/// the Helper's own query in one bounded exec.
struct HostHelperFiles: HostNotificationFiles {
    let host: any HostHelperHost
    /// The Host's core session, as the user wrote it. Usage is read per session.
    var session = ""
    var amuxEndpoint: AmuxCoreEndpoint? = nil
    var nonce: @Sendable () -> String = { UUID().uuidString }

    /// The Helper's report for this session. Throws `AgentUsageHostHelperNeed`
    /// when no Helper here can answer.
    func readUsage(timeZone: String, claudeLimits: Bool) async throws -> AgentUsageReport {
        guard amuxEndpoint == nil else {
            throw TransportError.hostFeatureUnavailable(feature: String(localized: "Usage through the amux native helper"))
        }
        guard AgentUsageProbe.isQueryableTimeZone(timeZone) else {
            throw TransportError.malformedResponse(String(localized: "The Usage query arguments are invalid."))
        }
        let script = HostHelperScript(
            .usageQuery(
                timeZone: timeZone, claudeLimits: claudeLimits,
                session: HerdrCoreSessionName.normalized(session)),
            nonce: nonce())
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
    }

    func readNotificationConfig() async throws -> Data? {
        try await read(HeelerSSHTransport.notificationConfigFileName)
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await replace(HeelerSSHTransport.notificationConfigFileName, contents)
    }

    func readUsageAccountFile() async throws -> Data? {
        guard amuxEndpoint == nil else {
            throw TransportError.hostFeatureUnavailable(feature: String(localized: "Usage Accounts through the amux native helper"))
        }
        return try await read(UsageAccountFile.fileName)
    }

    func replaceUsageAccountFile(_ contents: Data) async throws {
        guard amuxEndpoint == nil else {
            throw TransportError.hostFeatureUnavailable(feature: String(localized: "Usage Accounts through the amux native helper"))
        }
        try await replace(UsageAccountFile.fileName, contents)
    }

    /// One read of the Helper, without the Node.js run that finds the extension
    /// folders: only an install's list needs those. This is how notifications and
    /// banners come to know a Host, so on a Mac it also loads an agent a restart
    /// left out. It takes no second health read: a user waiting on a switch gets
    /// what launchd says now, and Host detail is where health is settled.
    func readHostHelper() async throws -> HostHelperReading? {
        if let amuxEndpoint {
            return try await HostHelperReading(native: AmuxNativeHelperReading.read(endpoint: amuxEndpoint, over: host, nonce: nonce))
        }
        return try await HostHelperInstaller(
            host: host, nonce: nonce, bundle: { throw HostHelperBundle.LoadError.missing }
        ).readLoadingAgent()
    }

    func replaceSeenMarks(_ contents: Data, keyID: String) async throws {
        try await replace(HerdrCoreSeenMarkFile.fileName(keyID: keyID), contents)
    }

    func removeSeenMarks(keyID: String) async throws {
        let path = try await directory() + "/" + HerdrCoreSeenMarkFile.fileName(keyID: keyID)
        let result = try await host.runHostHelperScript(HostHelperScript(.removeFiles([path]), nonce: nonce()))
        guard result.exitStatus == 0 else {
            throw NotificationRegistrationError.writeFailed(detail: String(decoding: result.stderr, as: UTF8.self))
        }
    }

    private func read(_ name: String) async throws -> Data? {
        let directory = try await directory()
        return try await host.readHostHelperFile(at: directory + "/" + name, privateDirectory: directory)
    }

    private func replace(_ name: String, _ contents: Data) async throws {
        let directory = try await directory()
        try await host.replaceHostHelperFile(
            contents, at: directory + "/" + name, privateDirectory: directory)
    }

    private func directory() async throws -> String {
        if let amuxEndpoint {
            let reading = try await AmuxNativeHelperReading.read(endpoint: amuxEndpoint, over: host, nonce: nonce)
            guard reading.state == .ready else {
                throw TransportError.malformedResponse(reading.detail)
            }
            return amuxEndpoint.helper.directory
        }
        return try await layout().directory
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
