import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal input controller")
struct TerminalInputControllerTests {
    @Test func checkingTheConnectionBlocksInputWithoutReplayingItOnRecovery() {
        var writes: [Data] = []
        var scrolls = 0
        let controller = TerminalInputController()
        let generation = controller.beginSession(
            writer: { writes.append($0) }, scroller: { _, _ in scrolls += 1 })
        #expect(controller.requestPaste("one\ntwo").requiresReview)
        controller.isEnabled = false

        #expect(!controller.send(Data("ignored".utf8)))
        #expect(!controller.sendEscapeKey())
        #expect(!controller.insertComposerDraft("draft"))
        #expect(!controller.insertSnippet("snippet", bracketedPaste: false))
        #expect(!controller.insertReferenceWhenLive("path/to/file"))
        #expect(controller.requestPaste("paste") == .blocked)
        #expect(!controller.canConfirmPaste)
        #expect(!controller.confirmPaste())
        controller.scroll(Data([0x1B]), rows: 3)
        #expect(scrolls == 0)

        controller.isEnabled = true
        controller.sessionDidBecomeLive(generation)
        #expect(writes.isEmpty)
        #expect(controller.confirmPaste())
        #expect(writes == [Data("one\ntwo".utf8)])
        #expect(controller.send(Data("new".utf8)))
        #expect(writes.last == Data("new".utf8))
    }

    @Test func recoveryDiscardsQueuedScrollWithoutDroppingKeys() async {
        let instant = ContinuousClock.now
        let queue = TerminalAttachInputQueue(now: { instant })
        defer { queue.finish() }
        let controller = TerminalInputController()
        let generation = controller.beginSession(
            writer: { queue.send($0) },
            scroller: { queue.scroll($0, rows: $1) },
            discardPendingScroll: { queue.discardPendingScroll() })
        defer { controller.endSession(generation) }
        let key = Data("accepted key".utf8)
        let wheel = Data("wheel".utf8)
        #expect(controller.send(key))
        controller.scroll(wheel, rows: 12)
        controller.isEnabled = false
        controller.scroll(wheel, rows: 12)
        controller.isEnabled = true
        controller.scroll(wheel, rows: 1)
        #expect(await queue.next() == .keystrokes(key))
        #expect(await queue.next() == .scroll(wheel))
    }

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

    @Test func sendClosesTheIndexedLineOnLineFeed() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        let text = "please implement the parser"

        #expect(controller.send(Data(text.utf8)))
        #expect(controller.send(Data([0x0A])))
        #expect(controller.userMessageIndex.entries.map(\.rawText) == [text])
    }

    @Test func keystrokeEscapeDoesNotDiscardATypedLine() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.send(Data("please implement ".utf8)))
        #expect(controller.send(Data([0x1B])))
        #expect(controller.send(Data("the parser".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText)
                == ["please implement the parser"])
    }

    @Test func composerDraftEscapeCancelsPendingText() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.insertComposerDraft("please approve"))
        #expect(controller.userMessageIndex.entries.isEmpty)
        #expect(controller.sendEscapeKey())
        #expect(controller.send(Data([0x0D])))
        #expect(controller.userMessageIndex.entries.isEmpty)
    }

    @Test func escapeKeyThenABracketRequestDoesNotKeepComposerInsertedText() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.insertComposerDraft("please approve"))
        #expect(controller.sendEscapeKey())
        #expect(controller.send(Data("[review] do it".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText) == ["[review] do it"])
    }

    @Test func bracketedPasteWithCRLFIsOneEntryAtSubmit() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        let text = "please approve\r\nthen continue"

        #expect(controller.requestPaste(text, bracketedPaste: true).requiresReview)
        #expect(controller.confirmPaste())
        #expect(controller.userMessageIndex.entries.isEmpty)

        #expect(controller.send(Data([0x0D])))
        #expect(controller.userMessageIndex.entries.map(\.rawText) == [text])
    }

    @Test func hardwareEscapeAfterComposerInsertCancelsBeforeABracketRequest() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.insertComposerDraft("please approve"))
        #expect(controller.send(Data([0x1B])))
        #expect(controller.send(Data("[review] do it".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText) == ["[review] do it"])
    }
    @Test func aHeldReferenceWaitsForOutputAndFlushesOnlyOnce() {
        let controller = TerminalInputController()
        var writes: [Data] = []
        #expect(controller.insertReferenceWhenLive("file.swift:2 "))
        let generation = controller.beginSession { writes.append($0) }
        #expect(writes.isEmpty)

        controller.isEnabled = false
        controller.sessionDidBecomeLive(generation)
        #expect(writes.isEmpty)
        #expect(!controller.insertReferenceWhenLive("ignored.swift "))
        controller.isEnabled = true
        controller.sessionDidBecomeLive(generation)
        controller.sessionDidBecomeLive(generation)
        #expect(writes == [Data("file.swift:2 ".utf8)])
        #expect(controller.userMessageIndex.entries.isEmpty)
    }

    @Test func aHeldReferenceSurvivesReplacementAndIgnoresOldLiveSignals() {
        let controller = TerminalInputController()
        var oldWrites: [Data] = []
        var newWrites: [Data] = []
        let old = controller.beginSession { oldWrites.append($0) }
        #expect(controller.insertReferenceWhenLive("first.swift "))
        controller.detachSessionForReplacement()
        controller.endSession(old)
        let replacement = controller.beginSession { newWrites.append($0) }
        controller.sessionDidBecomeLive(old)
        #expect(oldWrites.isEmpty)
        #expect(newWrites.isEmpty)

        controller.sessionDidBecomeLive(replacement)
        #expect(newWrites == [Data("first.swift ".utf8)])
        #expect(oldWrites.isEmpty)
    }

    @Test func anEndedConnectingSessionKeepsHeldReferencesInInsertionOrder() {
        let controller = TerminalInputController()
        let old = controller.beginSession { _ in Issue.record("wrote before Attach was live") }
        #expect(controller.insertReferenceWhenLive("first.swift "))
        controller.endSession(old)
        #expect(controller.insertReferenceWhenLive("second.swift:3 "))
        var writes: [Data] = []
        let generation = controller.beginSession { writes.append($0) }
        controller.sessionDidBecomeLive(generation)
        #expect(writes == [Data("first.swift second.swift:3 ".utf8)])
    }

    @Test func aReferenceTypesImmediatelyIntoAnAlreadyLiveAttachWithoutEnter() {
        let controller = TerminalInputController()
        var writes: [Data] = []
        let generation = controller.beginSession { writes.append($0) }
        controller.sessionDidBecomeLive(generation)
        #expect(controller.insertReferenceWhenLive("file.swift:2 "))
        #expect(writes == [Data("file.swift:2 ".utf8)])
        #expect(controller.userMessageIndex.entries.isEmpty)
    }

    @Test func leavingDiscardsAHeldReference() {
        let controller = TerminalInputController()
        #expect(controller.insertReferenceWhenLive("file.swift:2 "))
        controller.discardHeldInsertion()
        var writes: [Data] = []
        let generation = controller.beginSession { writes.append($0) }
        controller.sessionDidBecomeLive(generation)
        #expect(writes.isEmpty)
    }

    @Test(arguments: ["file\rname ", "file\nname ", "file\tname ", "file\u{1B}name ", "file\u{85}name "])
    func aHeldReferenceRejectsEveryControlCharacter(text: String) {
        let controller = TerminalInputController()
        #expect(!controller.insertReferenceWhenLive(text))
        var writes: [Data] = []
        let generation = controller.beginSession { writes.append($0) }
        controller.sessionDidBecomeLive(generation)
        #expect(!controller.insertReferenceWhenLive(text))
        #expect(writes.isEmpty)
    }
}

@Suite("Terminal text safety")
struct TerminalTextSafetyTests {
    @Test(arguments: [
        ("please approve", false),
        ("please\napprove", true),
        ("please\rapprove", true),
        ("please approve\r\nthen continue", true),
    ])
    func isMultilineUsesUnicodeScalars(_ text: String, _ expected: Bool) {
        #expect(TerminalTextSafety.isMultiline(text) == expected)
    }
}
