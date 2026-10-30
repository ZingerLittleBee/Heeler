import Foundation
import Testing

@testable import Heeler

/// The framed transport over a scripted locator exec and a fake core socket:
/// which outcome the Host reads, and that nothing but the locator and one
/// channel ever happens.
@Suite struct HerdrCoreSSHTransportTests {
    // MARK: Connecting

    @Test func aRunningCoreConnectsOverTheLockedSocketWithOneFramedHello() async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(lock: "/tmp/elsewhere.sock", socketFile: true),
            channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()

        let info = try await transport.hello()

        #expect(info.coreID == "c1")
        #expect(info.version == "0.1.13")
        #expect(await host.log == ["locator", "open /tmp/elsewhere.sock"])
        let socket = try #require(await host.socket)
        let line = try JSONDecoder().decode(JSONValue.self, from: await socket.nextWrittenLine())
        #expect(line["params"] == .object(["generation": .number(1), "framed": .bool(true)]))
        try await transport.close()
    }

    @Test func callersThatRaceShareOneLink() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()

        async let first = transport.hello()
        async let second = transport.hello()
        _ = try await (first, second)

        #expect(await host.log == ["locator", "open \(ScriptedCoreHost.socketPath)"])
        try await transport.close()
    }

    @Test func aLaterHelloReusesTheLink() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()

        _ = try await transport.hello()
        _ = try await transport.hello()

        #expect(await host.log == ["locator", "open \(ScriptedCoreHost.socketPath)"])
        try await transport.close()
    }

    @Test func noLockTriesTheSessionsDefaultSocket() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()

        _ = try await transport.hello()

        #expect(await host.log.last == "open \(ScriptedCoreHost.socketPath)")
        try await transport.close()
    }

    @Test func aVersionOtherThanTheTestedOneIsAdvisory() async throws {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(version: "9.8.7"),
            channel: .answersHello(ScriptedCoreHost.helloReply(result: .object([
                "generation": .number(1), "version": .string("9.8.7"),
                "core": .object(["id": .string("c1"), "name": .string("lab")]),
                "framed": .bool(true),
                "features": .array(["framed", "attach", "events", "status"].map(JSONValue.string)),
            ]))))
        let transport = host.transport()

        #expect(try await transport.hello().version == "9.8.7")
        try await transport.close()
    }

    @Test func serverStatusAnswersOverTheLinkItOpens() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()
        let status = Task { try await transport.serverStatus() }
        let socket = try await waitForSocket(host)

        let request = await socket.nextRequest()
        #expect(request.method == "server.status")
        try await socket.reply(to: request.id, result: .object([
            "core": .object(["id": .string("c1"), "name": .string("lab")]),
            "version": .string("0.1.13"), "pid": .number(4242), "uptime_ms": .number(100),
        ]))

        #expect(try await status.value.pid == 4242)
        #expect(await host.log == ["locator", "open \(ScriptedCoreHost.socketPath)"])
        try await transport.close()
    }

    @Test func closeEndsTheLinkThenTheConnection() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()
        _ = try await transport.hello()
        let socket = try #require(await host.socket)

        try await transport.close()

        #expect(await socket.isClosed)
        #expect(await host.log.last == "close")
    }

    // MARK: What the Host reads

    @Test func noProgramReadsNotInstalledAndOpensNothing() async {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(executable: nil),
            channel: .answersHello(ScriptedCoreHost.helloReply()))

        await #expect(throws: TransportError.herdrCoreNotInstalled) {
            try await host.transport().hello()
        }
        #expect(await host.log == ["locator"])
    }

    @Test func aRefusedChannelWithNoSocketFileReadsNotRunning() async {
        let host = ScriptedCoreHost(channel: .refused)

        await #expect(
            throws: TransportError.herdrCoreNotRunning(
                socketPath: ScriptedCoreHost.socketPath, socketFilePresent: false)
        ) {
            try await host.transport().hello()
        }
    }

    @Test func aStaleLockReadsNotRunningAtTheLockedPath() async {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(lock: "/tmp/gone.sock", socketFile: false),
            channel: .refused)

        await #expect(
            throws: TransportError.herdrCoreNotRunning(socketPath: "/tmp/gone.sock", socketFilePresent: false)
        ) {
            try await host.transport().hello()
        }
    }

    @Test func aRefusedChannelWithASocketFileLeftBehindReadsNotRunningWithIt() async {
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(socketFile: true), channel: .refused)

        await #expect(
            throws: TransportError.herdrCoreNotRunning(
                socketPath: ScriptedCoreHost.socketPath, socketFilePresent: true)
        ) {
            try await host.transport().hello()
        }
    }

    @Test func anOverLongSocketPathReadsTooLongInsteadOfNotRunning() async {
        let path = "/" + String(repeating: "a", count: 107)
        let host = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(defaultPath: path),
            channel: .answersHello(ScriptedCoreHost.helloReply()))

        await #expect(throws: TransportError.herdrCoreSocketPathTooLong(path: path, limit: 107)) {
            try await host.transport().hello()
        }
        #expect(await host.log == ["locator"])
    }

    @Test(arguments: [
        ["framed", "attach", "events"], ["framed", "attach", "status"], ["framed", "events", "status"],
        ["attach", "events", "status"], [],
    ])
    func aMissingFeatureReadsUpdateRequiredByTheProbedPath(features: [String]) async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply(features: features)))

        await #expect(
            throws: TransportError.herdrCoreUpdateRequired(
                command: "\(ScriptedCoreHost.installedPath) update")
        ) {
            try await host.transport().hello()
        }
        let socket = try #require(await host.socket)
        await socket.waitUntilClosed()
    }

    @Test(arguments: ["unknown_method", "needs_framed", "unsupported_generation"])
    func anOlderCoresErrorReadsUpdateRequired(kind: String) async {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply(errorKind: kind)))

        await #expect(
            throws: TransportError.herdrCoreUpdateRequired(
                command: "\(ScriptedCoreHost.installedPath) update")
        ) {
            try await host.transport().hello()
        }
    }

    @Test func unknownMethodLaterOnTheLinkAlsoReadsUpdateRequired() async throws {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))
        let transport = host.transport()
        let status = Task { try await transport.serverStatus() }
        let socket = try await waitForSocket(host)

        let request = await socket.nextRequest()
        try await socket.replyError(to: request.id, kind: "unknown_method")

        await #expect(
            throws: TransportError.herdrCoreUpdateRequired(
                command: "\(ScriptedCoreHost.installedPath) update")
        ) {
            try await status.value
        }
        try await transport.close()
    }

    @Test func aFailedOpenIsNotKeptSoTheNextCallLooksAgain() async {
        let host = ScriptedCoreHost(channel: .refused)
        let transport = host.transport()

        await #expect(throws: TransportError.self) { try await transport.hello() }
        await #expect(throws: TransportError.self) { try await transport.hello() }

        #expect(await host.log.filter { $0 == "locator" }.count == 2)
    }

    // MARK: What it refuses to act on

    @Test func aSessionNameHCRefusesNeverReachesTheHost() async {
        let host = ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply()))

        await #expect(throws: TransportError.self) {
            try await host.transport(session: "../invalid-session").hello()
        }
        #expect(await host.log.isEmpty)
    }

    @Test func theSessionReachesTheLocatorNormalized() async throws {
        let host = ScriptedCoreHost(channel: .refused)

        _ = try await host.transport(session: "  phone work\n").locate()

        #expect(await host.scripts.first?.hasPrefix("__session='phone work'\n") == true)
    }

    @Test func aLocatorThatFailsOrPrintsNonsenseIsMalformed() async {
        let failed = ScriptedCoreHost(locatorStatus: 127, channel: .refused)
        await #expect {
            try await failed.transport().hello()
        } throws: { error in
            if case TransportError.malformedResponse = error { return true }
            return false
        }
        let nonsense = ScriptedCoreHost(locator: ["not the locator"], channel: .refused)
        await #expect {
            try await nonsense.transport().hello()
        } throws: { error in
            if case TransportError.malformedResponse = error { return true }
            return false
        }
        #expect(await nonsense.log == ["locator"])
    }

    private func waitForSocket(_ host: ScriptedCoreHost) async throws -> FakeCoreSocket {
        var budget = PollBudget(.seconds(10))
        while budget.hasTimeLeft {
            if let socket = await host.socket { return socket }
            try await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }
        return try #require(await host.socket)
    }
}
