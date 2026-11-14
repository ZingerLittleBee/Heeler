import Foundation

/// A Terminal's OSC 7501 report, in the program's own words.
struct HerdrCoreTerminalStatus: Decodable, Equatable, Sendable {
    let state: String
    let kind: String?
    let progress: Int?
    let app: String
    let title: String
    let message: String

    init(state: String, kind: String?, progress: Int?, app: String, title: String, message: String) {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case state, kind, progress, app, title
        case message = "msg"
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        state = try fields.decodeIfPresent(String.self, forKey: .state) ?? ""
        kind = try fields.decodeIfPresent(String.self, forKey: .kind)
        progress = try fields.decodeIfPresent(Int.self, forKey: .progress)
        app = try fields.decodeIfPresent(String.self, forKey: .app) ?? ""
        title = try fields.decodeIfPresent(String.self, forKey: .title) ?? ""
        message = try fields.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// What holds a Terminal's foreground right now.
struct HerdrCoreForeground: Decodable, Equatable, Sendable {
    let pid: Int?
    let name: String
    let argv: [String]
    let cwd: String

    init(pid: Int?, name: String, argv: [String], cwd: String) {
        self.pid = pid
        self.name = name
        self.argv = argv
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey {
        case pid, name, argv, cwd
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        pid = try fields.decodeIfPresent(Int.self, forKey: .pid)
        name = try fields.decodeIfPresent(String.self, forKey: .name) ?? ""
        argv = try fields.decodeIfPresent([String].self, forKey: .argv) ?? []
        cwd = try fields.decodeIfPresent(String.self, forKey: .cwd) ?? ""
    }
}

/// How a Terminal's program ended, for `lost` and `finished`.
struct HerdrCoreTerminalEnd: Decodable, Equatable, Sendable {
    let reason: String?
    let exitCode: Int?
    let signal: Int?
    let finishedMilliseconds: Int?

    private enum CodingKeys: String, CodingKey {
        case reason, signal
        case exitCode = "exit_code"
        case finishedMilliseconds = "finished_ms"
    }
}

/// A Terminal as the core's API shows it. Only the address is required, so a
/// newer core may drop or add any other field without breaking inventory.
struct HerdrCoreTerminalRecord: Decodable, Equatable, Sendable {
    let address: String
    let name: String?
    var labels: [String: String]
    let argv: [String]
    let cwd: String
    var keep: Bool
    var state: String
    var pid: Int?
    var exitCode: Int?
    let signal: Int?
    var reason: String?
    let createdMilliseconds: Int?
    let finishedMilliseconds: Int?
    let screen: String?
    var columns: Int
    var rows: Int
    let identity: String?
    var status: HerdrCoreTerminalStatus?
    let statusMilliseconds: Int?
    var records: [String: HerdrCoreTerminalStatus]
    var turn: Int
    var reported: Bool
    var title: String
    let parent: String?
    let notify: Bool
    let dieWithParent: Bool
    let removeOnExit: Bool
    let template: String?
    let submit: String?
    let stop: String?
    let pasteGapMilliseconds: Int?
    var foreground: HerdrCoreForeground?

    /// The core keeps a finished Terminal until it is removed. The Console hides it.
    var hasFinished: Bool { state == "finished" }

    /// One `foreground` event. A cleared one says the core cannot name the group
    /// holding the terminal, as when its leader has left and a member stays. That
    /// names no program, so the last sample stands until the next.
    mutating func noteForeground(_ sample: HerdrCoreForeground?) {
        if let sample { foreground = sample }
    }

    /// Between losing a kept Terminal's program and its new shell: live, with
    /// no process and a reason that is not a first spawn still pending.
    var isRestarting: Bool {
        guard state == "live", pid == nil, let reason else { return false }
        return reason != "spawn_pending"
    }

    private enum CodingKeys: String, CodingKey {
        case address, name, labels, argv, cwd, keep, state, pid, signal, reason, screen, rows
        case identity, status, records, turn, reported, title, parent, notify, template, submit
        case stop, foreground
        case exitCode = "exit_code"
        case createdMilliseconds = "created_ms"
        case finishedMilliseconds = "finished_ms"
        case columns = "cols"
        case statusMilliseconds = "status_ms"
        case dieWithParent = "die_with_parent"
        case removeOnExit = "rm"
        case pasteGapMilliseconds = "paste_gap_ms"
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        address = try fields.decode(String.self, forKey: .address)
        guard !address.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .address, in: fields, debugDescription: "A terminal has an empty address.")
        }
        name = try fields.decodeIfPresent(String.self, forKey: .name)
        labels = try fields.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        argv = try fields.decodeIfPresent([String].self, forKey: .argv) ?? []
        cwd = try fields.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        keep = try fields.decodeIfPresent(Bool.self, forKey: .keep) ?? false
        state = try fields.decodeIfPresent(String.self, forKey: .state) ?? ""
        pid = try fields.decodeIfPresent(Int.self, forKey: .pid)
        exitCode = try fields.decodeIfPresent(Int.self, forKey: .exitCode)
        signal = try fields.decodeIfPresent(Int.self, forKey: .signal)
        reason = try fields.decodeIfPresent(String.self, forKey: .reason)
        createdMilliseconds = try fields.decodeIfPresent(Int.self, forKey: .createdMilliseconds)
        finishedMilliseconds = try fields.decodeIfPresent(Int.self, forKey: .finishedMilliseconds)
        screen = try fields.decodeIfPresent(String.self, forKey: .screen)
        columns = try fields.decodeIfPresent(Int.self, forKey: .columns) ?? 0
        rows = try fields.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        identity = try fields.decodeIfPresent(String.self, forKey: .identity)
        status = try fields.decodeIfPresent(HerdrCoreTerminalStatus.self, forKey: .status)
        statusMilliseconds = try fields.decodeIfPresent(Int.self, forKey: .statusMilliseconds)
        records = try fields.decodeIfPresent([String: HerdrCoreTerminalStatus].self, forKey: .records) ?? [:]
        turn = try fields.decodeIfPresent(Int.self, forKey: .turn) ?? 0
        reported = try fields.decodeIfPresent(Bool.self, forKey: .reported) ?? false
        title = try fields.decodeIfPresent(String.self, forKey: .title) ?? ""
        parent = try fields.decodeIfPresent(String.self, forKey: .parent)
        notify = try fields.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        dieWithParent = try fields.decodeIfPresent(Bool.self, forKey: .dieWithParent) ?? false
        removeOnExit = try fields.decodeIfPresent(Bool.self, forKey: .removeOnExit) ?? false
        template = try fields.decodeIfPresent(String.self, forKey: .template)
        submit = try fields.decodeIfPresent(String.self, forKey: .submit)
        stop = try fields.decodeIfPresent(String.self, forKey: .stop)
        pasteGapMilliseconds = try fields.decodeIfPresent(Int.self, forKey: .pasteGapMilliseconds)
        foreground = try fields.decodeIfPresent(HerdrCoreForeground.self, forKey: .foreground)
    }

    init(tmuxPane pane: TmuxInventory.Pane) {
        var labels: [String: String] = [:]
        if !pane.agentSession.isEmpty {
            labels[HerdrCoreSessionHint.sessionLabel] = pane.agentSession
        }
        if !pane.chatPick.isEmpty {
            labels[HerdrCoreSessionHint.pickLabel] = pane.chatPick
        }
        let pid = pane.processID > 0 ? pane.processID : nil
        let argv = pane.foregroundArguments ?? []
        address = pane.paneID
        name = nil
        self.labels = labels
        self.argv = argv
        cwd = pane.path
        keep = false
        state = pane.isDead ? "finished" : "live"
        self.pid = pid
        exitCode = nil
        signal = nil
        reason = nil
        createdMilliseconds = nil
        finishedMilliseconds = nil
        screen = nil
        columns = pane.width
        rows = pane.height
        identity = nil
        status = nil
        statusMilliseconds = nil
        records = [:]
        turn = 0
        reported = false
        title = ""
        parent = nil
        notify = false
        dieWithParent = false
        removeOnExit = false
        template = nil
        submit = nil
        stop = nil
        pasteGapMilliseconds = nil
        // `pane.processID` (`#{pane_pid}`) is the Pane's top process (`self.pid`),
        // often a login shell, while `command`, `foregroundArguments`, and `path`
        // describe its foreground job without reporting that job's pid. Leave
        // `foreground.pid` nil so `HerdrCoreSessionBinder` walks from `record.pid`
        // and relies on `foreground` only for `name`, `argv`, and `cwd`.
        foreground = !pane.isDead && pid != nil
            ? HerdrCoreForeground(pid: nil, name: pane.command, argv: argv, cwd: pane.path)
            : nil
    }
}

/// The terminals a subscription starts from, or that a `missed` replaces them
/// with. Federated addresses belong to another machine and are left out.
struct HerdrCoreSnapshot: Equatable, Sendable {
    let sequence: Int
    let terminals: [HerdrCoreTerminalRecord]
    /// The events channel; only a subscribe result names one.
    let channel: UInt32?

    init(result: JSONValue) throws {
        guard let sequence = HerdrCoreWire.integer(result["seq"]), sequence >= 0,
            case .array(let records) = result["terminals"]
        else { throw TransportError.malformedResponse(String(localized: "herdr-core: Invalid subscription snapshot.")) }
        self.sequence = sequence
        terminals = try records.map { try HerdrCoreWire.typed($0) as HerdrCoreTerminalRecord }
            .filter { !$0.address.contains("/") }
        channel = HerdrCoreWire.integer(result["channel"]).flatMap(UInt32.init(exactly:))
    }
}

/// One fact change from the core, or the local `dropped` marker.
enum HerdrCoreEvent: Equatable, Sendable {
    case created(HerdrCoreTerminalRecord)
    case restarted(HerdrCoreTerminalRecord)
    case size(terminal: String, columns: Int, rows: Int)
    case title(terminal: String, title: String)
    case foreground(terminal: String, HerdrCoreForeground?)
    case status(terminal: String, HerdrCoreTerminalStatus?, records: [String: HerdrCoreTerminalStatus], reported: Bool)
    case turn(terminal: String, turn: Int, state: String?)
    case labels(terminal: String, [String: String])
    case keep(terminal: String, Bool)
    case document(name: String, version: Int, machine: String?)
    case lost(terminal: String, HerdrCoreTerminalEnd)
    case finished(terminal: String, HerdrCoreTerminalEnd)
    case removed(terminal: String)
    /// A kind this app does not know. It says nothing of the kinds this app does
    /// know, so the deltas stay good and no snapshot is needed.
    case unknown(type: String)
    /// The core dropped this subscriber's backlog and sent this instead.
    case missed(HerdrCoreSnapshot)
    case heartbeat(sequence: Int)
    /// The bounded stream shed older events: the consumer resyncs from a snapshot.
    case dropped
}

/// A subscription's sequence belongs to one core process, so each connection
/// gets a fresh cursor from its own subscribe snapshot. `missed` replaces the
/// inventory and sets a new lower bound: buffered older events must not be
/// reapplied after it.
struct HerdrCoreTypedEventCursor {
    private(set) var sequence: Int

    init(snapshot: HerdrCoreSnapshot) {
        sequence = snapshot.sequence
    }

    init(sequence: Int) {
        self.sequence = sequence
    }

    /// One notification line. Nil means nothing for the consumer: a stale
    /// event, a federated terminal or a notification this app does not know.
    mutating func decode(line: Data) throws -> HerdrCoreEvent? {
        let envelope: JSONValue
        do {
            envelope = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            throw TransportError.malformedResponse(String(localized: "herdr-core: Invalid event notification."))
        }
        let method = envelope["method"]?.stringValue
        guard method == "event" || method == "heartbeat" || method == "missed" else { return nil }
        let params = envelope["params"] ?? .null
        guard let next = HerdrCoreWire.integer(params["seq"]), next >= 0 else {
            throw TransportError.malformedResponse(String(localized: "herdr-core: An event has no sequence."))
        }
        // A heartbeat reports the core's current global sequence, not a
        // delivered-event watermark. It can precede events already queued for
        // this subscriber; advancing here would silently discard them.
        if method == "heartbeat" { return .heartbeat(sequence: next) }
        if method == "missed" {
            sequence = next
            return .missed(try HerdrCoreSnapshot(result: params))
        }
        guard next > sequence else { return nil }
        sequence = next
        return try Self.event(from: params)
    }

    private static let terminalKinds: Set<String> = [
        "created", "restarted", "size", "title", "foreground", "status", "turn", "labels", "keep",
        "lost", "finished", "removed",
    ]

    private static func event(from params: JSONValue) throws -> HerdrCoreEvent? {
        guard let type = params["type"]?.stringValue else {
            throw TransportError.malformedResponse(String(localized: "herdr-core: An event has no type."))
        }
        let data = params["data"] ?? .null
        if type == "doc" {
            let document: DocumentData = try HerdrCoreWire.typed(data)
            return .document(
                name: document.name, version: document.version,
                machine: params["machine"]?.stringValue)
        }
        guard let terminal = params["terminal"]?.stringValue, !terminal.isEmpty else {
            // A newer core's kind need not be about one Terminal, as `doc` is not.
            guard terminalKinds.contains(type) else { return .unknown(type: type) }
            throw TransportError.malformedResponse(
                String(localized: "herdr-core: A terminal event has no terminal address."))
        }
        guard !terminal.contains("/") else { return nil }
        switch type {
        case "created": return .created(try HerdrCoreWire.typed(data))
        case "restarted": return .restarted(try HerdrCoreWire.typed(data))
        case "size":
            let size: SizeData = try HerdrCoreWire.typed(data)
            return .size(terminal: terminal, columns: size.cols, rows: size.rows)
        case "title":
            let title: TitleData = try HerdrCoreWire.typed(data)
            return .title(terminal: terminal, title: title.title)
        case "foreground":
            return .foreground(
                terminal: terminal, data == .null ? nil : try HerdrCoreWire.typed(data))
        case "status":
            let status: StatusData = try HerdrCoreWire.typed(data)
            return .status(
                terminal: terminal, status.status, records: status.records ?? [:],
                reported: status.reported ?? false)
        case "turn":
            let turn: TurnData = try HerdrCoreWire.typed(data)
            return .turn(terminal: terminal, turn: turn.turn, state: turn.state)
        case "labels":
            let labels: LabelsData = try HerdrCoreWire.typed(data)
            return .labels(terminal: terminal, labels.labels)
        case "keep":
            let keep: KeepData = try HerdrCoreWire.typed(data)
            return .keep(terminal: terminal, keep.keep)
        case "lost": return .lost(terminal: terminal, try HerdrCoreWire.typed(data))
        case "finished": return .finished(terminal: terminal, try HerdrCoreWire.typed(data))
        case "removed": return .removed(terminal: terminal)
        default: return .unknown(type: type)
        }
    }

    private struct DocumentData: Decodable {
        let name: String
        let version: Int
    }

    private struct SizeData: Decodable {
        let cols: Int
        let rows: Int
    }

    private struct TitleData: Decodable {
        let title: String
    }

    private struct StatusData: Decodable {
        let status: HerdrCoreTerminalStatus?
        let records: [String: HerdrCoreTerminalStatus]?
        let reported: Bool?
    }

    private struct TurnData: Decodable {
        let turn: Int
        let state: String?
    }

    private struct LabelsData: Decodable {
        let labels: [String: String]
    }

    private struct KeepData: Decodable {
        let keep: Bool
    }
}

/// The events channel is a byte stream of newline-terminated JSON, cut at
/// 16 KiB and at the credit edge, so a DATA frame can hold part of a line or
/// several lines.
struct HerdrCoreLineBuffer {
    private let maximumLineBytes: Int
    private var pending = Data()

    init(maximumLineBytes: Int = HerdrCoreFrame.maximumPayload) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// The lines these bytes complete, without their newlines. Blank lines are dropped.
    mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            pending.append(bytes.subdata(in: start..<newline))
            try checkLength()
            if !pending.isEmpty { lines.append(pending) }
            pending = Data()
            start = newline + 1
        }
        pending.append(bytes.subdata(in: start..<bytes.endIndex))
        try checkLength()
        return lines
    }

    private func checkLength() throws {
        guard pending.count <= maximumLineBytes else {
            throw TransportError.malformedResponse(
                String(localized: "herdr-core: An event line exceeds \(maximumLineBytes) bytes."))
        }
    }
}

/// The bytes of an events channel. Real ones are a `HerdrCoreLinkStream`.
protocol HerdrCoreEventBytes: Sendable {
    /// The next bytes, or nil once the channel ended.
    func read() async throws -> Data?
    func close() async
}

/// What `terminal.read` returns. `lines: 0` reads the screen as the core holds
/// it, so a full-screen program is never scrolled to read it.
struct HerdrCoreTerminalRead: Decodable, Equatable, Sendable {
    let text: String
    let complete: Bool
    /// "screen", "history", or "stitched" for a full-screen program scrolled to read it.
    let how: String
}

/// A live subscription: the subscribe snapshot, then what follows it.
///
/// The snapshot is a property, so no flood can shed it. `events` is bounded:
/// its pump keeps reading, and so keeps returning credit, whether or not the
/// consumer does, and marks what it sheds with `.dropped`, after which the
/// consumer resyncs. Ending is explicit: call `end()`.
final class HerdrCoreEventStream: Sendable {
    static let bufferLimit = 256

    let snapshot: HerdrCoreSnapshot
    /// The core of the link this subscription is on, which is the one `snapshot`
    /// lists and the addresses in it mean something to.
    let coreID: String
    /// Finishes without error after `end()` or a server CLOSE, and throws if the link dies.
    let events: AsyncThrowingStream<HerdrCoreEvent, any Error>
    private let source: any HerdrCoreEventBytes
    private let pump: Task<Void, Never>

    init(
        snapshot: HerdrCoreSnapshot, coreID: String, source: any HerdrCoreEventBytes,
        bufferLimit: Int = HerdrCoreEventStream.bufferLimit
    ) {
        self.snapshot = snapshot
        self.coreID = coreID
        self.source = source
        let (events, continuation) = AsyncThrowingStream<HerdrCoreEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferLimit))
        self.events = events
        let pump = Task {
            var cursor = HerdrCoreTypedEventCursor(snapshot: snapshot)
            var lines = HerdrCoreLineBuffer()
            do {
                while let bytes = try await source.read() {
                    for line in try lines.append(bytes) {
                        guard let event = try cursor.decode(line: line) else { continue }
                        if case .dropped = continuation.yield(event) {
                            _ = continuation.yield(.dropped)
                        }
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                await source.close()
                continuation.finish(throwing: error)
            }
        }
        self.pump = pump
        continuation.onTermination = { _ in pump.cancel() }
    }

    /// Closes the events channel. The stream then finishes without error. Idempotent.
    func end() async {
        pump.cancel()
        await source.close()
        await pump.value
    }
}
