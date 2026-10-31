import Foundation
import Testing

@testable import Heeler

/// The Agent rule (ADR 0032) from the shared vector the Helper's Node side reads
/// too: each case is a core Terminal record and the Agent it holds.
@Suite struct HerdrCoreAgentRuleTests {
    struct VectorFile: Decodable {
        let provisional: Bool
        let coreVersion: String
        let apps: [String: String]
        let cases: [Case]
    }

    struct Case: Decodable {
        let name: String
        let source: String
        let record: JSONValue
        /// The data of the `foreground` events after the record, null for a cleared one.
        let foregroundEvents: [JSONValue]?
        let expected: Expected?
    }

    struct Expected: Decodable, Equatable {
        let kind: String
        let known: Bool
        let status: String
    }

    private static func vectors() throws -> VectorFile {
        let url = try #require(
            Bundle(for: BundleToken.self).url(
                forResource: "herdr-core-agent-rule-v1", withExtension: "json"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private final class BundleToken {}

    private static func terminal(_ record: JSONValue) throws -> HerdrCoreTerminalRecord {
        try HerdrCoreWire.typed(record)
    }

    @Test func everyCaseHoldsTheAgentItSays() throws {
        let file = try Self.vectors()
        #expect(file.cases.count >= 100)
        for vector in file.cases {
            var record = try Self.terminal(vector.record)
            for event in vector.foregroundEvents ?? [] {
                record.noteForeground(event == .null ? nil : try HerdrCoreWire.typed(event))
            }
            let agent = HerdrCoreAgentRule.agent(in: record)
            let actual = agent.map {
                Expected(kind: $0.kind, known: $0.isKnownProgram, status: $0.status.rawValue)
            }
            #expect(actual == vector.expected, "\(vector.name)")
        }
    }

    @Test func everyCaseNamesItsSourceAndItsOwnName() throws {
        let file = try Self.vectors()
        #expect(file.provisional)
        #expect(file.coreVersion == "0.1.13")
        for vector in file.cases {
            #expect(!vector.source.trimmingCharacters(in: .whitespaces).isEmpty, "\(vector.name)")
        }
        #expect(Set(file.cases.map(\.name)).count == file.cases.count)
    }

    @Test func theAppTableIsTheSixReportingHarnesses() throws {
        let file = try Self.vectors()
        #expect(file.apps == [
            "claude-code": "claude", "codex": "codex", "opencode": "opencode", "pi": "pi",
            "omp": "omp", "grok-build": "grok",
        ])
        #expect(HerdrCoreAgentRule.reportedApps == file.apps)
        // Each one reads as a kind the app can start, so its rows have its name.
        for kind in file.apps.values {
            #expect(SupportedAgentKind(rawValue: kind) != nil, "\(kind)")
        }
    }

    /// A generic Agent's kind is a word to show. No table the app keeps by program
    /// may take it for that program, whatever a Terminal on the Host reports.
    @Test func aGenericKindNeverReadsAsAKnownProgram() throws {
        var apps = SupportedAgentKind.allCases.flatMap {
            [$0.rawValue, $0.rawValue.uppercased(), $0.executable, " \($0.rawValue) "]
        }
        apps += ChatProgram.allCases.map(\.rawValue)
        apps += ["Claude Code", "pi-cli", "unknown", "agent", "shell", "program", "", "   ", "$(id)", "a/b", "東京"]
        let reported = Set(HerdrCoreAgentRule.reportedApps.keys)
        for app in apps where !reported.contains(app.lowercased().trimmingCharacters(in: .whitespaces)) {
            let record = try Self.terminal(.object([
                "address": .string("t1"), "state": .string("live"), "pid": .number(7),
                "foreground": .object([
                    "name": .string("tool"), "argv": .array([.string("tool")]), "cwd": .string("/w"),
                ]),
                "status": .object(["app": .string(app), "state": .string("idle")]),
            ]))
            let agent = try #require(HerdrCoreAgentRule.agent(in: record), "\(app)")
            #expect(!agent.isKnownProgram, "\(app)")
            #expect(SupportedAgentKind(rawValue: agent.kind.lowercased()) == nil, "\(app)")
            #expect(ChatProgram(rawValue: agent.kind.lowercased()) == nil, "\(app)")
            #expect(AgentNotificationIdentity.kindLabel(agent.kind) == agent.kind, "\(app)")
            #expect(agent.kind != ConsoleAgent.sessionFileAgent, "\(app)")
            #expect(agent.kind.utf8.count <= 32, "\(app)")
            #expect(agent.kind.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }, "\(app)")
        }
    }
}
