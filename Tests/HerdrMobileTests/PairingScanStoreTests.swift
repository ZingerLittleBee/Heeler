import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Pairing scan store")
struct PairingScanStoreTests {
    /// A canonical config-only code from the shared vectors, so the store
    /// tests ride on the same source of truth as the decoder tests.
    private static let validCode = PairingCodeVectorFile.shared.valid[0].code

    @Test func parsesAScannedPairingCode() throws {
        let store = PairingScanStore()

        store.submit(scannedCode: Self.validCode)

        let code = try #require(store.pairingCode)
        #expect(code == (try PairingCode.decode(Self.validCode)))
        #expect(store.scanFailureMessage == nil)
    }

    @Test func foreignQRCodesAskForTheHerdrPairingCode() {
        let store = PairingScanStore()

        store.submit(scannedCode: "https://example.com/some-other-qr")

        #expect(store.pairingCode == nil)
        let message = store.scanFailureMessage
        #expect(message?.contains("not a herdr Pairing Code") == true)
    }

    @Test func unsupportedVersionsNameTheVersionAndAskForAnUpdate() {
        let store = PairingScanStore()

        store.submit(scannedCode: "HERDR-PAIR:2:eyJhZGRycyI6WyIxOTIuMTY4LjEuNDIiXX0")

        #expect(store.pairingCode == nil)
        let message = store.scanFailureMessage
        #expect(message?.contains("version 2") == true)
        #expect(message?.contains("Update") == true)
    }

    @Test func corruptCodesAskForRegeneration() {
        let store = PairingScanStore()

        store.submit(scannedCode: "HERDR-PAIR:1:!!!corrupt!!!")

        #expect(store.pairingCode == nil)
        #expect(store.scanFailureMessage?.contains("Regenerate") == true)
    }

    @Test func aGoodScanClearsAnEarlierFailure() throws {
        let store = PairingScanStore()
        store.submit(scannedCode: "HERDR-PAIR:1:!!!corrupt!!!")

        store.submit(scannedCode: Self.validCode)

        #expect(store.pairingCode != nil)
        #expect(store.scanFailureMessage == nil)
    }

    @Test func furtherScansAreIgnoredOnceACodeParsed() throws {
        let store = PairingScanStore()
        store.submit(scannedCode: Self.validCode)
        let first = try #require(store.pairingCode)

        store.submit(scannedCode: "HERDR-PAIR:1:!!!corrupt!!!")

        #expect(store.pairingCode == first)
        #expect(store.scanFailureMessage == nil)
    }

    @Test func rescanReturnsToAFreshScanningState() {
        let store = PairingScanStore()
        store.submit(scannedCode: Self.validCode)

        store.rescan()

        #expect(store.pairingCode == nil)
        #expect(store.scanFailureMessage == nil)
    }
}
