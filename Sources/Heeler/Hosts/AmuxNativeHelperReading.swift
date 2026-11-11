import Foundation

/// Native helper negotiation is independent of Node's version/install model.
/// Readiness comes from the running follower's private IPC, not configuration.
struct AmuxNativeHelperReading: Sendable, Equatable {
    enum State: String, Decodable, Sendable { case stopped, disconnected, ready }
    let state: State
    let capabilities: Set<String>

    private struct Identity: Decodable {
        let kind: String
        let contract: Int
        let schemaVersion: Int
        let serverKind: String
        let coreID: String
        let generation: Int
        let session: String
        let socket: String
        let directory: String
        let coreExecutable: String
        let capabilities: [String]
    }

    private struct Health: Decodable {
        let kind: String
        let contract: Int
        let coreID: String
        let session: String
        let socket: String
        let state: State
        let sequence: UInt64?
    }

    static func read(endpoint: AmuxCoreEndpoint, over host: any HostHelperHost,
                     nonce: @Sendable () -> String) async throws -> Self {
        func query(status: Bool) async throws -> Data {
            let script = HostHelperScript(.amuxNative(endpoint, status: status), nonce: nonce())
            let result = try await host.runHostHelperScript(script)
            guard result.exitStatus == 0 else {
                throw TransportError.malformedResponse(String(localized: "The amux native helper could not be queried. Check Mobile settings in amux."))
            }
            let lines = try HostHelperProbe.framedLines(stdout: result.stdout, nonce: script.nonce)
            guard lines.count == 1 else { throw HostHelperError.unreadableHost }
            return Data(lines.joined().utf8)
        }
        func decode<Value: Decodable>(_ type: Value.Type, status: Bool) async throws -> Value {
            let data = try await query(status: status)
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw TransportError.malformedResponse(String(localized: "The amux native helper returned an unsupported identity or health response. Check Mobile settings in amux and pair again."))
            }
        }
        let identity = try await decode(Identity.self, status: false)
        let capabilities = Set(identity.capabilities)
        guard identity.kind == "amux-native", identity.contract == 1,
              identity.schemaVersion == 1, identity.serverKind == "core",
              identity.coreID == endpoint.core.id, identity.generation == endpoint.core.generation,
              identity.session == endpoint.session, identity.socket == endpoint.socketPath,
              identity.directory == endpoint.helper.directory, AmuxCoreEndpoint.isSafePath(identity.coreExecutable),
              AmuxCoreEndpoint.requiredCapabilities.isSubset(of: capabilities) else {
            throw TransportError.malformedResponse(String(localized: "The amux native helper identity or implemented capabilities do not match this pairing. Update amux and pair again."))
        }
        let health = try await decode(Health.self, status: true)
        guard health.kind == "amux-native", health.contract == 1,
              health.coreID == endpoint.core.id, health.session == endpoint.session, health.socket == endpoint.socketPath else {
            throw TransportError.malformedResponse(String(localized: "The amux native helper is following a different Core. Pair again from amux."))
        }
        guard health.state != .ready || health.sequence != nil else {
            throw TransportError.malformedResponse(String(localized: "The amux native helper has no verified subscription snapshot. Check Mobile settings in amux and pair again."))
        }
        return Self(state: health.state, capabilities: capabilities)
    }

    var detail: String {
        switch state {
        case .ready: String(localized: "The amux-managed native helper is connected to the paired Core. Manage it in amux; Heeler does not install or replace it.")
        case .stopped: String(localized: "The amux-managed native helper is stopped. Open Mobile settings in amux. Heeler does not start or install it.")
        case .disconnected: String(localized: "The amux-managed native helper is not connected to the paired Core. Check Mobile settings in amux.")
        }
    }
}
