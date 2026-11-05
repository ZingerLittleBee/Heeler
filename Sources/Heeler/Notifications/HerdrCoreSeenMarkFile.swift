import Foundation

/// What this device has seen on a herdr-core Host, as the Host Helper reads it
/// (ADR 0033): one file per device in the Helper's directory, named from its
/// Notification Key id and never from a Terminal address. The Helper counts an
/// Agent's Done for this device only for a turn that ended after its mark here.
///
/// `plugin/test-vectors/herdr-core-seen-mark-v1.json` pins the format: this writes
/// it, byte for byte, and the Helper's `seen-marks.js` reads it.
struct HerdrCoreSeenMarkFile: Equatable, Sendable {
    /// The Notification Key id of this device's registration on the Host.
    let device: String
    /// Marks belong to one core, whose addresses they name.
    let core: String
    /// By Terminal address.
    let marks: [String: HerdrCoreTurnState.Mark]

    static func fileName(keyID: String) -> String { "seen-\(keyID).json" }

    /// A list in address order, so the bytes do not depend on how a platform's
    /// encoder sorts a dictionary's keys.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Wire(
                v: 1, device: device, core: core,
                marks: marks.sorted { $0.key < $1.key }.map {
                    Wire.Mark(terminal: $0.key, turn: $0.value.turn, word: $0.value.word)
                }))
    }

    private struct Wire: Encodable {
        struct Mark: Encodable {
            let terminal: String
            let turn: Int
            /// Left out for a Terminal that has reported nothing.
            let word: String?
        }

        let v: Int
        let device: String
        let core: String
        let marks: [Mark]
    }
}
