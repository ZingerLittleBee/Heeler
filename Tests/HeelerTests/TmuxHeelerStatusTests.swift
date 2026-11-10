import Foundation
import Testing

@testable import Heeler

/// How a tmux Pane's `@heeler-status` reads, and the Agent Status and Done it
/// gives on one device (ADR 0044), from the shared vector the hook script's
/// and the Helper's tests read too.
@Suite struct TmuxHeelerStatusTests {
    struct VectorFile: Decodable {
        let doneReporters: [String]
        let values: [Value]
        let writes: [Write]
        let reads: [Read]
    }

    struct Value: Decodable {
        let name: String
        let value: String
        let state: String?
        let app: String?
        let kind: String?
        let msg: String?
        let turn: Int
        let blocked: Int
    }

    struct Write: Decodable {
        struct Step: Decodable {
            let value: String
        }

        let name: String
        let steps: [Step]
    }

    struct Read: Decodable {
        let name: String
        let kind: String
        let steps: [Step]
    }

    struct Mark: Decodable, Equatable {
        let turn: Int
        let word: String?
    }

    struct Step: Decodable {
        let event: String
        let value: String?
        let kind: String?
        let status: String?
        let done: Bool?
        let mark: Mark?
    }

    private final class BundleToken {}

    private static func vectors() throws -> VectorFile {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "tmux-heeler-status-v1", withExtension: "json"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    @Test func everyValueReadsAsTheVectorSays() throws {
        let file = try Self.vectors()
        #expect(!file.values.isEmpty)
        for vector in file.values {
            let status = TmuxProgramStatus(option: vector.value)
            #expect(status.state == vector.state, "\(vector.name)")
            #expect(status.app == vector.app, "\(vector.name)")
            #expect(status.kind == vector.kind, "\(vector.name)")
            #expect(status.message == vector.msg, "\(vector.name)")
            #expect(status.turn == vector.turn, "\(vector.name)")
            #expect(status.blocked == vector.blocked, "\(vector.name)")
        }
    }

    /// The writers' values are the app's to read: none goes back on a count.
    @Test func everyWrittenValueReadsWithCountsThatNeverGoBack() throws {
        let file = try Self.vectors()
        #expect(!file.writes.isEmpty)
        for vector in file.writes {
            var turn = 0
            var blocked = 0
            for step in vector.steps {
                let status = TmuxProgramStatus(option: step.value)
                #expect(status.turn >= turn, "\(vector.name): \(step.value)")
                #expect(status.blocked >= blocked, "\(vector.name): \(step.value)")
                turn = status.turn
                blocked = status.blocked
            }
        }
    }

    @Test func theDoneReportersAreTheAgentRulesKnownReporters() throws {
        let file = try Self.vectors()
        let kinds = Set(file.doneReporters.compactMap { HerdrCoreAgentRule.reportedApps[$0] })
        #expect(kinds.count == file.doneReporters.count)
        #expect(kinds == HerdrCoreTurnState.doneReporterKinds)
    }

    /// Runs each step the way the Console's projection does.
    @Test func everyLookReadsTheAgentStatusAndDoneTheVectorSays() throws {
        let file = try Self.vectors()
        #expect(!file.reads.isEmpty)
        for vector in file.reads {
            var state = TmuxTurnState()
            var kind: String? = vector.kind
            var isShown = false
            for (index, step) in vector.steps.enumerated() {
                let label = "\(vector.name), step \(index + 1)"
                switch step.event {
                case "sample":
                    let status = TmuxProgramStatus(option: step.value ?? "")
                    if let kind {
                        state.noteSample(status, kind: kind, isShown: isShown)
                    } else {
                        state.noteNoAgent(status)
                    }
                case "open":
                    isShown = true
                    state.markSeen()
                case "close":
                    isShown = false
                case "agent":
                    kind = step.kind
                    continue
                default:
                    Issue.record("Unknown event \(step.event) in \(label)")
                    continue
                }
                #expect((kind == nil ? nil : state.agentStatus.rawValue) == step.status, "\(label)")
                #expect(state.isDone == step.done, "\(label)")
                if let mark = step.mark {
                    #expect(state.seen.map { Mark(turn: $0.turn, word: $0.word) } == mark, "\(label)")
                }
            }
        }
    }
}
