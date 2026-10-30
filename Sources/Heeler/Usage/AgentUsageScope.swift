import Foundation

/// What the Usage tab shows for All Hosts or one Host. Token Usage adds up
/// across Hosts, whose Transcripts are distinct. Usage Limits never do: two
/// Hosts may share an account and the report carries no account identity,
/// so they stay per Host.
struct AgentUsageScope: Equatable {
    /// One Host as the scope reads it.
    struct HostReading: Equatable, Identifiable {
        let id: Host.ID
        let name: String
        let state: AgentUsageStore.State
        var refreshFailure: String? = nil
        var isRetryingRefresh = false
        /// Usage borrows the Console's connection: a Host without one
        /// cannot answer until it reconnects.
        var isConnected = true
    }

    /// A Host whose report the scope adds up.
    struct IncludedHost: Equatable, Identifiable {
        let id: Host.ID
        let name: String
        let report: AgentUsageReport
        let refreshFailure: String?
        let isRetryingRefresh: Bool
        /// Every ok program's 30-day totals on this Host.
        let last30Days: AgentUsageReport.Summary

        var programs: [AgentUsageReport.Program] { report.programs ?? [] }
    }

    /// A Host the scope leaves out, and why.
    struct ExcludedHost: Equatable, Identifiable {
        let id: Host.ID
        let name: String
        let reason: String
    }

    struct Directory: Equatable, Identifiable {
        let hostName: String
        let directory: AgentUsageReport.Directory
        var id: String { "\(hostName)\u{0}\(directory.path)" }
    }

    /// One program's Token Usage across the scope's Hosts.
    struct Program: Equatable, Identifiable {
        let program: String
        let totals: AgentUsageReport.Totals
        /// Days by the date each Host reported, in its own time zone.
        let daily: [AgentUsageReport.Daily]
        let models: [AgentUsageReport.Model]
        let directories: [Directory]
        var id: String { program }
        var displayName: String { AgentUsageReport.Program.displayName(for: program) }
    }

    let included: [IncludedHost]
    let excluded: [ExcludedHost]
    /// Hosts still answering their first read.
    let loading: [HostReading]
    let programs: [Program]

    init(readings: [HostReading]) {
        var included: [IncludedHost] = []
        var excluded: [ExcludedHost] = []
        var loading: [HostReading] = []
        for reading in readings {
            switch reading.state {
            case .available(let report):
                included.append(IncludedHost(
                    id: reading.id, name: reading.name, report: report,
                    refreshFailure: reading.refreshFailure,
                    isRetryingRefresh: reading.isRetryingRefresh,
                    last30Days: Self.sum((report.programs ?? []).compactMap(\.okTotals?.last30Days))))
            case _ where !reading.isConnected:
                excluded.append(ExcludedHost(id: reading.id, name: reading.name, reason: "Not connected"))
            case .idle, .loading:
                loading.append(reading)
            default:
                excluded.append(ExcludedHost(
                    id: reading.id, name: reading.name, reason: Self.reason(for: reading.state)))
            }
        }
        self.included = included
        self.excluded = excluded
        self.loading = loading
        programs = Self.programs(in: included)
    }

    var isEmpty: Bool { included.isEmpty }

    var refreshing: Bool { included.contains { $0.report.refreshing == true } }

    /// The days' time zones, in Host order.
    var timeZones: [String] {
        var zones: [String] = []
        for host in included {
            if let zone = host.report.timeZone, !zones.contains(zone) { zones.append(zone) }
        }
        return zones
    }

    var dayNote: String? {
        let zones = timeZones
        if zones.count > 1 {
            return "Days follow each Host’s time zone (\(zones.joined(separator: ", ")))."
        }
        return zones.first.map { "Days shown in \($0)." }
    }

    /// Every program's totals for a range.
    func total(_ range: AgentUsageRange) -> AgentUsageReport.Summary {
        Self.sum(programs.map { range.summary(in: $0.totals) })
    }

    /// Every program's day, by date.
    func day(_ date: String) -> AgentUsageReport.Summary {
        Self.sum(programs.compactMap { program in
            program.daily.first { $0.date == date }.map(\.summary)
        })
    }

    /// The dates any program reported, oldest first.
    var dates: [String] {
        Array(Set(programs.flatMap { $0.daily.map(\.date) })).sorted()
    }

    /// One Claude Code Account's part of its program for a range.
    struct AccountUsage: Equatable, Identifiable {
        let id: String
        let name: String
        /// nil when its Token Usage could not be read; zero when it has
        /// none recorded yet.
        let summary: AgentUsageReport.Summary?
    }

    /// The readable Accounts that make up `program` for a range, in Account
    /// order, when the scope is one Host with more than one. Accounts belong
    /// to their Host, so a scope of several Hosts keeps program totals only;
    /// the program's own figures already add its Accounts up.
    func accounts(of program: String, range: AgentUsageRange) -> [AccountUsage] {
        guard included.count == 1, let host = included.first,
            let accounts = host.programs.first(where: { $0.program == program })?.accounts
        else { return [] }
        let readable = accounts.filter(\.isReadable)
        guard readable.count > 1 else { return [] }
        return readable.map { account in
            let usage = account.tokenUsage
            let summary: AgentUsageReport.Summary? = switch usage?.state {
            case "ok"?: usage?.totals.map(range.summary(in:))
            case "noData"?: .init(tokens: .zero, estimatedCostUSD: 0, unpricedTokens: 0)
            default: nil
            }
            return AccountUsage(id: account.id, name: account.displayName, summary: summary)
        }
    }

    /// The short line a Host that cannot be added up shows in place of its
    /// figures.
    static func reason(for state: AgentUsageStore.State) -> String {
        switch state {
        case .idle, .loading: "Loading…"
        case .requirement: "Needs the Heeler plugin"
        case .unsupportedPlatform: "Not supported on Windows"
        case .unsupportedBackend: "Not supported on herdr-core"
        case .runtimeMissing: "No Agent activity yet"
        case .updateRequired: "Update Heeler"
        case .failed: "Could not read Usage"
        case .available: ""
        }
    }

    static func sum(_ summaries: [AgentUsageReport.Summary]) -> AgentUsageReport.Summary {
        let priced = summaries.compactMap(\.estimatedCostUSD)
        return AgentUsageReport.Summary(
            tokens: .sum(summaries.map(\.tokens)),
            // Unpriced throughout stays unpriced rather than becoming $0.
            estimatedCostUSD: priced.isEmpty && !summaries.isEmpty ? nil : priced.reduce(0, +),
            unpricedTokens: summaries.reduce(0) { $0 + ($1.unpricedTokens ?? 0) })
    }

    private static func programs(in hosts: [IncludedHost]) -> [Program] {
        var order: [String] = []
        var byProgram: [String: [(String, AgentUsageReport.Program.TokenUsage)]] = [:]
        for host in hosts {
            for program in host.programs where program.okTotals != nil {
                if byProgram[program.program] == nil { order.append(program.program) }
                byProgram[program.program, default: []].append((host.name, program.tokenUsage))
            }
        }
        return order.compactMap { name in
            guard let usages = byProgram[name] else { return nil }
            let totals = usages.compactMap(\.1.totals)
            var days: [String: [AgentUsageReport.Summary]] = [:]
            for (_, usage) in usages {
                for day in usage.daily ?? [] { days[day.date, default: []].append(day.summary) }
            }
            var models: [String: [AgentUsageReport.Model]] = [:]
            var modelOrder: [String] = []
            for (_, usage) in usages {
                for model in usage.models ?? [] {
                    if models[model.model] == nil { modelOrder.append(model.model) }
                    models[model.model, default: []].append(model)
                }
            }
            return Program(
                program: name,
                totals: AgentUsageReport.Totals(
                    today: sum(totals.map(\.today)),
                    last7Days: sum(totals.map(\.last7Days)),
                    last30Days: sum(totals.map(\.last30Days))),
                daily: days.keys.sorted().map { date in
                    let day = sum(days[date] ?? [])
                    return AgentUsageReport.Daily(
                        date: date, tokens: day.tokens, estimatedCostUSD: day.estimatedCostUSD,
                        unpricedTokens: day.unpricedTokens)
                },
                models: modelOrder.compactMap { model in
                    guard let entries = models[model] else { return nil }
                    let summary = sum(entries.map(\.summary))
                    return AgentUsageReport.Model(
                        model: model, priced: entries.allSatisfy(\.priced), tokens: summary.tokens,
                        estimatedCostUSD: summary.estimatedCostUSD,
                        unpricedTokens: summary.unpricedTokens ?? 0)
                }
                .sorted { $0.tokens.total > $1.tokens.total },
                // The same path on two Hosts is two directories.
                directories: usages.flatMap { hostName, usage in
                    (usage.directories ?? []).map { Directory(hostName: hostName, directory: $0) }
                }
                .sorted { $0.directory.tokens.total > $1.directory.tokens.total })
        }
    }
}

extension AgentUsageReport.Tokens {
    static let zero = Self(input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0)

    static func sum(_ tokens: [Self]) -> Self {
        tokens.reduce(.zero) { sum, next in
            Self(input: sum.input + next.input, cacheRead: sum.cacheRead + next.cacheRead,
                cacheWrite: sum.cacheWrite + next.cacheWrite, output: sum.output + next.output,
                reasoning: sum.reasoning + next.reasoning, total: sum.total + next.total)
        }
    }
}

extension AgentUsageReport.Program {
    /// The totals of Token Usage that read ok.
    var okTotals: AgentUsageReport.Totals? {
        tokenUsage.state == "ok" ? tokenUsage.totals : nil
    }
}

extension AgentUsageReport.Daily {
    var summary: AgentUsageReport.Summary {
        .init(tokens: tokens, estimatedCostUSD: estimatedCostUSD, unpricedTokens: unpricedTokens)
    }
}

extension AgentUsageReport.Model {
    var summary: AgentUsageReport.Summary {
        .init(tokens: tokens, estimatedCostUSD: estimatedCostUSD, unpricedTokens: unpricedTokens)
    }
}

extension AgentUsageReport.Directory {
    var summary: AgentUsageReport.Summary {
        .init(tokens: tokens, estimatedCostUSD: estimatedCostUSD, unpricedTokens: unpricedTokens)
    }
}
