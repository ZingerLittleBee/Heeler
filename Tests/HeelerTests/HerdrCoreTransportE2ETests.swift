import CryptoKit
import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite("herdr-core real SSH", .enabled(if: CoreSSHFixture.isConfigured,
    "requires scripts/fixtures/herdr-core-ssh.py"), .serialized)
struct HerdrCoreTransportE2ETests {
    @Test("core inventory separates desktop agents and ordinary shell terminals")
    func inventory() async throws {
        try await CoreSSHFixture.with { fixture in
            let agent = try await fixture.startProgram()
            let shell = try await fixture.command(["run", "--bg", "--cwd", fixture.homePath, "/bin/sh"])
            let shellID = try #require(shell["address"]?.stringValue)
            let transport = try await fixture.connect()
            do {
                #expect(try await transport.ping().protocolVersion == 1)
                let snapshot = try await transport.sessionSnapshot()
                #expect(snapshot.agents.map(\.paneID) == [agent])
                #expect(snapshot.agents.first?.agent == "claude")
                #expect(snapshot.agents.first?.agentStatus == .idle)
                #expect(Set(snapshot.panes.map(\.paneID)) == [agent, shellID])
                #expect(snapshot.workspaces.count == 1)
                #expect(snapshot.panes.allSatisfy { $0.cwd == fixture.homePath })
                try await transport.close()
            } catch { try? await transport.close(); throw error }
        }
    }

    @Test("prompt and named keys reach the core program and screen reads return its response")
    func promptKeysAndRead() async throws {
        try await CoreSSHFixture.with { fixture in
            let agent = try await fixture.startProgram()
            let transport = try await fixture.connect()
            do {
                _ = try await transport.promptAgent(AgentPromptParams(target: agent, text: "phone-message"))
                try await fixture.waitForRead(transport, agent: agent, containing: "INPUT:phone-message")
                try await transport.sendAgentKeys(AgentSendKeysParams(keys: ["x", "Enter"], target: agent))
                try await fixture.waitForRead(transport, agent: agent, containing: "INPUT:x")
                try await transport.close()
            } catch { try? await transport.close(); throw error }
        }
    }

    @Test("subscriptions report membership and status, and reconnect fetches current inventory")
    func eventsAndReconnect() async throws {
        try await CoreSSHFixture.with { fixture in
            let transport = try await fixture.connect()
            let stream = try await transport.subscribeToEvents([
                .global(.paneCreated), .global(.paneClosed), .global(.paneAgentDetected),
            ])
            let observed = CoreSSHObservations()
            let reader = Task {
                do { for try await event in stream.events { await observed.append(event) } }
                catch { await observed.fail(String(describing: error)) }
            }
            do {
                let agent = try await fixture.startProgram()
                try await eventually { await observed.has(.paneCreated, target: agent) }
                _ = try await fixture.command(["send", agent, "work"])
                try await eventually { await observed.hasStatus(target: agent, status: "working") }
                await stream.end()
                reader.cancel()
                try await transport.close()
                _ = try await fixture.command(["send", agent, "idle"])
                let replacement = try await fixture.connect()
                do {
                    let snapshot = try await replacement.sessionSnapshot()
                    #expect(snapshot.agents.first?.paneID == agent)
                    #expect(snapshot.agents.first?.agentStatus == .idle)
                    let replacementEvents = try await replacement.subscribeToEvents([.global(.paneClosed)])
                    let closed = Task {
                        do { for try await event in replacementEvents.events { await observed.append(event) } }
                        catch { await observed.fail(String(describing: error)) }
                    }
                    try await replacement.closePane(PaneTarget(paneID: agent))
                    try await eventually { await observed.hasEnded(target: agent) }
                    #expect(try await replacement.sessionSnapshot().agents.isEmpty)
                    await replacementEvents.end()
                    closed.cancel()
                    try await replacement.close()
                } catch { try? await replacement.close(); throw error }
            } catch {
                await stream.end(); reader.cancel(); try? await transport.close(); throw error
            }
        }
    }

    @Test("attach carries raw input and resize, and detach leaves the program running")
    func attachResizeAndDetach() async throws {
        try await CoreSSHFixture.with { fixture in
            let agent = try await fixture.startProgram()
            let transport = try await fixture.connect()
            let session = try await transport.attachTerminal(TerminalAttachRequest(target: agent, cols: 80, rows: 24))
            let observed = CoreSSHObservations()
            let reader = Task {
                do { for try await bytes in session.output { await observed.append(bytes) } }
                catch { await observed.fail(String(describing: error)) }
            }
            do {
                session.send(Data("raw-\u{1B}[A\n".utf8))
                try await eventually { await observed.contains("HEX:7261772d1b5b410a") }
                session.resize(cols: 109, rows: 47)
                // SSH window-change completion precedes hc's polling loop;
                // observe the remote resize before querying program geometry.
                try await eventually {
                    let terminal = try await fixture.command(["get", agent])
                    return terminal["cols"] == .number(109) && terminal["rows"] == .number(47)
                }
                session.send(Data("size\n".utf8))
                try await eventually { await observed.contains("SIZE:109x47") }
                await session.end()
                reader.cancel()
                #expect(try await transport.sessionSnapshot().agents.first?.paneID == agent)
                let replacement = try await transport.attachTerminal(TerminalAttachRequest(target: agent, cols: 80, rows: 24))
                await replacement.end()
                try await transport.close()
            } catch {
                await session.end(); reader.cancel(); try? await transport.close(); throw error
            }
        }
    }

    @Test("phone launches create a shell workspace, another shell, and an independent agent")
    func launchFromPhone() async throws {
        try await CoreSSHFixture.with { fixture in
            try await fixture.prepareProgram()
            // A same-named core template must not intercept the selected executable.
            let template = fixture.homePath + "/../config/herdr-core/templates/claude.md"
            let templateBody = "---\ncommand: python3 -u " + GitProbe.singleQuoted(fixture.program)
                + "\n---\nThis template must not receive the native arguments.\n"
            let installed = try await fixture.connection.execute(
                "mkdir -p " + GitProbe.singleQuoted(fixture.homePath + "/../config/herdr-core/templates")
                    + "; printf %s " + GitProbe.singleQuoted(templateBody) + " > " + GitProbe.singleQuoted(template),
                timeout: .seconds(10))
            try #require(installed.exitStatus == 0)
            let transport = try await fixture.connect()
            do {
                let workspaceShell = try await transport.createShellWorkspace(
                    NewWorkspaceSpec(directory: fixture.homePath), tabLabel: nil)
                let snapshot = try await transport.sessionSnapshot()
                let workspaceID = try #require(snapshot.workspaces.first?.workspaceID)
                let nextShell = try await transport.createShellTerminal(
                    ShellTerminalCreationRequest(workspaceID: workspaceID, cwd: fixture.homePath))
                let agent = try await transport.startAgent(AgentLaunchRequest(
                    kind: "claude", name: "phone-started", arguments: [fixture.program],
                    workspaceID: workspaceID, cwd: fixture.homePath))
                try await eventually { try await fixture.command(["get", agent.paneID])["reported"] == .bool(true) }
                let record = try await fixture.command(["get", agent.paneID])
                #expect(record["parent"] == .null)
                #expect(record["cwd"] == .string(fixture.homePath))
                #expect(record["template"] == .null)
                #expect(record["argv"] == .array([
                    .string(fixture.homePath + "/.local/bin/claude"), .string(fixture.program),
                ]))
                let refreshed = try await transport.sessionSnapshot()
                #expect(refreshed.agents.map(\.paneID) == [agent.paneID])
                #expect(Set(refreshed.panes.map(\.paneID)) == [workspaceShell.paneID, nextShell.paneID, agent.paneID])
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: "launched-from-phone"))
                try await fixture.waitForRead(transport, agent: agent.paneID, containing: "INPUT:launched-from-phone")
                try await transport.close()
            } catch { try? await transport.close(); throw error }
        }
    }

    @Test("a rejected core session never calls the legacy backend")
    func noLegacyFallback() async throws {
        try await CoreSSHFixture.with { fixture in
            var settings = try fixture.settings()
            settings.coreSessionName = "../invalid-session"
            await #expect(throws: (any Error).self) {
                let transport = try await HeelerSSHTransport.connect(settings: settings)
                do { _ = try await transport.ping(); try await transport.close() }
                catch { try? await transport.close(); throw error }
            }
        }
    }
}

private enum CoreSSHFailure: Error { case timeout, fixture(String) }

private func eventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CoreSSHFailure.timeout
}

private actor CoreSSHObservations {
    var events: [HerdrEvent] = []
    var output = Data()
    var error: String?
    func append(_ event: HerdrEvent) { events.append(event) }
    func append(_ data: Data) { output.append(data) }
    func fail(_ message: String) { error = message }
    func contains(_ text: String) -> Bool { String(decoding: output, as: UTF8.self).contains(text) }
    func has(_ kind: GlobalEventKind, target: String) -> Bool {
        events.contains { $0.kind == kind.kind && $0.data["pane_id"] == .string(target) }
    }
    func hasEnded(target: String) -> Bool { has(.paneExited, target: target) || has(.paneClosed, target: target) }
    func hasStatus(target: String, status: String) -> Bool {
        events.contains { $0.kind == PaneEventKind.agentStatusChanged.kind
            && $0.data["pane_id"] == .string(target) && $0.data["agent_status"] == .string(status) }
    }
}

private struct CoreSSHFixture: Sendable {
    struct Configuration: Decodable, Sendable {
        let coreFixture: Bool
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let homePath: String
    }
    static var isConfigured: Bool {
        guard let raw = ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: raw),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["coreFixture"] as? Bool == true
    }
    let configuration: Configuration
    let connection: SSHConnection
    let session = "h" + UUID().uuidString.prefix(8).lowercased()
    var homePath: String { configuration.homePath }
    var launcher: String { homePath + "/.local/bin/hc" }
    var program: String { homePath + "/" + session + ".py" }

    static func with(_ body: (CoreSSHFixture) async throws -> Void) async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"])
        let data = try #require(Data(base64Encoded: raw))
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        let connection = try await SSHConnection.connect(to: SSHEndpoint(host: config.host, port: config.port), timeout: RealSSHFixture.setupTimeout)
        let key = DeviceKey(privateKey: try RealSSHFixture.deviceKey(seed: config.deviceKeySeed))
        try await connection.authenticate(username: config.username, publicKey: key.publicKeyBlob,
            signer: { try key.privateKey.signature(for: $0) }, timeout: RealSSHFixture.setupTimeout)
        let fixture = CoreSSHFixture(configuration: config, connection: connection)
        do {
            try await body(fixture)
            try await fixture.cleanup()
            try await connection.close(timeout: .seconds(3))
        } catch {
            try? await fixture.cleanup()
            try? await connection.close(timeout: .seconds(3))
            throw error
        }
    }

    func settings() throws -> SSHTransportSettings {
        var result = SSHTransportSettings(host: configuration.host, port: Int(configuration.port),
            username: configuration.username, credentials: .ed25519(try RealSSHFixture.deviceKey(seed: configuration.deviceKeySeed)),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true }, socket: .defaultSession)
        result.backend = .herdrCore
        result.coreSessionName = session
        return result
    }
    func connect() async throws -> HeelerSSHTransport { try await HeelerSSHTransport.connect(settings: settings()) }
    func command(_ words: [String]) async throws -> JSONValue {
        let command = "HC_SESSION=" + GitProbe.singleQuoted(session) + " "
            + ([launcher, "--json"] + words).map(GitProbe.singleQuoted).joined(separator: " ")
        let response = try await connection.execute(command, timeout: .seconds(15))
        guard response.exitStatus == 0 else { throw CoreSSHFailure.fixture(String(decoding: response.stderr, as: UTF8.self)) }
        return try JSONDecoder().decode(JSONValue.self, from: response.stdout)
    }
    func prepareProgram() async throws {
        let source = #"""
        import os, sys, tty
        tty.setraw(0)
        def status(word):
            print('\033]7501;state='+word+':app=claude-code\007', flush=True)
        status('idle')
        pending = bytearray()
        while True:
            b = os.read(0, 1)
            if not b: break
            pending.extend(b)
            if b in (b'\r', b'\n'):
                print('HEX:'+pending.hex(), flush=True)
                text = pending.rstrip(b'\r\n').decode('utf-8', errors='replace')
                print('INPUT:'+text, flush=True)
                size = os.get_terminal_size(0)
                print('SIZE:'+str(size.columns)+'x'+str(size.lines), flush=True)
                status('working' if text == 'work' else 'idle')
                pending.clear()
        """#
        let sftp = try await connection.openSFTP(timeout: .seconds(10))
        let file = try await sftp.openFileForWriting(at: program, permissions: 0o600, timeout: .seconds(10))
        try await file.write(Data(source.utf8), timeout: .seconds(10))
        try await file.close(timeout: .seconds(10))
        try await sftp.close(timeout: .seconds(10))
        // An inert executable with the same launch name, never a real paid Agent.
        let wrapper = homePath + "/.local/bin/claude"
        let installed = try await connection.execute(
            "printf '%s\\n' '#!/bin/sh' 'exec python3 -u \"$@\"' > " + GitProbe.singleQuoted(wrapper)
                + "; chmod 700 " + GitProbe.singleQuoted(wrapper), timeout: .seconds(10))
        try #require(installed.exitStatus == 0)
    }
    func startProgram() async throws -> String {
        try await prepareProgram()
        let started = try await command(["run", "--bg", "--cwd", homePath, "python3", "-u", program])
        let address = try #require(started["address"]?.stringValue)
        try await eventually { try await command(["get", address])["reported"] == .bool(true) }
        return address
    }
    func waitForRead(_ transport: HeelerSSHTransport, agent: String, containing text: String) async throws {
        try await eventually {
            try await transport.readAgent(AgentReadParams(source: .visible, target: agent)).text.contains(text)
        }
    }
    func cleanup() async throws {
        _ = try await command(["server", "stop"])
        let cleaned = try await connection.execute("rm -f " + GitProbe.singleQuoted(program)
            + " " + GitProbe.singleQuoted(homePath + "/../config/herdr-core/templates/claude.md")
            + "; test ! -e " + GitProbe.singleQuoted(homePath + "/../legacy-called"), timeout: .seconds(10))
        #expect(cleaned.exitStatus == 0, "Core selection called the legacy herdr launcher")
    }
}
