import Foundation

/// Field names. herdr sidebar.json builtins and `$custom` plugin keys, plus
/// Heeler-only names (`host`, `status`, `directory`) that exist in the app
/// layout, not as authored plugin fields.
///
/// `state_icon` still parses so herdr snapshots and older saved layouts keep
/// decoding, but Console layouts drop it (`normalizedForConsole`) and the
/// Field Editor never offers it: the status badge at the end of Row 1 owns it.
enum AgentRowToken: RawRepresentable, Codable, Hashable, Sendable {
    case stateIcon, stateText, workspace, tab, pane, agent
    case terminalTitle, terminalTitleStripped
    case host, status, directory
    case custom(String)

    /// herdr fields the Field Editor offers. Excludes `state_icon`.
    static let herdrBuiltins: [Self] = [
        .stateText, .workspace, .tab, .pane, .agent,
        .terminalTitle, .terminalTitleStripped,
    ]

    static let heelerBuiltins: [Self] = [
        .host, .status, .directory,
    ]

    static let builtins: [Self] = herdrBuiltins + heelerBuiltins

    init?(rawValue: String) {
        switch rawValue {
        case "state_icon": self = .stateIcon
        case "state_text": self = .stateText
        case "workspace": self = .workspace
        case "tab": self = .tab
        case "pane": self = .pane
        case "agent": self = .agent
        case "terminal_title": self = .terminalTitle
        case "terminal_title_stripped": self = .terminalTitleStripped
        case "host": self = .host
        case "status": self = .status
        case "directory": self = .directory
        default:
            guard rawValue.first == "$" else { return nil }
            let name = rawValue.dropFirst()
            guard (1...32).contains(name.utf8.count), name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 95 || $0 == 45
            }) else { return nil }
            self = .custom(String(name))
        }
    }

    var rawValue: String {
        switch self {
        case .stateIcon: "state_icon"
        case .stateText: "state_text"
        case .workspace: "workspace"
        case .tab: "tab"
        case .pane: "pane"
        case .agent: "agent"
        case .terminalTitle: "terminal_title"
        case .terminalTitleStripped: "terminal_title_stripped"
        case .host: "host"
        case .status: "status"
        case .directory: "directory"
        case .custom(let name): "$\(name)"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let token = Self(rawValue: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown row token")
        }
        self = token
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A validated sRGB color, independent of SwiftUI/UIKit. Only #RGB and
/// #RRGGBB are accepted. Keep the original spelling for snapshot consumers.
struct HexColor: Codable, Hashable, Sendable {
    let rawValue: String
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init?(_ value: String) {
        guard value.first == "#", value.utf8.count == 4 || value.utf8.count == 7 else { return nil }
        let digits = value.dropFirst()
        guard digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
        guard let rgb = UInt32(expanded, radix: 16) else { return nil }
        rawValue = value
        red = UInt8((rgb >> 16) & 0xff)
        green = UInt8((rgb >> 8) & 0xff)
        blue = UInt8(rgb & 0xff)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let color = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid hex color")
        }
        self = color
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AgentRowStyledToken: Codable, Equatable, Sendable {
    var token: AgentRowToken
    var fg: HexColor?
    var bold: Bool?
    var dim: Bool?

    init(_ token: AgentRowToken, fg: HexColor? = nil, bold: Bool? = nil, dim: Bool? = nil) {
        self.token = token
        self.fg = fg
        self.bold = bold
        self.dim = dim
    }
}

typealias AgentRow = [AgentRowStyledToken]

enum AgentRowLayoutError: Error, Equatable {
    case tooManyRows, tooManyTokens, invalidRowGap, invalidToken
}

/// One complete choice of rows, including per-kind replacements. Row gap is
/// the gap between Agent entries, never between rows within an entry.
///
/// `maximumRows` bounds what the wire and the persisted catalog accept, so
/// herdr snapshots and older saves still decode. The Console itself shows
/// three fixed row slots (`AgentRowSlot`); `normalizedForConsole` reduces any
/// layout to that shape.
struct AgentRowLayout: Codable, Equatable, Sendable {
    static let maximumRows = 16
    static let maximumTokensPerRow = 16
    /// Console row slots: Row 1 and Row 2 follow herdr, Row 3 is Heeler's.
    static let maximumConsoleRows = 3
    /// Heeler's default sidebar rows, used when a Host has no snapshot.
    /// Pane title leads Row 2 when present; Agent name remains alongside it.
    /// Still carries `state_icon`; the Console never does.
    static let heelerDefault = AgentRowLayout(rows: [
        [.init(.stateIcon), .init(.workspace), .init(.tab)],
        [.init(.pane), .init(.agent)],
    ])
    /// Fallback sidebar fields with Heeler's default directory row.
    static let consoleDefault = heelerDefault.withHeelerRow()

    var rowGap: Int
    var rows: [AgentRow]
    var rowsByAgent: [String: [AgentRow]]

    init(rows: [AgentRow], rowGap: Int = 0, rowsByAgent: [String: [AgentRow]] = [:]) {
        self.rows = rows
        self.rowGap = rowGap
        self.rowsByAgent = rowsByAgent
    }

    func rows(forAgentKind kind: String) -> [AgentRow] {
        rowsByAgent[kind] ?? rows
    }

    /// The Console shape: at most `maximumConsoleRows` rows, no `state_icon`
    /// (the status badge at the end of Row 1 owns it), and no per-kind
    /// overrides: every Agent on a Host shares the same rows, so herdr's
    /// `rows_by_agent` is decoded but never applied. Row gap and every other
    /// field style stay as they are.
    func normalizedForConsole() -> AgentRowLayout {
        AgentRowLayout(
            rows: rows.prefix(Self.maximumConsoleRows).map { row in
                row.filter { $0.token != .stateIcon }
            },
            rowGap: rowGap)
    }

    /// Import only herdr's first two rows. The third belongs to Heeler;
    /// new layouts show the directory, while sync supplies the user's row.
    func withHeelerRow(_ thirdRow: AgentRow = [.init(.directory)]) -> AgentRowLayout {
        var imported = normalizedForConsole()
        imported.rows = Array(AgentRowSlot.slotRows(imported.rows).prefix(AgentRowSlot.herdrRowCount))
            + [thirdRow]
        return imported
    }

    /// Console layouts hold at most `maximumConsoleRows` rows.
    func validateForConsole() throws {
        guard rows.count <= Self.maximumConsoleRows else {
            throw AgentRowLayoutError.tooManyRows
        }
    }

    func validate() throws {
        guard (0...65535).contains(rowGap) else { throw AgentRowLayoutError.invalidRowGap }
        for layoutRows in [rows] + Array(rowsByAgent.values) {
            guard layoutRows.count <= Self.maximumRows else { throw AgentRowLayoutError.tooManyRows }
            for row in layoutRows {
                guard row.count <= Self.maximumTokensPerRow else { throw AgentRowLayoutError.tooManyTokens }
                guard row.allSatisfy({ AgentRowToken(rawValue: $0.token.rawValue) != nil }) else {
                    throw AgentRowLayoutError.invalidToken
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rowGap = "row_gap"
        case rows
        case rowsByAgent = "rows_by_agent"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowGap = try container.decodeIfPresent(Int.self, forKey: .rowGap) ?? 0
        rows = try container.decodeIfPresent([AgentRow].self, forKey: .rows) ?? Self.heelerDefault.rows
        rowsByAgent = try container.decodeIfPresent([String: [AgentRow]].self, forKey: .rowsByAgent) ?? [:]
        try validate()
    }
}

/// Which of the three Console row slots a row index names. Rows 1 and 2
/// start from herdr's sidebar fields, which Sync from plugin refills; Row 3
/// is Heeler's own row. Every slot accepts herdr and Heeler fields alike.
enum AgentRowSlot: Equatable, Sendable {
    case herdr, heeler

    static let herdrRowCount = 2

    /// nil outside the Console's row slots.
    static func forRow(_ index: Int) -> AgentRowSlot? {
        guard (0..<AgentRowLayout.maximumConsoleRows).contains(index) else { return nil }
        return index < herdrRowCount ? .herdr : .heeler
    }

    /// Provenance label shown beside the row title.
    var label: String {
        switch self {
        case .herdr: "herdr"
        case .heeler: "Heeler"
        }
    }

    /// `rows` padded with empty rows to the Console's slot count.
    static func slotRows(_ rows: [AgentRow]) -> [AgentRow] {
        rows + Array(repeating: [], count: max(0, AgentRowLayout.maximumConsoleRows - rows.count))
    }
}

/// Sort is independent of ConsoleListPresentationMode's flat/by-Host axis.
enum AgentPanelSort: String, Codable, Sendable {
    case priority, spaces

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let sort = Self(rawValue: raw == "workspaces" ? "spaces" : raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Agent panel sort")
        }
        self = sort
    }
}

/// Read-only normalized plugin snapshot. Unknown token names are removed
/// individually; malformed structure or an unsupported version is absent.
/// Local persisted layouts use stricter Codable decoding to protect edits.
struct AgentRowLayoutSnapshot: Equatable, Sendable {
    let layout: AgentRowLayout
    let agentPanelSort: AgentPanelSort
    let diagnostics: [String]

    init(layout: AgentRowLayout, agentPanelSort: AgentPanelSort = .spaces, diagnostics: [String] = []) {
        self.layout = layout
        self.agentPanelSort = agentPanelSort
        self.diagnostics = diagnostics
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data,
            let snapshot = try? JSONDecoder().decode(WireSnapshot.self, from: data),
            snapshot.v == 1,
            let layout = try? (snapshot.sidebar?.agents?.layout() ?? AgentRowLayout.heelerDefault)
        else { return nil }
        return Self(
            layout: layout, agentPanelSort: snapshot.agentPanelSort ?? .spaces,
            diagnostics: snapshot.diagnostics ?? [])
    }

    private struct WireSnapshot: Decodable {
        let v: Int
        let agentPanelSort: AgentPanelSort?
        let sidebar: Sidebar?
        let diagnostics: [String]?

        enum CodingKeys: String, CodingKey {
            case v, sidebar, diagnostics
            case agentPanelSort = "agent_panel_sort"
        }
    }

    private struct Sidebar: Decodable {
        let agents: WireLayout?
    }

    private struct WireLayout: Decodable {
        let rowGap: Int?
        let rows: [[WireToken]]?
        let rowsByAgent: [String: [[WireToken]]]?

        enum CodingKeys: String, CodingKey {
            case rowGap = "row_gap"
            case rows
            case rowsByAgent = "rows_by_agent"
        }

        func layout() throws -> AgentRowLayout {
            func convert(_ rows: [[WireToken]]) throws -> [AgentRow] {
                guard rows.count <= AgentRowLayout.maximumRows else { throw AgentRowLayoutError.tooManyRows }
                return try rows.map { row in
                    guard row.count <= AgentRowLayout.maximumTokensPerRow else {
                        throw AgentRowLayoutError.tooManyTokens
                    }
                    return row.compactMap { value in
                        AgentRowToken(rawValue: value.token).map {
                            AgentRowStyledToken(
                                $0, fg: value.fg.flatMap(HexColor.init), bold: value.bold, dim: value.dim)
                        }
                    }
                }
            }
            let layout = AgentRowLayout(
                rows: try rows.map(convert) ?? AgentRowLayout.heelerDefault.rows,
                rowGap: rowGap ?? 0,
                rowsByAgent: try (rowsByAgent ?? [:]).mapValues(convert))
            try layout.validate()
            return layout
        }
    }

    private struct WireToken: Decodable {
        let token: String
        let fg: String?
        let bold: Bool?
        let dim: Bool?
    }
}
