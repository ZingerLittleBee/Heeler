import Foundation
import Observation

/// One Host's on-demand Usage reading. Connections are borrowed from Console;
/// opening Usage never starts an independent SSH connection.
@MainActor
@Observable
final class AgentUsageStore {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case requirement(String)
        case unsupportedPlatform
        case runtimeMissing
        case updateRequired
        case available(AgentUsageReport)
        case failed(String)
    }

    private var snapshotState: State = .idle
    var state: State {
        guard !claudeLimitsEnabled, case .available(let report) = snapshotState else { return snapshotState }
        return .available(report.hidingClaudeLimits())
    }
    private(set) var isLoading = false
    var claudeLimitsEnabled: Bool {
        didSet {
            guard oldValue != claudeLimitsEnabled else { return }
            defaults.set(claudeLimitsEnabled, forKey: preferenceKey)
            request = nil
            isLoading = false
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferenceKey: String
    @ObservationIgnored private let read: @MainActor (String, Bool) async throws -> State
    @ObservationIgnored private var request: UUID?

    convenience init(hostID: Host.ID, transports: any NotificationTransportProvider,
        defaults: UserDefaults = .standard) {
        self.init(hostID: hostID, defaults: defaults) { timeZone, claudeLimits in
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await Self.read(over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
            }
        }
    }

    /// Console uses a weak capture here so its retained stores cannot keep it alive.
    init(hostID: Host.ID, defaults: UserDefaults = .standard,
        read: @escaping @MainActor (String, Bool) async throws -> State) {
        self.read = read
        self.defaults = defaults
        preferenceKey = "usage.claude-limits.\(hostID.uuidString)"
        claudeLimitsEnabled = defaults.bool(forKey: preferenceKey)
    }

    func refresh(timeZone: String = TimeZone.current.identifier) async {
        let claudeLimits = claudeLimitsEnabled
        guard !Task.isCancelled else { return }
        let id = UUID()
        request = id
        isLoading = true
        if state == .idle { snapshotState = .loading }
        defer {
            if request == id {
                isLoading = false
                request = nil
            }
        }
        while request == id && !Task.isCancelled {
            let next: State
            do {
                next = try await read(timeZone, claudeLimits)
            } catch AgentUsageError.unsupportedVersion {
                next = .updateRequired
            } catch TransportError.hostFeatureUnavailable {
                next = .unsupportedPlatform
            } catch {
                next = .failed("Could not read Usage. Check the Host connection and try again.")
            }
            guard request == id else { return }
            guard !Task.isCancelled else {
                if state == .loading { snapshotState = .idle }
                return
            }
            snapshotState = next
            guard case .available(let report) = next, report.refreshing == true else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    func invalidate() {
        request = nil
        isLoading = false
        snapshotState = .idle
    }

    nonisolated static func read(
        over transport: any Transport, timeZone: String, claudeLimits: Bool
    ) async throws -> State {
        guard let plugin = try await transport.readHeelerPlugin() else {
            return .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.")
        }
        guard let version = plugin.parsedVersion else {
            return .requirement("Could not verify the plugin version. Usage needs plugin 0.7.0 or newer.")
        }
        guard HeelerPluginFeature.usage.isSupported(by: version) else {
            return .requirement(HeelerPluginFeature.usage.requirementNote(installed: version))
        }
        guard plugin.isEnabled else {
            return .requirement("Enable the Heeler plugin on this Host to read Usage.")
        }
        let report = try await transport.readAgentUsage(timeZone: timeZone, claudeLimits: claudeLimits)
        return report.runtime == "missing" ? .runtimeMissing : .available(report)
    }
}
