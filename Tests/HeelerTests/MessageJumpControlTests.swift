import Foundation
import Testing
import UIKit

@testable import Heeler

struct MessageJumpControlTests {
    @Test func availabilityRequiresAlternateScreen() {
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: false,
                agentStatus: .idle,
                isRunning: false)
                == MessageJumpControlAvailability(isVisible: false, isEnabled: false))
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                agentStatus: .idle,
                isRunning: false)
                == MessageJumpControlAvailability(isVisible: true, isEnabled: true))
    }

    @Test func availabilityDisablesWhileWorkingOrRunning() {
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                agentStatus: .working,
                isRunning: false).isEnabled)
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                agentStatus: .idle,
                isRunning: true).isEnabled)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                agentStatus: .blocked,
                isRunning: false).isEnabled)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                agentStatus: .done,
                isRunning: false).isEnabled)
    }

    @Test func noticeCopyStaysQuietForFoundAndCancelled() {
        #expect(
            MessageJumpNotice.text(for: .found, askingForOlder: true) == nil)
        #expect(
            MessageJumpNotice.text(for: .cancelled, askingForOlder: false) == nil)
        #expect(
            MessageJumpNotice.text(for: .reachedEnd, askingForOlder: true)
                == "No earlier message")
        #expect(
            MessageJumpNotice.text(for: .reachedEnd, askingForOlder: false)
                == "Back at live output")
        #expect(
            MessageJumpNotice.text(for: .exhausted, askingForOlder: true)
                == "Couldn't find the message")
    }
}

@MainActor
struct TerminalScrollControlTests {
    @Test func scrollRowsEmitsRemoteWheelOnAlternateScreenWithMouseTracking() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows = rows
            })
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(control.isAlternateScreen)

        control.scrollRows(towardOlderContent: true, rows: 6)
        #expect(scrolledSequence == Data("\u{1B}[<64;40;12M".utf8))
        #expect(scrolledRows == 6)

        scrolledSequence = Data()
        scrolledRows = 0
        control.scrollRows(towardOlderContent: false, rows: 3)
        #expect(scrolledSequence == Data("\u{1B}[<65;40;12M".utf8))
        #expect(scrolledRows == 3)
    }

    @Test func scrollRowsEmitsCursorKeysOnAlternateScreenWithoutMouseTracking() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows = rows
            })
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrolledSequence == Data([0x1B, 0x5B, 0x41]))
        #expect(scrolledRows == 2)

        scrolledSequence = Data()
        control.scrollRows(towardOlderContent: false, rows: 2)
        #expect(scrolledSequence == Data([0x1B, 0x5B, 0x42]))
    }

    @Test func scrollRowsTakesLocalBranchOnPrimaryScreen() {
        var scrollCalls = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, _ in scrollCalls += 1 })
        let control = TerminalScrollControl()
        control.terminal = terminal

        #expect(!control.isAlternateScreen)
        control.scrollRows(towardOlderContent: true, rows: 4)
        // Primary screen has no remote sequence; the local binding path does
        // not call onScroll.
        #expect(scrollCalls == 0)
    }

    @Test func scrollRowsLeavesTheTouchAccumulatorAlone() {
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, rows in scrolledRows += rows })
        let control = TerminalScrollControl()
        control.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))

        // Half a row at the default 16 pt cell height — remainder must survive
        // a chrome-driven scrollRows call.
        #expect(terminal.scrollTouch(translationY: 8) == 0)
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrolledRows == 2)
        scrolledRows = 0
        #expect(terminal.scrollTouch(translationY: 8) == 1)
        #expect(scrolledRows == 1)
    }

    @Test func isAlternateScreenSyncsFromTheSurfaceAndClearsOnRelease() {
        let control = TerminalScrollControl()
        #expect(!control.isAlternateScreen)

        let terminal = TerminalScreenView.makeConfiguredTerminal()
        control.terminal = terminal
        #expect(!control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        #expect(control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049l".utf8))
        #expect(!control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        #expect(control.isAlternateScreen)
        control.terminal = nil
        #expect(!control.isAlternateScreen)
    }

    @Test func wiringFeedsViewportTextToTheJumpController() {
        let wiring = AgentMessageJumpWiring()
        // The controller is a stub on this branch; calling frameDidChange must
        // still be legal and cheap while no jump is running.
        wiring.controller.frameDidChange("hello")
        #expect(!wiring.controller.isRunning)
        wiring.resetSession()
        #expect(!wiring.controller.isRunning)
    }
}
