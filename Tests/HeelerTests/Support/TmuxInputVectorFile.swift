import Foundation

/// The shared tmux input vectors from `plugin/test-vectors/tmux-input-v1.json`
/// (ADR 0043's input measurements), bundled into the test target as a
/// resource. Byte strings are hex.
struct TmuxInputVectorFile: Decodable, Sendable {
    let description: String
    let keys: [Key]
    let runs: [Run]
    let texts: [Text]
    let literal: [Arrival]
    let pasteTexts: [Text]
    let pastes: [Paste]
    let oneShot: [OneShot]

    struct Key: Decodable, Sendable {
        /// keytest.py's name for the key.
        let name: String
        /// xterm's encoding of the key, as a desktop terminal sends it.
        let desktop: String
        /// The same key in other forms the terminal view may send it in.
        let alternates: [String]?
        /// Heeler's tmux name for it, or nil when Heeler types it as `text`.
        let key: String?
        let extended: Bool?
        let text: String?
    }

    struct Run: Decodable, Sendable {
        let version: String
        let extendedKeys: String
        let extendedKeysFormat: String?
        let program: String
        let paneKeyMode: String
        let sources: [String]
        /// What the program read for the desktop's key, by the key's name.
        let read: [String: String]
        /// What it read for Heeler's `send-keys`, where that differed.
        let heelerRead: [String: String]
        /// What it read for tmux's own name of a key Heeler names otherwise.
        let otherNameRead: [String: String]
    }

    struct Text: Decodable, Sendable {
        let name: String
        let text: String
        let argument: String
    }

    struct Arrival: Decodable, Sendable {
        let version: String
        let extendedKeys: String
        let name: String
        let exact: Bool
        let received: String?
        let source: String
    }

    struct Paste: Decodable, Sendable {
        let version: String
        let bracketedPaste: Bool
        let flags: String
        let name: String
        let exact: Bool
        let source: String
    }

    struct OneShot: Decodable, Sendable {
        let version: String
        let argument: String
        let received: String
        let source: String
    }

    private final class BundleToken {}

    static func load() throws -> TmuxInputVectorFile {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "tmux-input-v1", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSDebugDescriptionErrorKey: "tmux-input-v1.json"])
        }
        return try JSONDecoder().decode(TmuxInputVectorFile.self, from: Data(contentsOf: url))
    }

    static func bytes(_ hex: String) -> Data {
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }
}
