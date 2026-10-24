import Foundation

/// The plugin's small `usage` v1 response. Unknown fields are deliberately
/// ignored so newer plugins can add data without breaking older apps.
struct AgentUsageReport: Decodable, Equatable, Sendable {
    struct Scan: Decodable, Equatable, Sendable {
        let state: String
        let coveredFrom: String?
        let coveredThrough: String?
        let skippedArchives: Int
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
    }

    let version: Int
    let runtime: String
    let generatedAt: String?
    let timeZone: String?
    let refreshing: Bool?
    let pricingVersion: String?
    let scan: Scan?
    var programs: [Program]?

    /// A device that opted out must never show a reading cached by another query.
    func hidingClaudeLimits() -> Self {
        var report = self
        report.programs = programs?.map { program in
            guard program.program == "claude" else { return program }
            var hidden = program
            hidden.usageLimits = .init(state: "disabled", reason: nil, source: nil,
                observedAt: nil, retryAt: nil, plan: nil, windows: nil)
            return hidden
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

enum AgentUsageError: Error, Equatable {
    case unsupportedVersion
    case invalidReport
}
