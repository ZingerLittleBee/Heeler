import Foundation
import Testing

@testable import Heeler

/// When a herdr-core Agent ends a turn and reads Done on this device (ADR 0033),
/// from the shared vector the Helper's Node side reads too.
@Suite struct HerdrCoreTurnEndTests {
    struct VectorFile: Decodable {
        let provisional: Bool
        let coreVersion: String
        let doneReporters: [String]
        let cases: [Case]
    }

    struct Case: Decodable {
        let name: String
        let source: String
        let kind: String
        let steps: [Step]
    }

    struct Step: Decodable {
        let event: String
        let state: String?
        let turn: Int?
        let reported: Bool?
        let kind: String?
        let ends: Bool
        let done: Bool
    }

    private final class BundleToken {}

    private static func vectors() throws -> VectorFile {
        let url = try #require(
            Bundle(for: BundleToken.self).url(
                forResource: "herdr-core-turn-end-v1", withExtension: "json"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    /// Runs one step the way the Console's projection does, with the count a
    /// status event finds on its record, which only its turn event moves.
    private static func apply(
        _ step: Step, to state: inout HerdrCoreTurnState, kind: inout String?, count: inout Int
    ) throws -> Bool {
        switch step.event {
        case "snapshot":
            count = try #require(step.turn)
            return state.noteSnapshot(
                turn: count, word: step.state, kind: kind,
                reported: try #require(step.reported as Bool?))
        case "status":
            return state.noteStatus(word: step.state, turn: count, kind: kind)
        case "turn":
            count = try #require(step.turn)
            state.noteTurn(count)
            return false
        case "restarted":
            count = try #require(step.turn)
            state.noteRestart(turn: count)
            return false
        case "agent":
            kind = step.kind
            if kind == nil { state.noteNoAgent() }
            return false
        case "seen":
            state.markSeen()
            return false
        default:
            Issue.record("Unknown event \(step.event)")
            return false
        }
    }

    @Test func everyStepEndsATurnOrReadsDoneAsTheVectorSays() throws {
        let file = try Self.vectors()
        #expect(!file.cases.isEmpty)
        for vector in file.cases {
            var state = HerdrCoreTurnState()
            var kind: String? = vector.kind
            var count = 0
            for (index, step) in vector.steps.enumerated() {
                let ended = try Self.apply(step, to: &state, kind: &kind, count: &count)
                let place = "\(vector.name), step \(index) (\(step.event))"
                #expect(ended == step.ends, "\(place): ends")
                #expect(state.isDone == step.done, "\(place): done")
            }
        }
    }

    @Test func everyCaseNamesItsSourceAndIsOneTheFileCanBeTrustedFor() throws {
        let file = try Self.vectors()
        #expect(file.coreVersion == "0.1.13")
        // Until the owner's recordings on hc-lab confirm its cases.
        #expect(file.provisional)
        #expect(Set(file.cases.map(\.name)).count == file.cases.count)
        for vector in file.cases {
            #expect(!vector.source.trimmingCharacters(in: .whitespaces).isEmpty, "\(vector.name)")
            #expect(!vector.steps.isEmpty, "\(vector.name)")
        }
    }

    @Test func theKnownDoneReportersAreTheOnesTheFileNames() throws {
        let file = try Self.vectors()
        #expect(HerdrCoreTurnState.doneReporterKinds == Set(file.doneReporters))
    }

    @Test(arguments: ["working", "blocked", "error"])
    func aMarkWithAWordThatIsNoTurnEndNeverCountsAsSeeingOne(word: String) {
        var state = HerdrCoreTurnState()
        _ = state.noteSnapshot(turn: 4, word: word, kind: "claude", reported: true)
        state.markSeen()
        #expect(state.seen == HerdrCoreTurnState.Mark(turn: 4, word: word))
        #expect(!state.isDone)
    }

    @Test func aMarkIsTheTurnThatEndedAndSurvivesEncoding() throws {
        var state = HerdrCoreTurnState()
        _ = state.noteStatus(word: "working", turn: 4, kind: "claude")
        _ = state.noteStatus(word: "done", turn: 4, kind: "claude")
        state.noteTurn(5)
        _ = state.noteStatus(word: "idle", turn: 5, kind: "claude")
        state.markSeen()
        #expect(state.seen == HerdrCoreTurnState.Mark(turn: 5, word: "done"))

        let decoded = try JSONDecoder().decode(
            HerdrCoreTurnState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
