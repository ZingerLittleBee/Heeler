import Foundation

/// The Rex server a control link reached: the process that answered, and the
/// server Heeler follows through it. Another instance is another server, and
/// what was known of the last one is void, unless it restored the last one's
/// sessions, as a restarted server does: then it continues the last one's
/// core (ADR 0050).
struct RexServerStatus: Sendable, Equatable {
    /// The server process that answered, new with each start.
    let instanceID: String
    /// Rex's word for the files the server sees, the same for two servers
    /// that share them and nil when it gives none. It means nothing else.
    let hostID: String?
    /// The server whose terminals these are: an instance's own id, or the
    /// core of the last instance when this one restored its sessions.
    private(set) var coreID: String

    /// Reads `server.status`'s result. Throws `TransportError` when it names
    /// no instance.
    init(reading result: JSONValue) throws {
        guard let instanceID = result["instance_id"]?.stringValue, !instanceID.isEmpty else {
            throw TransportError.rexAnswerUnreadable(String(localized: "Rex's status named no server instance."))
        }
        self.instanceID = instanceID
        hostID = result["host_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        coreID = instanceID
    }

    init(instanceID: String, hostID: String? = nil, coreID: String? = nil) {
        self.instanceID = instanceID
        self.hostID = hostID
        self.coreID = coreID ?? instanceID
    }

    /// This instance, as the continuation of `core`.
    func continuing(_ core: String) -> RexServerStatus {
        var status = self
        status.coreID = core
        return status
    }

    /// Whether this status names the server `other` names, whichever
    /// instance of it answered.
    func isSameServer(as other: RexServerStatus) -> Bool {
        coreID == other.coreID
    }
}

/// What this device knows of the last Rex server a Host answered with: its
/// core, the instance and files it last ran as, and the sessions it last
/// listed. A later instance that sees the same files and lists one of those
/// sessions restored them, and continues the core (ADR 0050).
struct RexServerLineage: Codable, Equatable, Sendable {
    var coreID: String
    var instanceID: String
    var hostID: String?
    var sessionIDs: [String]

    init(_ server: RexServerStatus, sessionIDs: [String] = []) {
        coreID = server.coreID
        instanceID = server.instanceID
        hostID = server.hostID
        self.sessionIDs = sessionIDs
    }

    /// Whether `answered`, another instance than the last, may have restored
    /// the last one's sessions, so that its list says which: only one that
    /// sees the same files can, and only a known session can say so.
    func mayContinue(in answered: RexServerStatus) -> Bool {
        guard let hostID, answered.hostID == hostID, !sessionIDs.isEmpty else { return false }
        return true
    }

    /// Whether a list of `listed` session ids holds one of the last ones.
    func isContinued(byListing listed: [String]) -> Bool {
        !Set(listed).isDisjoint(with: sessionIDs)
    }
}

/// The machine a Rex server runs on, as `server.version` names it: its
/// `platform` starts with the system, as `darwin_arm64` did on a Mac (Rex
/// 0.1.0-preview.14, rex-compatibility.md). No Linux value was seen, so one
/// that names `linux` anywhere reads as Linux, one that names `windows` as
/// native Windows, and anything else as unknown.
enum RexServerPlatform {
    /// The kernel as a probe's `uname -s` prints it, or nil.
    static func kernel(reading result: JSONValue) -> String? {
        guard let platform = result["platform"]?.stringValue else { return nil }
        let words = platform.lowercased().split { !$0.isLetter }
        if words.contains("darwin") { return HerdrCoreLocator.macOSKernel }
        if words.contains("linux") { return HerdrCoreLocator.linuxKernel }
        if words.contains("windows") { return HerdrCoreLocator.windowsKernel }
        return nil
    }
}

/// Where a Rex terminal lives: its session and its block. A Pane's id is this
/// address written as one opaque string, so no other code reads Rex's ids
/// apart (ADR 0050).
struct RexPaneAddress: Hashable, Sendable {
    let sessionID: String
    let blockID: String

    init(sessionID: String, blockID: String) {
        self.sessionID = sessionID
        self.blockID = blockID
    }

    /// Each id with `%` and `/` escaped, joined by `/`.
    var paneID: String {
        "\(Self.escaped(sessionID))/\(Self.escaped(blockID))"
    }

    /// The address a Pane id names; nil for an id this type did not write.
    init?(paneID: String) {
        let parts = paneID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let session = Self.unescaped(parts[0]), let block = Self.unescaped(parts[1]),
            !session.isEmpty, !block.isEmpty
        else { return nil }
        sessionID = session
        blockID = block
    }

    private static func escaped(_ id: String) -> String {
        id.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    private static func unescaped(_ part: Substring) -> String? {
        var result = ""
        var rest = part[...]
        while let percent = rest.firstIndex(of: "%") {
            result += rest[..<percent]
            let code = rest[percent...].prefix(3)
            switch code {
            case "%25": result += "%"
            case "%2F": result += "/"
            default: return nil
            }
            rest = rest[rest.index(percent, offsetBy: 3)...]
        }
        return result + rest
    }
}

/// What Heeler shows of a terminal besides its place: kept current by the
/// terminal's own events, and read once per control link.
struct RexTerminalDetails: Sendable, Equatable {
    /// The title the terminal's program set; nil while it set none.
    var title: String?
    /// The foreground program's name.
    var program: String?
    /// The foreground program's working directory.
    var directory: String?
    /// The foreground process's id, its first argument and the script an
    /// interpreter runs: what says which program it is, and whether a Program
    /// Status is its own (ADR 0054).
    var processID: Int?
    var argv0: String?
    var script: String?
    /// The Program Status the terminal's programs last reported without an id,
    /// whichever program it came from; nil for none.
    var status: RexProgramStatus?
    /// Whether nothing has said yet what holds the terminal: this link has
    /// neither read its foreground nor heard it change, and the last link
    /// knew none. Until then it is not known to host an Agent, or to host
    /// none. `RexInventoryBook` says it as it lists the terminal.
    var awaitsForeground = false

    init(
        title: String? = nil, program: String? = nil, directory: String? = nil, processID: Int? = nil,
        argv0: String? = nil, script: String? = nil, status: RexProgramStatus? = nil
    ) {
        self.title = title
        self.program = program
        self.directory = directory
        self.processID = processID
        self.argv0 = argv0
        self.script = script
        self.status = status
    }

    /// The foreground a process read or event named.
    mutating func noteForeground(_ process: RexInventoryWire.Process) {
        program = process.program
        directory = process.directory
        processID = process.processID
        argv0 = process.argv0
        script = process.script
    }
}

/// A terminal's root Program Status as Rex keeps it (ADR 0054): OSC 7501's
/// state and app as the program reported them, the foreground process when
/// the report arrived, and when Rex took it. The control link that holds it
/// adds how it followed the record.
struct RexProgramStatus: Sendable, Equatable {
    let state: String
    /// The record's app, else the app it takes from a parent.
    let app: String?
    let ownerProcessID: Int?
    let ownerName: String?
    /// Rex's `updated_at`. Every report moves it, the same report made again
    /// too, and a read leaves it.
    let updatedAt: String?
    /// How the link that read or heard this record followed it; nil for one
    /// no link holds.
    var follow: RexStatusFollow?

    init(
        state: String, app: String? = nil, ownerProcessID: Int? = nil, ownerName: String? = nil,
        updatedAt: String? = nil, follow: RexStatusFollow? = nil
    ) {
        self.state = state
        self.app = app
        self.ownerProcessID = ownerProcessID
        self.ownerName = ownerName
        self.updatedAt = updatedAt
        self.follow = follow
    }

    /// Whether `other` is this report, whichever link holds it.
    func isSameReport(as other: RexProgramStatus) -> Bool {
        state == other.state && app == other.app && ownerProcessID == other.ownerProcessID
            && ownerName == other.ownerName && updatedAt == other.updatedAt
    }

    /// Whether `other` came from the program that made this one: the same
    /// foreground and the same app.
    func isSameProgram(as other: RexProgramStatus) -> Bool {
        app == other.app && ownerProcessID == other.ownerProcessID && ownerName == other.ownerName
    }
}

/// How one control link followed a terminal's root record (ADR 0054). `id`
/// names a stretch in which the link heard every report, and `finishedTurns`
/// counts the reports in it that took the record from working or blocked to
/// done for the same program, as ADR 0046 counts a tmux Pane's turns. A read
/// that finds another record than the link held starts a new stretch, since
/// what came between is unknown. Rex keeps no such count.
struct RexStatusFollow: Codable, Equatable, Sendable {
    let id: UUID
    var finishedTurns = 0

    init(id: UUID = UUID(), finishedTurns: Int = 0) {
        self.id = id
        self.finishedTurns = finishedTurns
    }
}

/// Every terminal a Rex server lists, in Rex's order (ADR 0050). A session
/// lists its windows in order, each window its terminals in reading order:
/// the tiled layout first, then the floating layers. Terminals that belong to
/// a session but to none of its windows are its detached ones. Blocks that
/// are not terminals are left out, and so is a session with no terminal.
struct RexInventory: Sendable, Equatable {
    struct Session: Sendable, Equatable {
        let id: String
        var label: String
        var activeWindowID: String?
        var windows: [Window]
        var detached: [Terminal]

        var terminals: [Terminal] { windows.flatMap(\.terminals) + detached }
    }

    struct Window: Sendable, Equatable {
        let id: String
        /// Nil when the window carries the label Rex gives every new window.
        var label: String?
        var terminals: [Terminal]
    }

    struct Terminal: Sendable, Equatable {
        let blockID: String
        /// Nil when the block carries the label Rex gives every new block.
        var label: String?
        /// The client that owns the block, when one does.
        var owner: String?
        var details: RexTerminalDetails
    }

    var sessions: [Session]

    init(sessions: [Session] = []) {
        self.sessions = sessions
    }

    /// Every terminal's details by address.
    var details: [RexPaneAddress: RexTerminalDetails] {
        var details: [RexPaneAddress: RexTerminalDetails] = [:]
        for session in sessions {
            for terminal in session.terminals {
                details[RexPaneAddress(sessionID: session.id, blockID: terminal.blockID)] = terminal.details
            }
        }
        return details
    }

    /// Each terminal's root Program Status by address; one with none is left out.
    var programStatuses: [RexPaneAddress: RexProgramStatus] {
        details.compactMapValues(\.status)
    }

    /// The same sessions, windows and terminals with no details, so two
    /// inventories that differ only in titles, programs or directories compare equal.
    var withoutDetails: RexInventory {
        var stripped = self
        for index in stripped.sessions.indices {
            for window in stripped.sessions[index].windows.indices {
                for terminal in stripped.sessions[index].windows[window].terminals.indices {
                    stripped.sessions[index].windows[window].terminals[terminal].details = RexTerminalDetails()
                }
            }
            for terminal in stripped.sessions[index].detached.indices {
                stripped.sessions[index].detached[terminal].details = RexTerminalDetails()
            }
        }
        return stripped
    }
}

/// Reads the inventory's answers and events off the control link. Anything a
/// field lacks reads as absent; an answer missing what identifies it reads as
/// nil, so the caller can tell it apart from an empty one.
enum RexInventoryWire {
    /// What creates terminal blocks, and names their methods and events.
    static let terminalCreator = "com.superlogical.terminal"

    static func terminalMethod(_ name: String) -> String { "\(terminalCreator).\(name)" }

    struct SessionEntry: Sendable, Equatable {
        let id: String
        let label: String
    }

    /// One block as a view or a listing names it.
    struct BlockFacts: Sendable, Equatable {
        let id: String
        let label: String?
        let creatorName: String?
        let flavor: String?
        let owner: String?

        var isTerminal: Bool {
            creatorName == RexInventoryWire.terminalCreator
                || (creatorName == nil && flavor?.hasPrefix("\(RexInventoryWire.terminalCreator).") == true)
        }

        /// The label, unless it is one Rex gives a block it was not named: the
        /// flavor's last name, `shell`, for a new block, and `Block` and the
        /// last eight hex digits of its id for one whose label was cleared
        /// (both seen on 0.1.0-preview.14).
        var customLabel: String? {
            guard let label, !label.isEmpty else { return nil }
            if let flavor, let short = flavor.split(separator: ".").last, label == short { return nil }
            return RexInventoryWire.isDefaultLabel(label, prefix: "Block", id: id) ? nil : label
        }
    }

    struct ViewWindow: Sendable, Equatable {
        let id: String
        let label: String?
        /// The window's blocks in reading order.
        let blocks: [BlockFacts]

        /// The label, unless it is the one Rex gives every new window: `Window`
        /// and the last eight hex digits of its id (seen on 0.1.0-preview.14).
        var customLabel: String? {
            guard let label, !label.isEmpty else { return nil }
            return RexInventoryWire.isDefaultLabel(label, prefix: "Window", id: id) ? nil : label
        }
    }

    /// Whether `label` is `prefix` and the last eight hex digits of `id`, its
    /// part after the last colon with dashes removed: the label Rex makes
    /// from an id.
    static func isDefaultLabel(_ label: String, prefix: String, id: String) -> Bool {
        let digits = id.split(separator: ":").last.map { $0.replacingOccurrences(of: "-", with: "") } ?? ""
        return digits.count >= 8 && label == "\(prefix) \(digits.suffix(8))"
    }

    struct View: Sendable, Equatable {
        let revision: Int
        let label: String?
        let activeWindowID: String?
        let windows: [ViewWindow]
    }

    struct ListedBlock: Sendable, Equatable {
        let facts: BlockFacts
        /// The window a placed block is in.
        let windowID: String?
    }

    struct Process: Sendable, Equatable {
        let program: String?
        let directory: String?
        let processID: Int?
        let argv0: String?
        let script: String?

        init(
            program: String?, directory: String?, processID: Int? = nil, argv0: String? = nil,
            script: String? = nil
        ) {
            self.program = program
            self.directory = directory
            self.processID = processID
            self.argv0 = argv0
            self.script = script
        }
    }

    /// `session.attach_all`'s sessions, in the server's order.
    static func sessions(_ result: JSONValue) -> [SessionEntry]? {
        guard case .array(let entries)? = result["sessions"] else { return nil }
        return entries.compactMap { entry in
            entry["session_id"]?.stringValue.map { SessionEntry(id: $0, label: entry["label"]?.stringValue ?? "") }
        }
    }

    /// `session.view`'s windows, each with its blocks in reading order.
    static func view(_ result: JSONValue) -> View? {
        guard let revision = result["revision"]?.rexWholeNumber, case .array(let windows)? = result["windows"] else {
            return nil
        }
        return View(
            revision: revision, label: result["label"]?.stringValue,
            activeWindowID: result["active_window_id"]?.stringValue,
            windows: windows.compactMap(window))
    }

    /// `session.list_blocks`'s blocks, placed and detached, in its order.
    static func blocks(_ result: JSONValue) -> [ListedBlock]? {
        guard case .array(let blocks)? = result["blocks"] else { return nil }
        return blocks.compactMap { block in
            facts(block).map { facts in
                // A placement this build does not know reads as detached.
                let placed = block["placement"]?.stringValue == "placed"
                return ListedBlock(facts: facts, windowID: placed ? block["window_id"]?.stringValue : nil)
            }
        }
    }

    /// A terminal's title, from its title method or its title event. Empty
    /// reads as none.
    static func title(_ result: JSONValue?) -> String? {
        guard let title = result?["title"]?.stringValue, !title.isEmpty else { return nil }
        return title
    }

    /// A terminal's foreground program, from its process method or its
    /// process event. No foreground reads as no program and no directory.
    static func process(_ result: JSONValue?) -> Process {
        let foreground = result?["foreground"]
        func text(_ key: String) -> String? {
            foreground?[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        return Process(
            program: text("name"), directory: text("cwd"), processID: foreground?["pid"]?.rexWholeNumber,
            argv0: text("argv0"), script: text("script"))
    }

    /// The root record of a terminal's `program_status` answer, the one with
    /// no id; nil when it has none. Child records are a program's subtasks.
    static func rootStatus(_ result: JSONValue?) -> RexProgramStatus? {
        guard case .array(let records)? = result?["records"] else { return nil }
        return records.first { isRoot($0["id"]) }.flatMap(status)
    }

    /// Whether a `program_status_changed` event changed the root record.
    static func changesRootStatus(_ payload: JSONValue?) -> Bool {
        isRoot(payload?["id"])
    }

    /// The record a `program_status_changed` event carries.
    static func changedStatus(_ payload: JSONValue?) -> RexProgramStatus? {
        status(payload?["record"])
    }

    /// Whether a `program_status_removed` event removed the root record.
    static func removesRootStatus(_ payload: JSONValue?) -> Bool {
        guard case .array(let ids)? = payload?["ids"] else { return false }
        return ids.contains { $0.stringValue == "" }
    }

    /// A record's id, absent or empty for the root.
    private static func isRoot(_ id: JSONValue?) -> Bool {
        guard let id, id != .null else { return true }
        return id.stringValue == ""
    }

    private static func status(_ record: JSONValue?) -> RexProgramStatus? {
        guard let record, let state = record["state"]?.stringValue, !state.isEmpty else { return nil }
        func text(_ value: JSONValue?) -> String? {
            value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        let owner = record["owner"]
        let app = text(record["app"]) ?? text(record["effective_app"])
        return RexProgramStatus(
            state: turnState(state, app: app, message: text(record["msg"])), app: app,
            ownerProcessID: owner?["pid"]?.rexWholeNumber, ownerName: text(owner?["name"]),
            updatedAt: text(record["updated_at"]))
    }

    /// A record's state as Heeler reads it. Claude Code keeps its record at
    /// `working` once a turn has ended while commands it put in the
    /// background still run, and says how many in `msg`, where a running turn
    /// says what it is doing: "1 shell still running" (2.1.327, live). The
    /// turn is over then. Claude Code sits at its prompt, takes the next one,
    /// and has nothing for Esc to interrupt, so that record reads `done`, as
    /// the end of its turn does on the other Server Kinds, for everything
    /// that reads the state: Agent Status, Done per device, and the Composer,
    /// which offers Send. Any other wording leaves the state as reported.
    private static func turnState(_ reported: String, app: String?, message: String?) -> String {
        guard reported == "working", app?.lowercased() == "claude-code", let words = message?.split(separator: " "),
            words.count >= 4, words.suffix(2).elementsEqual(["still", "running"]),
            let count = words.first, count.allSatisfy(\.isASCII), count.allSatisfy(\.isNumber)
        else { return reported }
        return "done"
    }

    private static func window(_ value: JSONValue) -> ViewWindow? {
        guard let id = value["window_id"]?.stringValue else { return nil }
        guard case .array(let layers)? = value["layers"] else {
            return ViewWindow(id: id, label: value["label"]?.stringValue, blocks: [])
        }
        // The tiled layout reads first, then each floating layer as listed.
        let ordered =
            layers.filter { $0["kind"]?.stringValue != "floating" }
            + layers.filter { $0["kind"]?.stringValue == "floating" }
        var blocks: [BlockFacts] = []
        var seen: Set<String> = []
        for layer in ordered {
            guard case .array(let listed)? = layer["blocks"] else { continue }
            let byID = Dictionary(listed.compactMap { facts($0).map { ($0.id, $0) } }) { first, _ in first }
            var order: [String] = []
            collect(layer["layout"], into: &order)
            // A block the layer lists but its layout does not place still shows.
            order += listed.compactMap { $0["block_id"]?.stringValue }
            for blockID in order {
                guard let block = byID[blockID], seen.insert(blockID).inserted else { continue }
                blocks.append(block)
            }
        }
        return ViewWindow(id: id, label: value["label"]?.stringValue, blocks: blocks)
    }

    /// A layout tree's blocks, the part before each split ahead of the part after.
    private static func collect(_ node: JSONValue?, into order: inout [String]) {
        guard let node else { return }
        if let blockID = node["block_id"]?.stringValue {
            order.append(blockID)
        } else if let split = node["split"] {
            collect(split["before"], into: &order)
            collect(split["after"], into: &order)
        }
    }

    private static func facts(_ block: JSONValue) -> BlockFacts? {
        guard let id = block["block_id"]?.stringValue else { return nil }
        return BlockFacts(
            id: id, label: block["label"]?.stringValue, creatorName: block["creator_name"]?.stringValue,
            flavor: block["flavor"]?.stringValue, owner: block["owner"]?.stringValue)
    }
}

extension JSONValue {
    /// A whole number that fits an `Int`.
    fileprivate var rexWholeNumber: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int(value)
    }
}
