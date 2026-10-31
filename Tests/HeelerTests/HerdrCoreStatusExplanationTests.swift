import Foundation
import Testing

@testable import Heeler

/// Why a core Agent reads Unknown (ADR 0034). The releases are the ones the
/// compatibility notes record, written out here rather than read from the table.
@Suite struct HerdrCoreStatusExplanationTests {
    private static func record(
        foreground: [String], reported: Bool = false, status: (state: String, app: String)? = nil
    ) throws -> HerdrCoreTerminalRecord {
        try HerdrCoreWire.typed(
            .object([
                "address": .string("t1"), "state": .string("live"), "pid": .number(7),
                "argv": .array([.string("/bin/zsh")]), "reported": .bool(reported),
                "foreground": .object([
                    "pid": .number(70), "name": .string(foreground[0]),
                    "argv": .array(foreground.map(JSONValue.string)), "cwd": .string("/work"),
                ]),
                "status": status.map {
                    .object(["state": .string($0.state), "app": .string($0.app)])
                } ?? .null,
            ]))
    }

    @Test(arguments: [
        ("claude", "Claude Code", "2.1.295"),
        ("codex", "Codex", "0.163"),
        ("opencode", "OpenCode", "2.1"),
        ("pi", "Pi", "1.1.0"),
        ("omp", "Oh My Pi", "18.8.7"),
    ])
    func aProgramNamesItsFirstReportingRelease(executable: String, program: String, release: String) throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: [executable])))
        #expect(
            explanation.text
                == "\(program) hasn't reported a status. It reports one from version \(release), so an older version stays Unknown.")
        #expect(!explanation.offersGrokBuildEdit)
    }

    @Test func grokBuildNamesNoRelease() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: ["grok"])))
        #expect(explanation.text == "Grok Build hasn't reported a status.")
    }

    @Test func aKnownProgramWithoutANotedReleaseNamesNone() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: ["gemini"])))
        #expect(explanation.text == "Gemini CLI hasn't reported a status.")
        #expect(!explanation.offersGrokBuildEdit)
    }

    /// A program Heeler does not know is an Agent only through a report, so
    /// Unknown there is a state word Heeler cannot read.
    @Test func anUnknownProgramNamesNoRelease() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(
                record: try Self.record(
                    foreground: ["mybot"], reported: true, status: ("thinking", "mybot"))))
        #expect(explanation.text == "This program has not reported a state yet.")
        #expect(!explanation.offersGrokBuildEdit)
    }

    /// Claude Code before sign-in: the core saw a report, and holds no state.
    @Test func aTerminalThatReportedAndHoldsNoStateHasNotReportedAStateYet() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: ["claude"], reported: true)))
        #expect(explanation.text == "Claude Code has not reported a state yet.")
        #expect(!explanation.offersGrokBuildEdit)
    }

    @Test func anAgentThatReportsANamedStateHasNothingToExplain() throws {
        for state in ["idle", "done", "working", "blocked", "error"] {
            #expect(
                HerdrCoreStatusExplanation(
                    record: try Self.record(
                        foreground: ["grok"], reported: true, status: (state, "grok-build"))) == nil)
        }
    }

    @Test func aShellHasNothingToExplain() throws {
        #expect(HerdrCoreStatusExplanation(record: try Self.record(foreground: ["/bin/zsh"])) == nil)
    }

    // MARK: The Grok Build offer

    @Test func theOfferIsOnAGrokBuildAgentWithNoStatus() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: ["grok"])))
        #expect(explanation.offersGrokBuildEdit)
    }

    /// Grok Build reported, so its automatic check did not turn it off.
    @Test func noOfferOnAGrokBuildAgentThatReported() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: ["grok"], reported: true)))
        #expect(explanation.text == "Grok Build has not reported a state yet.")
        #expect(!explanation.offersGrokBuildEdit)
    }

    /// What the core kept came from the program before: it says nothing of this one.
    @Test func anotherProgramsLeftoverReportDoesNotCountAsThisOnes() throws {
        let grok = try #require(
            HerdrCoreStatusExplanation(
                record: try Self.record(
                    foreground: ["grok"], reported: true, status: ("idle", "claude-code"))))
        #expect(grok.text == "Grok Build hasn't reported a status.")
        #expect(grok.offersGrokBuildEdit)

        let codex = try #require(
            HerdrCoreStatusExplanation(
                record: try Self.record(
                    foreground: ["codex"], reported: true, status: ("idle", "grok-build"))))
        #expect(!codex.offersGrokBuildEdit)
    }

    @Test func itKeepsTheAgentsProcessForReadingItsConfigurationFolder() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(record: try Self.record(foreground: ["grok"])))
        #expect(explanation.agentProcess == 70)
    }
}
