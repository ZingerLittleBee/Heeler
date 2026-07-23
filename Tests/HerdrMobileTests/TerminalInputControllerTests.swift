import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Terminal input controller")
struct TerminalInputControllerTests {
    @Test func imagePathInsertionIsOrderedAndNeverSubmits() throws {
        var writes: [Data] = []
        let controller = TerminalInputController()
        let generation = controller.beginSession { writes.append($0) }

        #expect(controller.insertPath("/private/tmp/staged/image.jpg", matching: generation))
        #expect(
            writes == [
                Data("/private/tmp/staged/image.jpg".utf8),
                Data(" ".utf8),
            ])
        #expect(!writes.contains(Data([0x0D])))
        #expect(!writes.contains(Data([0x0A])))
    }

    @Test func staleGenerationCannotReceiveAutomaticInsertion() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        let original = controller.beginSession { writes.append($0) }
        controller.endSession(original)
        _ = controller.beginSession { writes.append($0) }

        #expect(!controller.insertPath("/tmp/stale.png", matching: original))
        #expect(writes.isEmpty)
        #expect(controller.insertPathIntoCurrentSession("/tmp/current.png"))
        #expect(
            writes == [
                Data("/tmp/current.png".utf8),
                Data(" ".utf8),
            ])
    }

    @Test func pausingDropsKeyboardPasteAndControlInputUntilResumed() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        controller.pause()
        controller.send(Data("keyboard".utf8))
        #expect(controller.requestPaste("clipboard") == .blocked)
        #expect(controller.isPaused)
        #expect(writes.isEmpty)

        controller.resume()
        controller.send(Data([0x03]))
        #expect(controller.requestPaste("clipboard") == .inserted)
        #expect(writes == [Data([0x03]), Data("clipboard".utf8)])
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
}
