import Foundation
import HeelerSSH
import Testing

@testable import Heeler

extension HeelerSSHTransportBehaviorE2ETests {
    @Test("Usage quotes its runtime and plugin paths through an endpoint exec")
    func usageQuotesPathsThroughEndpoint() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await UsageScratchPlugin.with(environment: environment) { plugin in
            try await plugin.writeNode("""
                [ "$1" = \(GitProbe.singleQuoted(plugin.root + "/src/usage-query.js")) ] || exit 3
                [ "$2" = '--tz' ] && [ "$3" = 'Asia/Kathmandu' ] || exit 4
                [ "$4" = '--claude-limits' ] || exit 5
                printf '%s' '{"version":1,"runtime":"missing"}'
                """)
            let transport = try await HeelerSSHTransport.connect(settings: plugin.settings)
            defer { Task { try? await transport.close() } }
            let report = try await transport.readAgentUsage(
                timeZone: "Asia/Kathmandu", claudeLimits: true, pluginRoot: plugin.root)
            #expect(report.runtime == "missing")
            #expect(try await transport.ping().version == "fake")
        }
    }

    @Test("Usage reports a missing or obsolete recorded runtime without a PATH fallback")
    func usageMissingRuntimeDoesNotFallBack() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await UsageScratchPlugin.with(environment: environment) { plugin in
            let transport = try await HeelerSSHTransport.connect(settings: plugin.settings)
            defer { Task { try? await transport.close() } }
            for node in [nil, "relative-node", plugin.directory + "/removed node"] as [String?] {
                try await plugin.setRuntimeNode(node)
                let report = try await transport.readAgentUsage(
                    timeZone: "UTC", claudeLimits: false, pluginRoot: plugin.root)
                #expect(report.runtime == "missing")
            }
            try await plugin.writeNode("exit 126")
            #expect(
                try await transport.readAgentUsage(
                    timeZone: "UTC", claudeLimits: false, pluginRoot: plugin.root).runtime == "missing")
        }
    }

    @Test("Usage rejects over-cap output and malformed responses on a real exec")
    func usageRequiresCompleteBoundedResponse() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await UsageScratchPlugin.with(environment: environment) { plugin in
            let transport = try await HeelerSSHTransport.connect(settings: plugin.settings)
            defer { Task { try? await transport.close() } }
            for body in [
                "printf '%s' '__HEELER_USAGE_BEGIN_other'; printf '%s' '{\"version\":1,\"runtime\":\"missing\"}'",
                "head -c 1048576 /dev/zero",
                "printf '%s' '{\"version\":1,\"runtime\":\"missing\"}'; exit 1",
            ] {
                try await plugin.writeNode(body)
                await #expect(throws: (any Error).self) {
                    try await transport.readAgentUsage(
                        timeZone: "UTC", claudeLimits: false, pluginRoot: plugin.root)
                }
            }
            #expect(try await transport.ping().version == "fake")
        }
    }

    @Test("Usage returns from SSH while its real worker keeps scanning")
    func usageWorkerOutlivesSSHQuery() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await UsageScratchPlugin.with(environment: environment) { plugin in
            let node = environment.homePath + "/.heeler-ci/usage-node"
            try await plugin.seedTranscripts(node: node, source: environment.homePath + "/.heeler-ci/usage-plugin")
            let transport = try await HeelerSSHTransport.connect(settings: plugin.settings)
            defer { Task { try? await transport.close() } }
            let started = ContinuousClock.now
            let first = try await transport.readAgentUsage(
                timeZone: "UTC", claudeLimits: false, pluginRoot: plugin.root)
            #expect(first.refreshing == true)
            #expect(started.duration(to: .now) < .seconds(5))
            let alive = try await plugin.runNode(node, script: "worker-alive.js")
            #expect(alive.trimmingCharacters(in: .whitespacesAndNewlines) == "alive")
            #expect(try await transport.ping().version == "fake")

            var report = first
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            while report.refreshing == true && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
                report = try await transport.readAgentUsage(
                    timeZone: "UTC", claudeLimits: false, pluginRoot: plugin.root)
            }
            #expect(report.refreshing == false)
            #expect(report.programs?.first?.tokenUsage.state == "ok")
            #expect(report.programs?.first?.tokenUsage.totals?.last30Days.tokens.total == 5)
        }
    }

    @Test("Usage times out without invalidating the Host connection")
    func usageTimeoutPreservesConnection() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await UsageScratchPlugin.with(environment: environment) { plugin in
            try await plugin.writeNode("sleep 30")
            let transport = try await HeelerSSHTransport.connect(settings: plugin.settings)
            defer { Task { try? await transport.close() } }
            let clock = ContinuousClock()
            let started = clock.now
            await #expect(throws: TransportError.hostFileTimedOut) {
                try await transport.readAgentUsage(
                    timeZone: "UTC", claudeLimits: false, pluginRoot: plugin.root)
            }
            #expect(started.duration(to: clock.now) < .seconds(12))
            #expect(try await transport.ping().version == "fake")
        }
    }
}

/// An isolated plugin environment. All executables and paths are scratch
/// files, so the acceptance lane never invokes an installed Agent program.
private struct UsageScratchPlugin {
    let connection: SSHConnection
    let directory: String
    let settings: SSHTransportSettings
    var root: String { directory + "/plugin's $literal" }
    private var nodePath: String { directory + "/node's runtime" }
    private static let timeout: Duration = .seconds(15)

    static func with(
        environment: HeelerSSHTransportBehaviorEnvironment,
        _ body: (UsageScratchPlugin) async throws -> Void
    ) async throws {
        let key = DeviceKey(privateKey: environment.deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: environment.host, port: environment.port),
            timeout: RealSSHFixture.setupTimeout)
        let directory = environment.homePath + "/usage $literal-" + UUID().uuidString
        let quoted = try #require(RemoteShellPath.quotedAbsolute(directory))
        do {
            try await connection.authenticate(
                username: environment.username, publicKey: key.publicKeyBlob,
                signer: { try key.privateKey.signature(for: $0) }, timeout: RealSSHFixture.setupTimeout)
            let created = try await connection.execute(
                "umask 077; mkdir \(quoted)", timeout: timeout)
            try #require(created.exitStatus == 0)
            var settings = environment.directSettings()
            let launcher = directory + "/herdr launcher"
            settings.herdrLauncher = try #require(
                HerdrLauncher(executablePath: launcher, socketPath: directory + "/endpoint $socket"))
            let fixture = UsageScratchPlugin(connection: connection, directory: directory, settings: settings)
            try await fixture.upload(
                path: launcher,
                text: """
                    #!/bin/sh
                    [ "$1 $2 $3" = 'plugin config-dir heeler' ] || exit 11
                    [ "$HERDR_SOCKET_PATH" = \(try #require(RemoteShellPath.quotedAbsolute(directory + "/endpoint $socket"))) ] || exit 12
                    printf '%s\\n' \(quoted)
                    """, permissions: 0o700)
            do {
                try await body(fixture)
            } catch {
                _ = try? await connection.execute("rm -rf \(quoted)", timeout: timeout)
                throw error
            }
            let removed = try await connection.execute("rm -rf \(quoted)", timeout: timeout)
            #expect(removed.exitStatus == 0)
            try await connection.close(timeout: .seconds(2))
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    func writeNode(_ body: String) async throws {
        try await upload(path: nodePath, text: "#!/bin/sh\n" + body + "\n", permissions: 0o700)
        try await setRuntimeNode(nodePath)
    }

    func setRuntimeNode(_ node: String?) async throws {
        let path = directory + "/runtime-node"
        if let node {
            try await upload(path: path, text: node + "\n", permissions: 0o600)
        } else {
            let quoted = try #require(RemoteShellPath.quotedAbsolute(path))
            let result = try await connection.execute("rm -f \(quoted)", timeout: Self.timeout)
            #expect(result.exitStatus == 0)
        }
    }

    func seedTranscripts(node: String, source: String) async throws {
        let copy = try await connection.execute(
            "cp -R " + GitProbe.singleQuoted(source) + " " + GitProbe.singleQuoted(root),
            timeout: Self.timeout)
        try #require(copy.exitStatus == 0)
        try await upload(path: directory + "/seed.js", text: """
            const fs = require('node:fs');
            const path = require('node:path');
            const root = process.argv[2];
            const home = path.join(root, 'home');
            const projects = path.join(home, '.claude', 'projects', '-fixture');
            fs.mkdirSync(projects, { recursive: true });
            const line = JSON.stringify({type:'assistant', sessionId:'fixture', requestId:'request',
              timestamp:new Date().toISOString(), cwd:'/fixture', message:{id:'response',
              model:'claude-fixture', usage:{input_tokens:3, output_tokens:2}}}) + '\\n';
            const batch = line.repeat(10000);
            for (let i = 0; i < 96; i++) fs.writeFileSync(path.join(projects, i + '.jsonl'), batch);
            fs.writeFileSync(path.join(root, 'runtime.json'), JSON.stringify({version:1,
              recordedAt:new Date().toISOString(),node:process.execPath,codex:null,claude:null,
              env:{PATH:path.dirname(process.execPath) + ':/usr/bin:/bin',HOME:home,
                CLAUDE_CONFIG_DIR:null,CODEX_HOME:null,XDG_CONFIG_HOME:null},
              stateDir:path.join(root,'state')}));
            fs.writeFileSync(path.join(root,'runtime-node'), process.execPath + '\\n');
            """, permissions: 0o600)
        _ = try await runNode(node, script: "seed.js")
        try await upload(path: directory + "/worker-alive.js", text: """
            const fs = require('node:fs');
            const path = require('node:path');
            const usage = path.join(process.argv[2], 'state', 'usage');
            for (const key of fs.readdirSync(usage)) {
              const lock = JSON.parse(fs.readFileSync(path.join(usage, key, 'worker.lock'), 'utf8'));
              process.kill(lock.pid, 0);
              console.log('alive');
            }
            """, permissions: 0o600)
    }

    func runNode(_ node: String, script: String) async throws -> String {
        let result = try await connection.execute(
            [node, directory + "/" + script, directory].map(GitProbe.singleQuoted).joined(separator: " "),
            timeout: Self.timeout)
        try #require(result.exitStatus == 0)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func upload(path: String, text: String, permissions: UInt32) async throws {
        let quoted = GitProbe.singleQuoted(path)
        let removed = try await connection.execute("rm -f " + quoted, timeout: Self.timeout)
        try #require(removed.exitStatus == 0)
        let sftp = try await connection.openSFTP(timeout: Self.timeout)
        let file = try await sftp.openFileForWriting(at: path, permissions: permissions, timeout: Self.timeout)
        try await file.write(Data(text.utf8), timeout: Self.timeout)
        try await file.close(timeout: Self.timeout)
        try await sftp.close(timeout: Self.timeout)
    }
}
