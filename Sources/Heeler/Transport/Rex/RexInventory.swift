import Foundation

/// The Rex server a control link reached. Another instance is another server
/// process: what was known of the last one is void (ADR 0048).
struct RexServerStatus: Sendable, Equatable {
    let instanceID: String

    /// Reads `server.status`'s result. Throws `TransportError` when it names
    /// no instance.
    init(reading result: JSONValue) throws {
        guard let instanceID = result["instance_id"]?.stringValue, !instanceID.isEmpty else {
            throw TransportError.rexAnswerUnreadable(String(localized: "Rex's status named no server instance."))
        }
        self.instanceID = instanceID
    }

    init(instanceID: String) {
        self.instanceID = instanceID
    }
}

/// Where a Rex terminal lives: its session and its block. A Pane's id is this
/// address written as one opaque string, so no other code reads Rex's ids
/// apart (ADR 0048).
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

    init(title: String? = nil, program: String? = nil, directory: String? = nil) {
        self.title = title
        self.program = program
        self.directory = directory
    }
}

/// Every terminal a Rex server lists, in Rex's order (ADR 0048). A session
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

        /// The label, unless it is the one Rex gives every new block of its
        /// flavor: the flavor's last name, `shell` (seen on 0.1.0-preview.14).
        var customLabel: String? {
            guard let label, !label.isEmpty else { return nil }
            if let flavor, let short = flavor.split(separator: ".").last, label == short { return nil }
            return label
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
            let digits = id.split(separator: ":").last.map { $0.replacingOccurrences(of: "-", with: "") } ?? ""
            return digits.count >= 8 && label == "Window \(digits.suffix(8))" ? nil : label
        }
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
        return Process(program: text("name"), directory: text("cwd"))
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
