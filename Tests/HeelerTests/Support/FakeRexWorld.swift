import Foundation
import Synchronization

@testable import Heeler

/// What a fake Rex server lists: sessions, their windows and layers, and the
/// blocks in them, answered in the shapes Rex 0.1.0-preview.14 (API revision
/// 12) was seen to use. Ids, labels, titles and paths are invented.
final class FakeRexWorld: Sendable {
    struct Block: Sendable {
        var id: String
        var label = "shell"
        var creator = RexInventoryWire.terminalCreator
        var flavor = "com.superlogical.terminal.shell"
        var owner: String? = "client:00000000-0000-7000-8000-0000000000aa"
        var title = ""
        var program: String? = "zsh"
        var directory: String? = "/home/dev"
        var processID = 4242
        var argv0: String?
        var script: String?
        /// The root Program Status record `program_status` answers; nil for none.
        var status: JSONValue?

        init(_ id: String) {
            self.id = id
        }

        /// A terminal whose foreground is `program` started as `argv0`, as an
        /// agent typed into a shell is.
        static func running(_ id: String, program: String, argv0: String? = nil) -> Block {
            var block = Block(id)
            block.program = program
            block.argv0 = argv0 ?? program
            return block
        }

        /// The root record a report of `state` from the foreground leaves, or
        /// from `owner` when another process made it, taken at `at`: Rex
        /// moves the time on every report, the same one made again too.
        /// `message` is what the program said it is doing.
        func record(
            _ state: String, app: String? = nil, owner: (pid: Int, name: String)? = nil,
            at time: String = "2026-11-16T12:00:00+00:00", message: String? = nil
        ) -> JSONValue {
            var record: [String: JSONValue] = [
                "state": .string(state), "updated_at": .string(time),
                "owner": [
                    "pid": .number(Double(owner?.pid ?? processID)), "name": .string(owner?.name ?? program ?? ""),
                ],
            ]
            if let app {
                record["app"] = .string(app)
                record["effective_app"] = .string(app)
            }
            if let message { record["msg"] = .string(message) }
            return .object(record)
        }

        /// A block some other creator made, which is not a terminal.
        static func notes(_ id: String) -> Block {
            var block = Block(id)
            block.label = "notes"
            block.creator = "com.example.notes"
            block.flavor = "com.example.notes.page"
            return block
        }
    }

    indirect enum Layout: Sendable {
        case block(String)
        case split(Layout, Layout)
    }

    struct Layer: Sendable {
        var floating = false
        var layout: Layout?
        var blocks: [Block]
    }

    struct Window: Sendable {
        var id: String
        var label: String
        var layers: [Layer]
    }

    struct Session: Sendable {
        var id: String
        var label: String
        var revision = 1
        var activeWindowID: String?
        var windows: [Window]
        var detached: [Block] = []
    }

    private struct State {
        var instanceID: String
        var sessions: [Session]
    }

    private let state: Mutex<State>
    /// What `server.version` names as the server's `platform`; nil answers
    /// without one.
    let platform: String?

    init(instanceID: String = "instance-0001", sessions: [Session] = [], platform: String? = "darwin_arm64") {
        state = Mutex(State(instanceID: instanceID, sessions: sessions))
        self.platform = platform
    }

    var sessions: [Session] { state.withLock { $0.sessions } }

    func update(_ change: (inout [Session]) -> Void) {
        state.withLock { change(&$0.sessions) }
    }

    /// Another server process on the same socket.
    func restart(as instanceID: String) {
        state.withLock { $0.instanceID = instanceID }
    }

    /// Answers every read the inventory makes as this world stands at the time,
    /// and what an open terminal asks of `client`'s blocks.
    func install(on server: FakeRexServer, client: String? = FakeRexServer.Welcome().clientID) async {
        await server.answer("server.status") { [self] _ in
            .result(["instance_id": .string(state.withLock { $0.instanceID }), "session_count": 1])
        }
        await server.answer("server.version") { [platform] _ in
            .result(.object(platform.map { ["platform": .string($0)] } ?? [:]))
        }
        await server.answer("session.attach_all") { [self] _ in .result(attachAll) }
        await server.answer("session.view") { [self] request in
            guard let session = session(request) else { return Self.sessionNotFound }
            return .result(Self.view(session))
        }
        await server.answer("session.list_blocks") { [self] request in
            guard let session = session(request) else { return Self.sessionNotFound }
            return .result(Self.listing(session))
        }
        await server.answer(RexInventoryWire.terminalMethod("title")) { [self] request in
            guard let block = block(request) else { return Self.blockNotFound }
            return .result(["title": .string(block.title)])
        }
        await server.answer(RexInventoryWire.terminalMethod("process")) { [self] request in
            guard let block = block(request) else { return Self.blockNotFound }
            return .result(Self.process(block))
        }
        await server.answer(RexInventoryWire.terminalMethod("program_status")) { [self] request in
            guard let block = block(request) else { return Self.blockNotFound }
            return .result(["records": .array(block.status.map { [$0] } ?? [])])
        }
        // What an open terminal asks: its session attached, and its size.
        await server.answer("session.attach") { [self] request in
            guard let session = session(request) else { return Self.sessionNotFound }
            return .result(["session_id": .string(session.id)])
        }
        await server.answer(RexInventoryWire.terminalMethod("resize")) { [self] request in
            guard block(request) != nil else { return Self.blockNotFound }
            return .result(.object([:]))
        }
        // Taking a block makes `client` its owner; giving it back leaves it
        // with none, as when nobody else is in line. Neither pushes the owner
        // change, which a test pushes as the server would.
        await server.answer("session.own_block") { [self] request in
            claim(request) { _ in client }
        }
        await server.answer("session.disown_block") { [self] request in
            claim(request) { owner in owner == client ? nil : owner }
        }
    }

    /// Sets the owner of each block a take or give back names, and answers
    /// with each one's owner after it, as Rex does.
    private func claim(_ request: FakeRexServer.Request, owner next: (String?) -> String?) -> FakeRexServer.Answer {
        guard case .array(let ids)? = request.payload?["block_ids"], !ids.isEmpty,
            let sessionID = request.payload?["session_id"]?.stringValue
        else { return .error(code: "bad_request", message: "name the blocks", status: 400) }
        let named = ids.compactMap(\.stringValue)
        var answered: [JSONValue] = []
        let found = state.withLock { state -> Bool in
            guard let index = state.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
            var session = state.sessions[index]
            for id in named {
                guard Self.update(id, in: &session, { $0.owner = next($0.owner) }) else { return false }
            }
            state.sessions[index] = session
            for id in named {
                let owner = Self.blocks(of: session).first { $0.id == id }?.owner
                var entry: [String: JSONValue] = ["block_id": .string(id)]
                if let owner { entry["owner"] = .string(owner) }
                answered.append(.object(entry))
            }
            return true
        }
        guard found else { return .error(code: "bad_request", message: "no such block", status: 400) }
        return .result(["blocks": .array(answered)])
    }

    private static func blocks(of session: Session) -> [Block] {
        session.windows.flatMap { $0.layers.flatMap(\.blocks) } + session.detached
    }

    private static func update(_ id: String, in session: inout Session, _ change: (inout Block) -> Void) -> Bool {
        for window in session.windows.indices {
            for layer in session.windows[window].layers.indices {
                if let index = session.windows[window].layers[layer].blocks.firstIndex(where: { $0.id == id }) {
                    change(&session.windows[window].layers[layer].blocks[index])
                    return true
                }
            }
        }
        if let index = session.detached.firstIndex(where: { $0.id == id }) {
            change(&session.detached[index])
            return true
        }
        return false
    }

    /// The owner of `blockID` in `sessionID`, as the world stands.
    func owner(of blockID: String, in sessionID: String = "session:studio") -> String? {
        sessions.first { $0.id == sessionID }.flatMap { Self.blocks(of: $0).first { $0.id == blockID }?.owner }
    }

    // MARK: Answers

    var attachAll: JSONValue {
        .object([
            "sessions": .array(
                sessions.map { .object(["session_id": .string($0.id), "label": .string($0.label)]) })
        ])
    }

    static func view(_ session: Session) -> JSONValue {
        var view: [String: JSONValue] = [
            "revision": .number(Double(session.revision)), "session_id": .string(session.id),
            "label": .string(session.label),
            "windows": .array(session.windows.map(window)),
        ]
        if let active = session.activeWindowID ?? session.windows.first?.id { view["active_window_id"] = .string(active) }
        return .object(view)
    }

    static func listing(_ session: Session) -> JSONValue {
        var blocks: [JSONValue] = []
        for window in session.windows {
            for layer in window.layers {
                for block in layer.blocks {
                    blocks.append(facts(block, extra: ["placement": "placed", "window_id": .string(window.id)]))
                }
            }
        }
        for block in session.detached {
            blocks.append(facts(block, extra: ["placement": "detached"]))
        }
        return .object(["blocks": .array(blocks)])
    }

    static func process(_ block: Block) -> JSONValue {
        guard let program = block.program else { return .object(["foreground": .null]) }
        var foreground: [String: JSONValue] = ["pid": .number(Double(block.processID)), "name": .string(program)]
        if let directory = block.directory { foreground["cwd"] = .string(directory) }
        if let argv0 = block.argv0 { foreground["argv0"] = .string(argv0) }
        if let script = block.script { foreground["script"] = .string(script) }
        return .object(["foreground": .object(foreground)])
    }

    private static func window(_ window: Window) -> JSONValue {
        .object([
            "window_id": .string(window.id), "label": .string(window.label),
            "layers": .array(
                window.layers.enumerated().map { index, layer in
                    var value: [String: JSONValue] = [
                        "layer_id": .string("layer:\(window.id)-\(index)"),
                        "kind": .string(layer.floating ? "floating" : "tiled"),
                        "blocks": .array(layer.blocks.map { facts($0) }),
                    ]
                    if let layout = layer.layout { value["layout"] = node(layout) }
                    return .object(value)
                }),
        ])
    }

    private static func node(_ layout: Layout) -> JSONValue {
        switch layout {
        case .block(let id):
            .object(["rect": [0, 0, 1, 1], "block_id": .string(id)])
        case .split(let before, let after):
            .object([
                "rect": [0, 0, 1, 1],
                "split": .object([
                    "split_id": "split:fake", "direction": "horizontal", "ratio": .number(0.5),
                    "before": node(before), "after": node(after),
                ]),
            ])
        }
    }

    private static func facts(_ block: Block, extra: [String: JSONValue] = [:]) -> JSONValue {
        var value: [String: JSONValue] = [
            "block_id": .string(block.id), "label": .string(block.label), "creator_name": .string(block.creator),
            "flavor": .string(block.flavor), "host_id": "host-0001",
        ]
        if let owner = block.owner { value["owner"] = .string(owner) }
        return .object(value.merging(extra) { _, new in new })
    }

    private static let sessionNotFound = FakeRexServer.Answer.error(
        code: "session_not_found", message: "no such session", status: 404)
    private static let blockNotFound = FakeRexServer.Answer.error(
        code: "not_found", message: "no such block", status: 404)

    private func session(_ request: FakeRexServer.Request) -> Session? {
        let id = request.payload?["session_id"]?.stringValue
        return sessions.first { $0.id == id }
    }

    private func block(_ request: FakeRexServer.Request) -> Block? {
        guard let session = session(request), let id = request.payload?["block_id"]?.stringValue else { return nil }
        let blocks = session.windows.flatMap { $0.layers.flatMap(\.blocks) } + session.detached
        return blocks.first { $0.id == id }
    }
}

extension FakeRexWorld {
    /// One session laid out as Rex lays out a busy one: a window split in two
    /// with a notes block beside them, a window with a floating layer over its
    /// one terminal, and a terminal detached from both.
    static func studio(id: String = "session:studio", label: String = "studio") -> Session {
        var left = Block("block:left")
        left.label = "left"
        left.title = "make test"
        left.program = "make"
        left.directory = "/home/dev/app"
        let right = Block("block:right")
        let notes = Block.notes("block:notes")
        var solo = Block("block:solo")
        solo.program = "vim"
        solo.directory = "/home/dev/app/src"
        var float = Block("block:float")
        float.label = "scratch"
        var detached = Block("block:detached")
        detached.program = "tail"
        return Session(
            id: id, label: label, revision: 3, activeWindowID: "window:0000-0000-0000-00000000b0b0",
            windows: [
                Window(
                    id: "window:0000-0000-0000-00000000a0a0", label: "editor",
                    layers: [
                        Layer(
                            layout: .split(.block(left.id), .split(.block(notes.id), .block(right.id))),
                            blocks: [right, notes, left])
                    ]),
                Window(
                    // Rex's own label for a new window, its id's last eight digits: unnamed.
                    id: "window:0000-0000-0000-00000000b0b0", label: "Window 0000b0b0",
                    layers: [
                        Layer(layout: .block(solo.id), blocks: [solo]),
                        Layer(floating: true, layout: .block(float.id), blocks: [float]),
                    ]),
            ],
            detached: [detached])
    }
}
