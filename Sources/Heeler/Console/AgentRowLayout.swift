import Foundation

/// Names in sidebar.json. Custom names are stored without `$` in the enum
/// and retain the prefix when encoded; Agent metadata keys have no prefix.
enum AgentRowToken: RawRepresentable, Codable, Hashable, Sendable {
    case stateIcon, stateText, workspace, tab, pane, agent
    case terminalTitle, terminalTitleStripped
    case custom(String)

    static let builtins: [Self] = [
        .stateIcon, .stateText, .workspace, .tab, .pane, .agent,
        .terminalTitle, .terminalTitleStripped,
    ]

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
struct AgentRowLayout: Codable, Equatable, Sendable {
    static let maximumRows = 16
    static let maximumTokensPerRow = 16
    static let heelerDefault = AgentRowLayout(rows: [
        [.init(.stateIcon), .init(.workspace), .init(.tab)], [.init(.agent)],
    ])

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
