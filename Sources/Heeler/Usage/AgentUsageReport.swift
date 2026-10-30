import Foundation

/// The plugin's small `usage` v1 response. Unknown fields are deliberately
/// ignored so newer plugins can add data without breaking older apps.
struct AgentUsageReport: Decodable, Equatable, Sendable {
    struct Scan: Decodable, Equatable, Sendable {
        let state: String
        let coveredFrom: String?
        let coveredThrough: String?
        let skippedArchives: Int
        /// Transcripts or folders the last run could not read; the plugin
        /// retries them. Optional so a report without the count still decodes.
        let unreadableFiles: Int?
    }

    struct Tokens: Decodable, Equatable, Sendable {
        let input: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let output: Int64
        /// Informative only: already included in output for programs that report it.
        let reasoning: Int64
        let total: Int64
    }

    struct Summary: Decodable, Equatable, Sendable {
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64?
    }

    struct Totals: Decodable, Equatable, Sendable {
        let today: Summary
        let last7Days: Summary
        let last30Days: Summary
    }

    struct Daily: Decodable, Equatable, Sendable {
        let date: String
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64?
    }

    struct Model: Decodable, Equatable, Sendable {
        let model: String
        let priced: Bool
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64
    }

    struct Directory: Decodable, Equatable, Sendable {
        let path: String
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64
    }

    struct Program: Decodable, Equatable, Sendable {
        struct TokenUsage: Decodable, Equatable, Sendable {
            let state: String
            let reason: String?
            let totals: Totals?
            let daily: [Daily]?
            let models: [Model]?
            let directories: [Directory]?
        }
        struct UsageLimits: Decodable, Equatable, Sendable {
            struct Window: Decodable, Equatable, Sendable, Identifiable {
                let id: String
                let label: String?
                let durationMinutes: Int?
                let usedPercent: Double?
                let resetsAt: String?
                let expired: Bool
            }

            let state: String
            let reason: String?
            let source: String?
            let observedAt: String?
            let retryAt: String?
            let plan: String?
            let windows: [Window]?
        }
        let program: String
        let tokenUsage: TokenUsage
        var usageLimits: UsageLimits
        /// Claude Code's Accounts, the Default Account first and the rest in
        /// the Account file's order (plugin 0.8.0 and later). The program's
        /// own `tokenUsage` already adds up the `ok` ones, and its
        /// `usageLimits` are the Default Account's. nil from older plugins
        /// and for other programs.
        var accounts: [Account]?
        /// Directories that look like a Claude Code Account, none counted
        /// until the user adds it. nil where `accounts` is.
        let accountSuggestions: [AccountSuggestion]?

        var displayName: String { Self.displayName(for: program) }

        /// A program a newer plugin adds keeps its own id rather than
        /// borrowing a known program's name.
        static func displayName(for program: String) -> String {
            switch program {
            case "claude": "Claude Code"
            case "codex": "Codex"
            default: program
            }
        }
    }

    /// One Claude Code config directory the plugin reads usage from
    /// (ADR 0030). Only `ok` Accounts carry figures.
    struct Account: Decodable, Equatable, Sendable, Identifiable {
        enum State: Equatable, Sendable {
            case ok
            /// Its directory does not exist or is not a directory.
            case missing
            /// Its real path is one another Account already counts.
            case duplicate
            /// After three counted Accounts, in a hand-edited file.
            case overLimit
            /// A state a newer plugin reports; counted as not readable.
            case other(String)

            init(_ value: String) {
                switch value {
                case "ok": self = .ok
                case "missing": self = .missing
                case "duplicate": self = .duplicate
                case "overLimit": self = .overLimit
                default: self = .other(value)
                }
            }
        }

        /// `default` for the Default Account; otherwise the Account file's id.
        let id: String
        let isDefault: Bool
        /// nil only for the Default Account without a name of its own.
        let name: String?
        /// As chosen, not resolved; the Default Account's first root.
        let directory: String
        let state: State
        let tokenUsage: Program.TokenUsage?
        var usageLimits: Program.UsageLimits?

        /// The app's own label for a Default Account without a name.
        static let defaultDisplayName = "Default"

        var displayName: String { name ?? Self.defaultDisplayName }

        /// Whether its Transcripts and Usage Limits count.
        var isReadable: Bool { state == .ok }

        private enum CodingKeys: String, CodingKey {
            case id, isDefault, name, directory, state, tokenUsage, usageLimits
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            name = try container.decodeIfPresent(String.self, forKey: .name)
            directory = try container.decode(String.self, forKey: .directory)
            state = State(try container.decode(String.self, forKey: .state))
            tokenUsage = try container.decodeIfPresent(Program.TokenUsage.self, forKey: .tokenUsage)
            usageLimits = try container.decodeIfPresent(Program.UsageLimits.self, forKey: .usageLimits)
        }
    }

    /// A directory the plugin offers as an Account: from a running Agent's
    /// environment or the home folder listing.
    struct AccountSuggestion: Decodable, Equatable, Sendable, Identifiable {
        enum Source: Equatable, Sendable {
            /// `CLAUDE_CONFIG_DIR` of a running Claude Code Agent.
            case agent
            /// A `.claude*` directory in the home or config folder.
            case home
            /// A source a newer plugin reports.
            case other(String)

            init(_ value: String) {
                switch value {
                case "agent": self = .agent
                case "home": self = .home
                default: self = .other(value)
                }
            }
        }

        let directory: String
        /// Its base name without the leading dot.
        let name: String
        let source: Source

        var id: String { directory }

        private enum CodingKeys: String, CodingKey {
            case directory, name, source
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            directory = try container.decode(String.self, forKey: .directory)
            name = try container.decode(String.self, forKey: .name)
            source = Source(try container.decodeIfPresent(String.self, forKey: .source) ?? "")
        }

        init(directory: String, name: String, source: Source) {
            self.directory = directory
            self.name = name
            self.source = source
        }
    }

    let version: Int
    let runtime: String
    let generatedAt: String?
    let timeZone: String?
    let refreshing: Bool?
    let pricingVersion: String?
    let scan: Scan?
    var programs: [Program]?

    /// Claude Code's entry, when the report has one.
    var claudeProgram: Program? { programs?.first { $0.program == "claude" } }

    /// A device that opted out must never show a reading cached by another query.
    func hidingClaudeLimits() -> Self {
        replacingClaudeLimits(state: "disabled", reason: nil)
    }

    /// Right after the toggle turns on, this report's query did not ask for
    /// Claude Code limits; they read as not read yet, not as off.
    func readingClaudeLimits() -> Self {
        replacingClaudeLimits(state: "unavailable", reason: "notReadYet")
    }

    /// The query that would have read Claude Code limits after the toggle
    /// turned on failed; they read as failed, not as still being read.
    func failedClaudeLimits() -> Self {
        replacingClaudeLimits(state: "error", reason: "requestFailed")
    }

    /// Every Account's limits follow the program's: the toggle covers them
    /// all. An Account without limits (not `ok`) keeps none.
    private func replacingClaudeLimits(state: String, reason: String?) -> Self {
        let limits = Program.UsageLimits(state: state, reason: reason, source: nil,
            observedAt: nil, retryAt: nil, plan: nil, windows: nil)
        var report = self
        report.programs = programs?.map { program in
            guard program.program == "claude" else { return program }
            var replaced = program
            replaced.usageLimits = limits
            replaced.accounts = program.accounts?.map { account in
                guard account.isReadable || account.usageLimits != nil else { return account }
                var replaced = account
                replaced.usageLimits = limits
                return replaced
            }
            return replaced
        }
        return report
    }

    static func decode(_ data: Data) throws -> Self {
        // Check the envelope before interpreting any version-specific fields.
        struct Envelope: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard try decoder.decode(Envelope.self, from: data).version == 1 else {
            throw AgentUsageError.unsupportedVersion
        }
        let report = try decoder.decode(Self.self, from: data)
        guard report.runtime == "missing" || (
            report.runtime == "recorded" && report.generatedAt != nil
                && report.timeZone != nil && report.refreshing != nil
                && report.scan != nil && report.programs != nil)
        else { throw AgentUsageError.invalidReport }
        return report
    }
}

/// The plugin's `YYYY-MM-DD` days are already folded into the report's time
/// zone, so they are parsed and formatted in UTC and never shift a second
/// time on a phone in another zone.
enum AgentUsageCalendarDay {
    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let dayOfMonth = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// The day in the reader's locale and calendar, or the plugin's text
    /// when it is not a date.
    static func text(
        _ day: String, locale: Locale, calendar: Calendar, includesYear: Bool, includesWeekday: Bool = false
    ) -> String {
        guard let date = date(day) else { return day }
        var calendar = calendar
        calendar.timeZone = .gmt
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).month(.abbreviated).day()
        if includesYear { style = style.year() }
        if includesWeekday { style = style.weekday(.abbreviated) }
        return date.formatted(style)
    }
}

enum AgentUsageError: Error, Equatable {
    case unsupportedVersion
    case invalidReport
}
