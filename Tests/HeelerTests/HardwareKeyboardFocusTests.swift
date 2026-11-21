import Testing

@testable import Heeler

/// With a hardware keyboard attached an Agent opens ready to type, where on
/// touch it opens with the keyboard down (#646). `GCKeyboard.coalesced` is
/// never nil on the Simulator, so each test says whether one is attached.
@MainActor
@Suite("Hardware keyboard focus", .serialized)
struct HardwareKeyboardFocusTests {
    // MARK: The rule

    @Test func anAttachedKeyboardOpensAgentsFocusedUntilTheKeyboardIsPutAway() {
        #expect(!TerminalKeyboardHandoff().opensFocused)

        let keyboard = AttachedKeyboard(isAttached: false)
        let handoff = TerminalKeyboardHandoff(hardwareKeyboard: HardwareKeyboard { keyboard.isAttached })
        #expect(!handoff.opensFocused)
        keyboard.isAttached = true
        #expect(handoff.opensFocused)

        handoff.keyboardWasPutAway()
        #expect(!handoff.opensFocused)
        // Raised again, or a keyboard just connected.
        handoff.keyboardCameUp()
        #expect(handoff.opensFocused)
    }

    /// An Agent's screen rebuilt under a sheet leaves the keys with the
    /// sheet, where the user is typing.
    @Test func aSheetOverTheAgentKeepsTheKeyboard() {
        let handoff = TerminalKeyboardHandoff(hardwareKeyboard: HardwareKeyboard { true })
        handoff.isCovered = { true }
        #expect(!handoff.opensFocused)
        handoff.isCovered = { false }
        #expect(handoff.opensFocused)
    }
}

@MainActor
private final class AttachedKeyboard {
    var isAttached: Bool

    init(isAttached: Bool) {
        self.isAttached = isAttached
    }
}
