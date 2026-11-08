import Foundation

/// Why a core Agent reads Unknown, from what its Terminal reported and never from
/// its screen (ADR 0034).
struct HerdrCoreStatusExplanation: Equatable, Sendable {
    let text: String
    /// Grok Build's automatic check left Program Status off, so the one edit that
    /// turns it on is worth offering (ADR 0033).
    let offersGrokBuildEdit: Bool
    /// The process whose environment says where its program keeps its configuration.
    let agentProcess: Int?

    /// The first release of each program that reports a Program Status, from
    /// herdr compatibility's notes. Grok Build's is not known.
    private static let firstReportingReleases = [
        "claude": (program: "Claude Code", release: "2.1.295"),
        "codex": (program: "Codex", release: "0.163"),
        "opencode": (program: "OpenCode", release: "2.1"),
        "pi": (program: "Pi", release: "1.1.0"),
        "omp": (program: "Oh My Pi", release: "18.8.7"),
    ]

    /// Nil unless the record holds an Agent reading Unknown.
    init?(record: HerdrCoreTerminalRecord) {
        guard let agent = HerdrCoreAgentRule.agent(in: record), agent.status == .unknown else {
            return nil
        }
        let noted = Self.firstReportingReleases[agent.kind]
        // Nil for a program Heeler does not know, which its own sentences name.
        let program: String? =
            agent.isKnownProgram
            ? noted?.program ?? SupportedAgentKind(rawValue: agent.kind)?.displayName ?? agent.kind
            : nil
        agentProcess = record.foreground?.pid ?? record.pid
        if Self.reportedForItself(record, kind: agent.kind) {
            text = program.map { String(localized: "\($0) has not reported a state yet.") }
                ?? String(localized: "This program has not reported a state yet.")
            offersGrokBuildEdit = false
            return
        }
        offersGrokBuildEdit = agent.kind == "grok"
        if let noted {
            let release = noted.release
            text = program.map {
                String(localized: "\($0) hasn't reported a status. It reports one from version \(release), so an older version stays Unknown.")
            } ?? String(localized: "This program hasn't reported a status. It reports one from version \(release), so an older version stays Unknown.")
        } else {
            text = program.map { String(localized: "\($0) hasn't reported a status.") }
                ?? String(localized: "This program hasn't reported a status.")
        }
    }

    /// A report from another known program is what the core kept of the one before.
    private static func reportedForItself(_ record: HerdrCoreTerminalRecord, kind: String) -> Bool {
        guard record.reported else { return false }
        guard let report = record.status else { return true }
        let app = report.app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let reported = HerdrCoreAgentRule.reportedApps[app] else { return true }
        return reported == kind
    }
}
