import Foundation
import Observation

/// One exact HTTP(S) target observed during the current Attach.
struct AttachLink: Identifiable, Equatable {
    let target: String
    let url: URL

    var id: String { target }
    var host: String { url.host ?? "" }
}

/// Owns the bounded, memory-only Attach Link collection and incremental
/// discovery state. A terminal pipeline may be replaced without replacing
/// this index; the enclosing `AgentAttachStore` clears it on leave.
@MainActor
@Observable
final class AttachLinkIndex {
    private static let maximumLinkCount = 20

    private(set) var links: [AttachLink] = []

    @ObservationIgnored private let onDistinctLink: (AttachLink) -> Void
    private var scanner = AttachLinkScanner()

    init(onDistinctLink: @escaping (AttachLink) -> Void) {
        self.onDistinctLink = onDistinctLink
    }

    func receive(_ data: Data) {
        var scanner = scanner
        scanner.receive(data) { target in
            record(target)
        }
        self.scanner = scanner
    }

    /// Supplements stream discovery from Ghostty's current visible text.
    /// Every snapshot is independent: its newlines remain hard boundaries
    /// because the embedding API does not identify visual soft wraps.
    func receiveViewportText(_ text: String) {
        var viewportScanner = AttachLinkScanner()
        viewportScanner.receive(Data(text.utf8)) { target in
            record(target, moveExistingToFront: false)
        }
        viewportScanner.finishOutput { target in
            record(target, moveExistingToFront: false)
        }
    }

    func finishOutput() {
        var scanner = scanner
        scanner.finishOutput { target in
            record(target)
        }
        self.scanner = scanner
    }

    func clear() {
        scanner = AttachLinkScanner()
        links.removeAll(keepingCapacity: false)
    }

    private func record(_ target: String, moveExistingToFront: Bool = true) {
        guard let url = TerminalLinkPolicy.url(for: target) else { return }
        let isDistinct = !links.contains(where: { $0.target == target })
        if !moveExistingToFront, !isDistinct {
            return
        }
        let link = AttachLink(target: target, url: url)
        links.removeAll { $0.target == link.target }
        links.insert(link, at: 0)
        if links.count > Self.maximumLinkCount {
            links.removeLast(links.count - Self.maximumLinkCount)
        }
        if isDistinct {
            onDistinctLink(link)
        }
    }
}

/// Removes terminal control content while preserving stream state across
/// arbitrary PTY chunks. SGR styling is transparent to visible URLs; other
/// controls end plain candidates. OSC 8 targets are collected explicitly so
/// their labels cannot hide or replace the real destination.
private struct AttachLinkScanner {
    private enum State: Equatable {
        case text
        case escape
        case escapeSequence
        case csi
        case osc
        case oscEscape
        case stringControl
        case stringControlEscape
    }

    private var state = State.text
    private var plain = PlainAttachLinkScanner()
    private var osc = OSC8Accumulator()
    private var isOSC8LabelActive = false

    mutating func receive(_ data: Data, record: (String) -> Void) {
        for byte in data {
            receive(byte, record: record)
        }
    }

    mutating func finishOutput(record: (String) -> Void) {
        if state != .text {
            finishPlainCandidate(record: record)
        } else if !isOSC8LabelActive, let target = plain.finishOutput() {
            record(target)
        }
        state = .text
        osc.reset()
        isOSC8LabelActive = false
    }

    private mutating func receive(_ byte: UInt8, record: (String) -> Void) {
        switch state {
        case .text:
            receiveText(byte, record: record)

        case .escape:
            receiveAfterEscape(byte, record: record)

        case .escapeSequence:
            if (0x30...0x7E).contains(byte) {
                state = .text
            } else if byte == 0x1B {
                state = .escape
            }

        case .csi:
            if (0x40...0x7E).contains(byte) {
                if byte != 0x6D {
                    finishPlainCandidate(record: record)
                }
                state = .text
            } else if byte == 0x1B {
                finishPlainCandidate(record: record)
                state = .escape
            }

        case .osc:
            if byte == 0x07 || byte == 0x9C {
                finishOSC(record: record)
            } else if byte == 0x1B {
                state = .oscEscape
            } else {
                osc.receive(byte)
            }

        case .oscEscape:
            if byte == 0x5C {
                finishOSC(record: record)
            } else {
                osc.invalidate()
                state = byte == 0x1B ? .oscEscape : .osc
            }

        case .stringControl:
            if byte == 0x9C {
                state = .text
            } else if byte == 0x1B {
                state = .stringControlEscape
            }

        case .stringControlEscape:
            state = byte == 0x5C ? .text : .stringControl
        }
    }

    private mutating func receiveText(_ byte: UInt8, record: (String) -> Void) {
        switch byte {
        case 0x1B:
            state = .escape
        case 0x9B:
            state = .csi
        case 0x9D:
            osc.reset()
            state = .osc
        case 0x90, 0x98, 0x9E, 0x9F:
            finishPlainCandidate(record: record)
            state = .stringControl
        case 0x80...0x9F:
            finishPlainCandidate(record: record)
        default:
            guard !isOSC8LabelActive else { return }
            plain.receive(byte, record: record)
        }
    }

    private mutating func receiveAfterEscape(
        _ byte: UInt8,
        record: (String) -> Void
    ) {
        switch byte {
        case 0x5B:
            state = .csi
        case 0x5D:
            osc.reset()
            state = .osc
        case 0x50, 0x58, 0x5E, 0x5F:
            finishPlainCandidate(record: record)
            state = .stringControl
        case 0x20...0x2F:
            finishPlainCandidate(record: record)
            state = .escapeSequence
        default:
            finishPlainCandidate(record: record)
            state = .text
        }
    }

    private mutating func finishOSC(record: (String) -> Void) {
        defer {
            osc.reset()
            state = .text
        }
        guard let hyperlink = osc.hyperlink else {
            finishPlainCandidate(record: record)
            return
        }

        finishPlainCandidate(record: record)
        switch hyperlink {
        case .close:
            isOSC8LabelActive = false
        case .open(let target):
            isOSC8LabelActive = true
            if let target {
                record(target)
            }
        }
    }

    private mutating func finishPlainCandidate(record: (String) -> Void) {
        guard !isOSC8LabelActive, let target = plain.finishOutput() else { return }
        record(target)
    }
}

private struct OSC8Accumulator {
    enum Hyperlink {
        case open(String?)
        case close
    }

    private enum Field: Equatable {
        case command
        case parameters
        case target
        case ignored
    }

    private static let maximumTargetBytes = 32 * 1024
    private static let maximumCommandBytes = 16

    private var field = Field.command
    private var command = Data()
    private var target = Data()
    private var isTargetOversized = false

    var hyperlink: Hyperlink? {
        guard field == .target else { return nil }
        guard !target.isEmpty else { return .close }
        guard !isTargetOversized,
            let target = String(data: target, encoding: .utf8)
        else {
            return .open(nil)
        }
        return .open(target)
    }

    mutating func receive(_ byte: UInt8) {
        switch field {
        case .command:
            if byte == 0x3B {
                field = command == Data("8".utf8) ? .parameters : .ignored
            } else if command.count < Self.maximumCommandBytes {
                command.append(byte)
            } else {
                field = .ignored
            }

        case .parameters:
            if byte == 0x3B {
                field = .target
            }

        case .target:
            guard !isTargetOversized else { return }
            guard target.count < Self.maximumTargetBytes else {
                target.removeAll(keepingCapacity: false)
                isTargetOversized = true
                return
            }
            target.append(byte)

        case .ignored:
            break
        }
    }

    mutating func invalidate() {
        field = .ignored
        command.removeAll(keepingCapacity: false)
        target.removeAll(keepingCapacity: false)
        isTargetOversized = false
    }

    mutating func reset() {
        field = .command
        command.removeAll(keepingCapacity: true)
        target.removeAll(keepingCapacity: true)
        isTargetOversized = false
    }
}

/// Recognizes plain web targets from printable terminal text. Network chunk
/// boundaries are invisible here; actual whitespace terminates candidates.
/// Both state buffers have hard upper bounds.
private struct PlainAttachLinkScanner {
    private static let maximumTargetBytes = 32 * 1024
    private static let longestSchemeBytes = Array("https://".utf8)
    private static let webSchemes = [
        Array("http://".utf8),
        Array("https://".utf8),
    ]
    private static let trailingSentencePunctuation = CharacterSet(charactersIn: ".,;:!")

    private var recent = Data()
    private var candidate = Data()
    private var isOversized = false

    mutating func receive(_ data: Data, record: (String) -> Void) {
        for byte in data {
            receive(byte, record: record)
        }
    }

    mutating func receive(_ byte: UInt8, record: (String) -> Void) {
        if Self.isBoundary(byte) {
            if let target = finishCandidate() {
                record(target)
            }
            recent.removeAll(keepingCapacity: true)
            return
        }

        if !candidate.isEmpty || isOversized {
            appendToCandidate(byte)
            return
        }

        recent.append(byte)
        if recent.count > Self.longestSchemeBytes.count {
            recent.removeFirst(recent.count - Self.longestSchemeBytes.count)
        }
        guard let scheme = Self.webSchemes.first(where: { recentEnds(with: $0) })
        else { return }
        candidate = Data(recent.suffix(scheme.count))
        recent.removeAll(keepingCapacity: true)
    }

    mutating func finishOutput() -> String? {
        defer { recent.removeAll(keepingCapacity: true) }
        return finishCandidate()
    }

    private mutating func appendToCandidate(_ byte: UInt8) {
        guard !isOversized else { return }
        guard candidate.count < Self.maximumTargetBytes else {
            candidate.removeAll(keepingCapacity: false)
            isOversized = true
            return
        }
        candidate.append(byte)
    }

    private mutating func finishCandidate() -> String? {
        defer {
            candidate.removeAll(keepingCapacity: true)
            isOversized = false
        }
        guard !isOversized, let text = String(data: candidate, encoding: .utf8) else {
            return nil
        }
        let target = Self.removingSurroundingPunctuation(from: text)
        return target.isEmpty ? nil : target
    }

    private func recentEnds(with suffix: [UInt8]) -> Bool {
        guard recent.count >= suffix.count else { return false }
        return zip(recent.suffix(suffix.count), suffix).allSatisfy {
            Self.lowercasedASCII($0.0) == $0.1
        }
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func removingSurroundingPunctuation(from text: String) -> String {
        var target = text
        var removedCharacter = true
        while removedCharacter, let last = target.last {
            removedCharacter = false
            if last.unicodeScalars.allSatisfy(trailingSentencePunctuation.contains) {
                target.removeLast()
                removedCharacter = true
                continue
            }
            for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}")] {
                guard last == Character(closing) else { continue }
                let openingCount = target.reduce(into: 0) {
                    if $1 == Character(opening) { $0 += 1 }
                }
                let closingCount = target.reduce(into: 0) {
                    if $1 == Character(closing) { $0 += 1 }
                }
                if closingCount > openingCount {
                    target.removeLast()
                    removedCharacter = true
                }
                break
            }
        }
        return target
    }

    private static func isBoundary(_ byte: UInt8) -> Bool {
        byte <= 0x20 || byte == 0x7F
            || byte == 0x22 || byte == 0x27
            || byte == 0x3C || byte == 0x3E
    }
}
