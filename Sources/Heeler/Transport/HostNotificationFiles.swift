import Foundation

/// Notification and Usage file access on a Host. `Transport` refines this and
/// stays rooted at the Heeler plugin's directories on Herdr TUI, which is what
/// the member documentation below describes.
protocol HostNotificationFiles: Sendable {
    /// Reads the Notification Registration file (v1, `plugin/README.md`)
    /// from the Heeler plugin's config dir on this Host; nil when no
    /// device has registered yet. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin is
    /// absent, so the ceremony can tell "install the plugin" apart from a
    /// broken read (#72).
    func readNotificationRegistration() async throws -> Data?

    /// Atomically replaces the Notification Registration file with
    /// `contents` (temp file + rename per the v1 contract), creating it when
    /// absent. Same plugin gate as the read.
    func replaceNotificationRegistration(_ contents: Data) async throws

    /// Reads the plugin's `notify.json` config from this Host's Heeler
    /// plugin config dir (the registration file's sibling; `plugin/README.md`);
    /// nil when the plugin has no config file yet. Same plugin gate as the
    /// registration read. Carries the custom Push Relay base URL (#76).
    func readNotificationConfig() async throws -> Data?

    /// Atomically replaces the plugin's `notify.json` config with `contents`
    /// (temp file + rename), creating it when absent. Same plugin gate as the
    /// registration write.
    func replaceNotificationConfig(_ contents: Data) async throws

    /// Runs the Usage query of the plugin installed at `pluginRoot`, which
    /// the caller resolved with `readHeelerPlugin()`. Reads aggregate usage,
    /// never credentials or Transcripts.
    func readAgentUsage(
        timeZone: String, claudeLimits: Bool, pluginRoot: String
    ) async throws -> AgentUsageReport

    /// Reads the Claude Code Account file (`usage-accounts.json`, ADR 0030)
    /// from this Host's Heeler plugin config dir; nil when no Account was
    /// ever added. Same plugin gate and POSIX-only reach as the registration
    /// read.
    func readUsageAccountFile() async throws -> Data?

    /// Atomically replaces the Account file with `contents` (temp file +
    /// rename, file 0600 in a 0700 directory), creating it when absent. Same
    /// plugin gate as the registration write.
    func replaceUsageAccountFile(_ contents: Data) async throws
}

extension HostNotificationFiles {
    /// Test doubles and alternative transports without a Host-side plugin
    /// can report its absence without emulating the plugin CLI.
    func readNotificationRegistration() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func readNotificationConfig() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func readAgentUsage(
        timeZone: String, claudeLimits: Bool, pluginRoot: String
    ) async throws -> AgentUsageReport {
        throw TransportError.hostFeatureUnavailable(feature: "Usage")
    }

    func readUsageAccountFile() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceUsageAccountFile(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }
}
