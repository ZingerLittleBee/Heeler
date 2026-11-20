import Foundation
import Synchronization
import Testing

@testable import Heeler

/// One Rex terminal's screen and keyboard as Chat reads them on the control
/// link, answered as Rex 0.1.0-preview.14 (API revision 12) shapes them:
/// `size`, `modes`, the `vt` text from `format` with the kitty keyboard flags
/// when asked, paged by `blob_read`, and input answered as `write` and
/// `block.event` are. Its foreground comes from the world, unless a test
/// queues the next answers. The screen is whatever a test sets.
final class FakeRexChatBlock: Sendable {
    struct State: Sendable {
        var lines: [String]
        var columns = 40
        var cursorKeys = false
        var bracketedPaste: Bool? = true
        var alternateScreen = false
        var kittyFlags = 0
        /// The next `process` answers, before the world's.
        var foregrounds: [JSONValue] = []
        /// The next `modes` answers' bracketed paste, before `bracketedPaste`.
        var bracketedPasteAnswers: [Bool] = []
    }

    let state: Mutex<State>

    init(lines: [String]) {
        state = Mutex(State(lines: lines))
    }

    func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    /// The world's block at `index` of the studio's first layer answers for
    /// the foreground.
    func install(on server: FakeRexServer, world: FakeRexWorld, blockIndex: Int = 2) async {
        await server.answer(RexInventoryWire.terminalMethod("size")) { [self] _ in
            let state = state.withLock { $0 }
            return .result([
                "columns": .number(Double(state.columns)), "rows": .number(Double(state.lines.count)), "owner": .null,
            ])
        }
        await server.answer(RexInventoryWire.terminalMethod("modes")) { [self] _ in
            let (state, queuedPaste) = state.withLock { state -> (State, Bool?) in
                let queued = state.bracketedPasteAnswers.isEmpty ? nil : state.bracketedPasteAnswers.removeFirst()
                return (state, queued)
            }
            var modes: [JSONValue] = [
                ["name": "insert", "number": 4, "ansi": true, "set": false],
                ["name": "cursor_keys", "number": 1, "set": .bool(state.cursorKeys)],
            ]
            if let paste = queuedPaste ?? state.bracketedPaste {
                modes.append(["name": "bracketed_paste", "number": 2004, "set": .bool(paste)])
            }
            return .result(["screen": .string(state.alternateScreen ? "alternate" : "primary"), "modes": .array(modes)])
        }
        await server.answer(RexInventoryWire.terminalMethod("format")) { [self] request in
            let text = answerText(kitty: request.payload?["args"]?["extra_kitty_keyboard"] == true)
            let limit = Self.integer(request.payload?["args"]?["max_bytes"]) ?? .max
            let bytes = Data(text.utf8)
            let end = min(bytes.count, limit)
            var result: [String: JSONValue] = [
                "content": .string(String(decoding: bytes.prefix(end), as: UTF8.self)),
                "total": .number(Double(bytes.count)),
            ]
            if end < bytes.count { result["id"] = 1 } else { result["eof"] = true }
            return .result(.object(result))
        }
        await server.answer(RexInventoryWire.terminalMethod("blob_read")) { [self] request in
            // The blob is the answer as the last format took it, kitty flags and all.
            let bytes = Data(answerText(kitty: true).utf8)
            let offset = min(Self.integer(request.payload?["args"]?["offset"]) ?? 0, bytes.count)
            let limit = Self.integer(request.payload?["args"]?["max_bytes"]) ?? .max
            let end = offset + min(bytes.count - offset, limit)
            return .result([
                "id": 1, "data": .string(String(decoding: bytes[offset..<end], as: UTF8.self)),
                "total": .number(Double(bytes.count)), "eof": .bool(end == bytes.count),
            ])
        }
        await server.answer(RexInventoryWire.terminalMethod("process")) { [self, world] _ in
            if let queued = state.withLock({ $0.foregrounds.isEmpty ? nil : $0.foregrounds.removeFirst() }) {
                return .result(queued)
            }
            return .result(FakeRexWorld.process(world.sessions[0].windows[0].layers[0].blocks[blockIndex]))
        }
        await server.answer(RexInventoryWire.terminalMethod("write")) { request in
            let data = request.payload?["args"]?["data"]?.stringValue ?? ""
            return .result(["bytes_written": .number(Double(data.utf8.count))])
        }
        await server.answer("block.event", with: .result(.object([:])))
    }

    /// History, then the screen's rows, joined as `vt` joins them.
    private func answerText(kitty: Bool) -> String {
        let state = state.withLock { $0 }
        var text = (["history above the screen"] + state.lines).joined(separator: "\r\n")
        if kitty, state.kittyFlags > 0 { text += "\u{1B}[=\(state.kittyFlags);1u" }
        return text
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value else { return nil }
        return Int(number)
    }

    /// A foreground as `process` answers it.
    static func foreground(_ program: String, pid: Int) -> JSONValue {
        ["foreground": ["pid": .number(Double(pid)), "name": .string(program), "argv0": .string(program)]]
    }
}

/// A started Rex projection on one scripted SSH connection, its studio's left
/// terminal running an Agent, and Chat's block reads on top.
@MainActor
struct RexChatRig {
    static let socket = "/run/user/1000/rex/server.sock"
    static let address = RexPaneAddress(sessionID: "session:studio", blockID: "block:left")
    static var paneID: String { address.paneID }
    static let write = RexInventoryWire.terminalMethod("write")

    let projection: RexConsoleProjection
    let server: FakeRexServer
    let world: FakeRexWorld
    let block: FakeRexChatBlock
    let connection: ScriptedRexHost

    /// The studio with `program` in its left terminal, reporting `state`.
    static func studio(running program: String = "claude", reporting state: String? = "working") -> FakeRexWorld.Session {
        var studio = FakeRexWorld.studio()
        var agent = FakeRexWorld.Block.running("block:left", program: program)
        agent.label = "left"
        agent.directory = "/home/dev/app"
        if let state { agent.status = agent.record(state, app: program) }
        studio.windows[0].layers[0].blocks[2] = agent
        return studio
    }

    static func start(
        _ block: FakeRexChatBlock, world: FakeRexWorld = FakeRexWorld(sessions: [RexChatRig.studio()]),
        inputDeadline: RexDeliveryDeadline? = nil,
        readDeadline: RexDeliveryDeadline = RexDeliveryDeadline(silence: .seconds(5), limit: .seconds(10)),
        sendClock: BlockedCardClock = .live, servers: Int = 1
    ) async throws -> RexChatRig {
        let server = FakeRexServer()
        await world.install(on: server)
        await block.install(on: server, world: world)
        var controls: [ScriptedRexHost.Channel] = [.server(server)]
        for _ in 1..<max(servers, 1) {
            let next = FakeRexServer()
            await world.install(on: next)
            await block.install(on: next, world: world)
            controls.append(.server(next))
        }
        let connection = ScriptedRexHost(control: controls)
        let dialer = RexHostSessionTests.Dialer([connection])
        var options = RexTerminalAttach.Options()
        options.stream.link = .testing
        if let inputDeadline { options.inputDeadline = inputDeadline }
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex, rexSocket: RexSocket(path: socket))
        let session = RexHostSession(
            storedSocket: host.rexSocket, connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            terminalOptions: options)
        let projection = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), chatReadDeadline: readDeadline,
            sendClock: sendClock, onChange: {})
        projection.start(isActive: true)
        let rig = RexChatRig(projection: projection, server: server, world: world, block: block, connection: connection)
        try await rig.waitUntil("the Agent listed") {
            !projection.isAwaitingSnapshot && projection.agentsByPane[RexChatRig.paneID] != nil
        }
        // The Agent is listed as soon as its own reads answer, with other
        // terminals' still on the link. A test that counts what it sends
        // starts once the link is quiet.
        try await rig.waitUntil("every terminal's first reads") {
            projection.inventory?.sessions.flatMap(\.terminals).contains { $0.details.awaitsForeground } == false
        }
        return rig
    }

    func end() {
        projection.end()
    }

    func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        throw CancellationError()
    }

    /// Input that reached `server`, in order.
    static func inputs(_ server: FakeRexServer) async -> [FakeRexServer.Request] {
        await server.requests.filter { $0.method == write || $0.method == "block.event" }
    }

    func inputs() async -> [FakeRexServer.Request] {
        await Self.inputs(server)
    }

    /// Composer Send for the left terminal.
    func composerSend() throws -> any CheckedComposerSend {
        let projection = projection
        let send = projection.checkedComposerSend(
            for: Self.paneID, keepingTo: TerminalCorePin(joined: projection.inventoryCore), live: { projection })
        return try #require(send)
    }

    /// What each write carried.
    func written() async -> [String] {
        await inputs().filter { $0.method == Self.write }.compactMap { $0.payload?["args"]?["data"]?.stringValue }
    }

    /// What each paste carried.
    func pasted() async -> [String] {
        await inputs().filter { $0.method == "block.event" }.compactMap {
            $0.payload?["event"]?["payload"]?["text"]?.stringValue
        }
    }

    /// Chat took no size and no block, attached to no session, and opened no
    /// data link.
    func tookNothing(sourceLocation: SourceLocation = #_sourceLocation) async {
        let taking: Set<String> = [
            "session.attach", "session.own_block", "session.disown_block", RexInventoryWire.terminalMethod("resize"),
        ]
        let methods = await server.requests.map(\.method)
        #expect(!methods.contains(where: taking.contains), sourceLocation: sourceLocation)
        #expect(await connection.log.allSatisfy { $0.hasPrefix("control ") }, sourceLocation: sourceLocation)
    }
}
