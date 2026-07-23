import Foundation
import Observation

/// The only application-level writer for Attach input. Keyboard input, terminal
/// controls, reviewed Paste, and Staged Image paths all cross this boundary so
/// pausing and session-generation checks apply consistently.
@MainActor
@Observable
final class TerminalInputController {
    struct SessionGeneration: Sendable, Hashable {
        fileprivate let value: UInt64
    }

    struct PasteReview: Sendable, Equatable {
        let lineCount: Int
        let characterCount: Int
        let preview: String
    }

    enum PasteRequestResult: Sendable, Equatable {
        case inserted
        case requiresReview(PasteReview)
        case rejected
        case blocked

        var requiresReview: Bool {
            if case .requiresReview = self { true } else { false }
        }
    }

    private(set) var liveGeneration: SessionGeneration?
    private(set) var isPaused = false
    private(set) var pendingPaste: PasteReview?
    private(set) var pasteErrorMessage: String?

    private var nextGeneration: UInt64 = 0
    private var writer: ((Data) -> Void)?
    private var pendingPasteText: String?

    @discardableResult
    func beginSession(writer: @escaping (Data) -> Void) -> SessionGeneration {
        nextGeneration &+= 1
        let generation = SessionGeneration(value: nextGeneration)
        liveGeneration = generation
        self.writer = writer
        return generation
    }

    func endSession(_ generation: SessionGeneration) {
        guard generation == liveGeneration else { return }
        liveGeneration = nil
        writer = nil
        cancelPaste()
    }

    func pause() {
        isPaused = true
        cancelPaste()
    }

    func resume() {
        isPaused = false
    }

    /// Sends ordinary terminal bytes if a live, unpaused Attach session exists.
    func send(_ data: Data) {
        guard !data.isEmpty, !isPaused else { return }
        writer?(data)
    }

    /// Inserts a staged path only into the session captured by an image
    /// operation. Path and separator remain distinct writes and no submit byte
    /// is ever synthesized.
    @discardableResult
    func insertPath(_ path: String, matching generation: SessionGeneration) -> Bool {
        guard generation == liveGeneration else { return false }
        return insertPathIntoCurrentSession(path)
    }

    /// Recovery action chosen by the user. It intentionally targets whichever
    /// Attach session is live now, rather than the operation's old generation.
    @discardableResult
    func insertPathIntoCurrentSession(_ path: String) -> Bool {
        guard !isPaused, writer != nil, Self.isValidAbsoluteHostPath(path) else {
            return false
        }
        writer?(Data(path.utf8))
        writer?(Data(" ".utf8))
        return true
    }

    @discardableResult
    func requestPaste(_ text: String) -> PasteRequestResult {
        pasteErrorMessage = nil
        guard !isPaused, writer != nil else { return .blocked }
        guard Self.containsOnlySafePasteScalars(text) else {
            cancelPaste()
            pasteErrorMessage = "The clipboard contains unsafe terminal control characters."
            return .rejected
        }
        guard Self.isMultiline(text) else {
            if !text.isEmpty {
                writer?(Data(text.utf8))
            }
            return .inserted
        }

        let review = PasteReview(
            lineCount: Self.lineCount(text),
            characterCount: text.count,
            preview: Self.preview(text))
        pendingPasteText = text
        pendingPaste = review
        return .requiresReview(review)
    }

    @discardableResult
    func confirmPaste() -> Bool {
        guard !isPaused, writer != nil, let text = pendingPasteText else {
            cancelPaste()
            return false
        }
        writer?(Data(text.utf8))
        cancelPaste()
        return true
    }

    func cancelPaste() {
        pendingPasteText = nil
        pendingPaste = nil
    }

    func clearPasteError() {
        pasteErrorMessage = nil
    }

    private static func isValidAbsoluteHostPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar.properties.generalCategory != .control
        }
    }

    private static func containsOnlySafePasteScalars(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                true
            default:
                scalar.properties.generalCategory != .control
            }
        }
    }

    private static func isMultiline(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r")
    }

    private static func lineCount(_ text: String) -> Int {
        var count = 1
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                if !previousWasCarriageReturn { count += 1 }
            } else if scalar.value == 0x0D {
                count += 1
            }
            previousWasCarriageReturn = scalar.value == 0x0D
        }
        return count
    }

    private static func preview(_ text: String) -> String {
        let limit = 2_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
