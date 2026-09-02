import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal input controller")
struct TerminalInputControllerTests {
    @Test func singleLinePasteInsertsImmediately() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.requestPaste("git status") == .inserted)
        #expect(writes == [Data("git status".utf8)])
        #expect(controller.pendingPaste == nil)
    }

    @Test func multilinePasteRequiresReviewAndConfirmsAsOneWrite() throws {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        let text = "printf one\nprintf two\n"

        let result = controller.requestPaste(text)

        guard case .requiresReview(let review) = result else {
            Issue.record("expected multiline review")
            return
        }
        #expect(review.lineCount == 3)
        #expect(review.characterCount == text.count)
        #expect(review.preview == text)
        #expect(writes.isEmpty)

        #expect(controller.confirmPaste())
        #expect(writes == [Data(text.utf8)])
        #expect(controller.pendingPaste == nil)
    }

    @Test func reviewedPasteWaitsForTheReplacementWriterAndSubmitsOnce() throws {
        var oldWrites: [Data] = []
        var replacementWrites: [Data] = []
        let controller = TerminalInputController()
        let oldGeneration = controller.beginSession { oldWrites.append($0) }
        let text = "git status\ngit diff"

        #expect(controller.requestPaste(text, bracketedPaste: true).requiresReview)
        let review = try #require(controller.pendingPaste)
        controller.detachSessionForReplacement()
        controller.endSession(oldGeneration, preservingPendingPaste: true)

        #expect(!controller.canConfirmPaste)
        #expect(!controller.confirmPaste())
        #expect(controller.pendingPaste == review)
        #expect(oldWrites.isEmpty)

        _ = controller.beginSession { replacementWrites.append($0) }
        #expect(controller.canConfirmPaste)
        #expect(controller.confirmPaste())
        #expect(
            replacementWrites == [
                TerminalBracketedPaste.start + Data(text.utf8) + TerminalBracketedPaste.end
            ])
        #expect(controller.pendingPaste == nil)
        #expect(!controller.confirmPaste())
        #expect(replacementWrites.count == 1)
    }

    @Test func ordinarySessionEndStillCancelsReviewedPaste() {
        let controller = TerminalInputController()
        let generation = controller.beginSession { _ in }

        #expect(controller.requestPaste("git status\ngit diff").requiresReview)
        controller.endSession(generation)

        #expect(controller.pendingPaste == nil)
        #expect(!controller.canConfirmPaste)
    }

    @Test func cancelIsTheSafeMultilineDefault() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        #expect(controller.requestPaste("one\ntwo").requiresReview)

        controller.cancelPaste()

        #expect(controller.pendingPaste == nil)
        #expect(writes.isEmpty)
    }

    @Test(arguments: [
        "nul\u{0}hidden",
        "escape\u{1B}[31m",
        "control\u{1F}hidden",
        "delete\u{7F}hidden",
        "c1\u{85}hidden",
    ])
    func unsafeClipboardControlsAreRejected(text: String) {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.requestPaste(text) == .rejected)
        #expect(controller.pasteErrorMessage != nil)
        #expect(controller.pendingPaste == nil)
        #expect(writes.isEmpty)
    }

    @Test func pastePreviewIsBoundedWithoutChangingConfirmedContent() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        let text = String(repeating: "x", count: 3_000) + "\nsecond"

        guard case .requiresReview(let review) = controller.requestPaste(text) else {
            Issue.record("expected multiline review")
            return
        }
        #expect(review.preview.count < text.count)
        #expect(review.preview.hasSuffix("…"))

        #expect(controller.confirmPaste())
        #expect(writes == [Data(text.utf8)])
    }

    @Test func snippetsGoOutWholeAndNeverSubmit() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.insertSnippet("run the tests", bracketedPaste: true))

        #expect(writes == [Data("run the tests".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
    }

    @Test func multilineSnippetsAreFramedAsAPasteWhenTheRemoteAskedForIt() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.insertSnippet("first\nsecond", bracketedPaste: true))

        #expect(
            writes == [
                TerminalBracketedPaste.start + Data("first\nsecond".utf8)
                    + TerminalBracketedPaste.end
            ])
    }

    @Test func withoutBracketedPasteTheMarkersAreNotSent() {
        // The markers would be echoed as literal garbage by an application
        // that never enabled DECSET 2004.
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.insertSnippet("first\nsecond", bracketedPaste: false))

        #expect(writes == [Data("first\nsecond".utf8)])
    }

    @Test func reviewedMultilinePasteIsFramedWithTheModeCapturedAtRequestTime() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        let text = "one\ntwo\nthree"

        #expect(controller.requestPaste(text, bracketedPaste: true).requiresReview)
        #expect(controller.confirmPaste())

        #expect(
            writes == [
                TerminalBracketedPaste.start + Data(text.utf8) + TerminalBracketedPaste.end
            ])
    }

    @Test func snippetWithUnsafeControlCharactersIsRefused() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(!controller.insertSnippet("escape\u{1B}[31m", bracketedPaste: true))
        #expect(writes.isEmpty)
    }

    @Test func snippetsRequireALiveSession() {
        let controller = TerminalInputController()

        #expect(!controller.insertSnippet("continue", bracketedPaste: true))
    }

    @Test func sendRequiresALiveSessionAndWritesRawBytes() {
        let controller = TerminalInputController()
        #expect(!controller.send(Data("n".utf8)))

        var writes: [Data] = []
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.send(Data("n".utf8)))
        #expect(writes == [Data("n".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
    }

    @Test func sendObservesPrintableBytesAndClosesTheIndexedLineOnEnter() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        let text = "please implement the parser"

        #expect(controller.send(Data(text.utf8)))
        #expect(controller.userMessageIndex.entries.isEmpty)

        #expect(controller.send(Data([0x0D])))
        #expect(controller.userMessageIndex.entries.map(\.rawText) == [text])
    }

    @Test func endingASessionClearsTheUserMessageIndex() {
        let controller = TerminalInputController()
        let generation = controller.beginSession { _ in }
        #expect(controller.send(Data("please implement the parser".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(!controller.userMessageIndex.entries.isEmpty)

        controller.endSession(generation)
        #expect(controller.userMessageIndex.entries.isEmpty)
    }

    @Test func aReplacementSessionDoesNotKeepThePredecessorIndex() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        #expect(controller.send(Data("please implement the parser".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(!controller.userMessageIndex.entries.isEmpty)

        controller.detachSessionForReplacement()
        #expect(controller.userMessageIndex.entries.isEmpty)

        _ = controller.beginSession { _ in }
        #expect(controller.userMessageIndex.entries.isEmpty)
        #expect(controller.send(Data("rewrite the matching tests".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText)
                == ["rewrite the matching tests"])
    }

    @Test func recordSubmittedDropsWhenTheGenerationIsNoLongerLive() {
        let controller = TerminalInputController()
        let generationA = controller.beginSession { _ in }
        controller.detachSessionForReplacement()
        let generationB = controller.beginSession { _ in }

        controller.recordSubmitted("Fix the failing tests", generation: generationA)
        #expect(controller.userMessageIndex.entries.isEmpty)

        controller.recordSubmitted("rewrite the matching tests", generation: generationB)
        #expect(
            controller.userMessageIndex.entries.map(\.rawText)
                == ["rewrite the matching tests"])
    }
}
