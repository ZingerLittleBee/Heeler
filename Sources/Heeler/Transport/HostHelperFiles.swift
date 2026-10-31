import Foundation

/// Notification and Usage files on a herdr-core Host, rooted at the Host Helper's
/// directory and never at the plugin's configuration directory (ADR 0033). Each
/// call finds the directory afresh, in one small exec. The Usage query itself
/// stays unavailable until the Helper can answer it.
struct HostHelperFiles: HostNotificationFiles {
    let host: any HostHelperHost
    var nonce: @Sendable () -> String = { UUID().uuidString }

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
        try await read(UsageAccountFile.fileName)
    }

    func replaceUsageAccountFile(_ contents: Data) async throws {
        try await replace(UsageAccountFile.fileName, contents)
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
