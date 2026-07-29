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

    private var scanner = PlainAttachLinkScanner()

    func receive(_ data: Data) {
        for target in scanner.receive(data) {
            record(target)
        }
    }

    func finishOutput() {
        if let target = scanner.finishOutput() {
            record(target)
        }
    }

    func clear() {
        scanner = PlainAttachLinkScanner()
        links.removeAll(keepingCapacity: false)
    }

    private func record(_ target: String) {
        guard let url = TerminalLinkPolicy.url(for: target) else { return }
        let link = AttachLink(target: target, url: url)
        links.removeAll { $0.target == link.target }
        links.insert(link, at: 0)
        if links.count > Self.maximumLinkCount {
            links.removeLast(links.count - Self.maximumLinkCount)
        }
    }
}

/// Recognizes plain web targets directly from the PTY byte stream. Network
/// chunk boundaries are invisible here; actual control and whitespace bytes
/// terminate candidates. Both state buffers have hard upper bounds.
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

    mutating func receive(_ data: Data) -> [String] {
        var targets: [String] = []
        for byte in data {
            if Self.isBoundary(byte) {
                if let target = finishCandidate() {
                    targets.append(target)
                }
                recent.removeAll(keepingCapacity: true)
                continue
            }

            if !candidate.isEmpty || isOversized {
                appendToCandidate(byte)
                continue
            }

            recent.append(byte)
            if recent.count > Self.longestSchemeBytes.count {
                recent.removeFirst(recent.count - Self.longestSchemeBytes.count)
            }
            guard let scheme = Self.webSchemes.first(where: { recentEnds(with: $0) })
            else { continue }
            candidate = Data(recent.suffix(scheme.count))
            recent.removeAll(keepingCapacity: true)
        }
        return targets
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
