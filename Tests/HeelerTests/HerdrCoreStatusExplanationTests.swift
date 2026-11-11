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

    /// The unknown program's own sentence, not a known program's with a
    /// placeholder name in it.
    @Test func anUnknownProgramThatNeverReportedHasItsOwnSentence() throws {
        let explanation = try #require(
            HerdrCoreStatusExplanation(
                record: try Self.record(
                    foreground: ["mybot"], reported: false, status: ("thinking", "mybot"))))
        #expect(explanation.text == "This program hasn't reported a status.")
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

    // MARK: tmux Panes (ADR 0044)

    @Test(arguments: [
        ("codex", "Codex"),
        ("grok", "Grok Build"),
        ("opencode", "OpenCode"),
    ])
    func aUserPipedTmuxAgentSaysHeelerLeavesItsPipeAlone(command: String, program: String) throws {
        let pane = TmuxInventory.Pane.make(
            processID: 91, command: command, hasPipe: true, pipeMark: "", arguments: [command])
        let explanation = try #require(HerdrCoreStatusExplanation(pane: pane, agentStatus: .unknown))
        #expect(
            explanation.text
                == "\(program) has no status because this Pane already has a pipe-pane of your own, which Heeler leaves alone.")
        #expect(!explanation.offersGrokBuildEdit)
        #expect(explanation.agentProcess == 91)
    }

    @Test func anUnknownTmuxGrokBuildAgentOffersItsEdit() throws {
        let unpiped = TmuxInventory.Pane.make(processID: 77, command: "grok", arguments: ["grok"])
        let withoutHelper = try #require(HerdrCoreStatusExplanation(pane: unpiped, agentStatus: .unknown))
        #expect(
            withoutHelper.text
                == "Grok Build hasn't reported a status. In tmux its status is read by the Host Helper.")
        #expect(withoutHelper.offersGrokBuildEdit)
        #expect(withoutHelper.agentProcess == 77)

        let helperPiped = TmuxInventory.Pane.make(
            processID: 77, command: "grok", hasPipe: true, pipeMark: "grok:77:token", arguments: ["grok"])
        let withHelper = try #require(HerdrCoreStatusExplanation(pane: helperPiped, agentStatus: .unknown))
        #expect(withHelper.text == "Grok Build hasn't reported a status.")
        #expect(withHelper.offersGrokBuildEdit)
        #expect(withHelper.agentProcess == 77)
    }

    @Test func unknownTmuxAgentsSayWhereTheirStatusComesFrom() throws {
        let codexUnpiped = TmuxInventory.Pane.make(command: "codex", arguments: ["codex"])
        #expect(
            HerdrCoreStatusExplanation(pane: codexUnpiped, agentStatus: .unknown)?.text
                == "Codex hasn't reported a status. In tmux its status is read by the Host Helper, from Codex 0.163.")

        let openCodePiped = TmuxInventory.Pane.make(
            command: "opencode", hasPipe: true, pipeMark: "opencode:50:token", arguments: ["opencode"])
        #expect(
            HerdrCoreStatusExplanation(pane: openCodePiped, agentStatus: .unknown)?.text
                == "OpenCode hasn't reported a status. It reports one from version 2.1, so an older version stays Unknown.")

        let claude = TmuxInventory.Pane.make(
            command: "claude", hasPipe: true, pipeMark: "", arguments: ["claude"])
        #expect(
            HerdrCoreStatusExplanation(pane: claude, agentStatus: .unknown)?.text
                == "Claude Code hasn't reported a status. In tmux its status comes from Heeler's Claude Code hooks.")

        let pi = TmuxInventory.Pane.make(command: "pi", arguments: ["pi"])
        #expect(
            HerdrCoreStatusExplanation(pane: pi, agentStatus: .unknown)?.text
                == "Pi hasn't reported a status. In tmux its status comes from the Host Helper's extension.")

        let omp = TmuxInventory.Pane.make(command: "omp", arguments: ["omp"])
        #expect(
            HerdrCoreStatusExplanation(pane: omp, agentStatus: .unknown)?.text
                == "Oh My Pi hasn't reported a status. In tmux its status comes from the Host Helper's extension.")

        let gemini = TmuxInventory.Pane.make(command: "gemini", arguments: ["gemini"])
        #expect(
            HerdrCoreStatusExplanation(pane: gemini, agentStatus: .unknown)?.text
                == "Gemini CLI hasn't reported a status.")
    }

    @Test func aTmuxPaneWithAReportShellOrKnownStatusFollowsTheSameRules() throws {
        let unrecognized = TmuxInventory.Pane.make(
            command: "grok", status: "state=thinking:app=grok-build:turn=0:blocked=0", arguments: ["grok"])
        let reported = try #require(HerdrCoreStatusExplanation(pane: unrecognized, agentStatus: .unknown))
        #expect(reported.text == "Grok Build has not reported a state yet.")
        #expect(!reported.offersGrokBuildEdit)

        let leftover = TmuxInventory.Pane.make(
            command: "grok", status: "state=idle:app=claude-code:turn=1:blocked=0", arguments: ["grok"])
        let afterClaude = try #require(HerdrCoreStatusExplanation(pane: leftover, agentStatus: .unknown))
        #expect(afterClaude.offersGrokBuildEdit)

        for status: AgentStatus in [.idle, .done, .working, .blocked, .error] {
            #expect(HerdrCoreStatusExplanation(pane: leftover, agentStatus: status) == nil)
        }
        let shell = TmuxInventory.Pane.make(command: "zsh", arguments: ["/bin/zsh"])
        #expect(HerdrCoreStatusExplanation(pane: shell, agentStatus: .unknown) == nil)
    }
}
