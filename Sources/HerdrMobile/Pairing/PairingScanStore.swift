import Foundation
import Observation

/// Turns strings recognized by the QR scanner into a parsed Pairing Code or
/// scan-step failure copy (#62). Camera capture stays in the view layer;
/// everything downstream of the scanned string is testable here against the
/// shared envelope vectors.
@MainActor
@Observable
final class PairingScanStore {
    /// Set once a scan parses; further scans are ignored until `rescan()`.
    private(set) var pairingCode: PairingCode?
    /// User-facing copy for the last failed scan, per the pairing failure
    /// taxonomy's parse step. Cleared by a successful scan or `rescan()`.
    private(set) var scanFailureMessage: String?

    func submit(scannedCode: String) {
        guard pairingCode == nil else { return }
        do {
            pairingCode = try PairingCode.decode(scannedCode)
            scanFailureMessage = nil
        } catch {
            scanFailureMessage = Self.message(for: error)
        }
    }

    /// Back to a fresh scanning state (the "Scan Again" action).
    func rescan() {
        pairingCode = nil
        scanFailureMessage = nil
    }

    private static func message(for error: PairingCodeError) -> String {
        switch error {
        case .badPrefix:
            "That QR code is not a herdr Pairing Code."
        case .unsupportedVersion(let found):
            "This Pairing Code uses version \(found), which this app does not "
                + "understand. Update the app and the pairing plugin so they match."
        case .badEncoding, .badPayload:
            "The Pairing Code could not be read. Regenerate it in herdr and scan again."
        }
    }
}
