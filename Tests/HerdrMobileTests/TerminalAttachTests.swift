import Foundation
import Testing
import UIKit

@testable import HerdrMobile

/// The attach bootstrap line (#11): the command typed into the PTY channel's
/// login shell. It must `exec` the attach process (so its exit ends the
/// channel), pin the herdr CLI to the Host's socket via `HERDR_SOCKET_PATH`
/// (a named-session target is "not found" on the default socket), quote the
/// target and socket safely for POSIX shells and fish alike, and refuse
/// targets that cannot be quoted safely for both.
@Suite("Terminal attach")
struct TerminalAttachTests {
    @MainActor
    @Test func attachStartsWithTheIOSInputMethodAndKeyboardSwitcher() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        #expect(terminal.keyboardMode == .text)
        #expect(terminal.inputView == nil)
        #expect(terminal.inputAccessoryView is TerminalKeyboardAccessory)
    }

    @MainActor
    @Test func attachSwitchesBetweenTextAndTerminalKeys() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()

        terminal.setKeyboardMode(.controls)
        #expect(terminal.keyboardMode == .controls)
        #expect(terminal.inputView is TerminalControlKeyboardView)

        terminal.setKeyboardMode(.text)
        #expect(terminal.keyboardMode == .text)
        #expect(terminal.inputView == nil)
    }

    @MainActor
    @Test func terminalKeysReuseTheMeasuredSystemKeyboardHeight() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.recordTextKeyboardHeight(totalHeight: 336, accessoryHeight: 48)
        terminal.recordTextKeyboardHeight(totalHeight: 48, accessoryHeight: 48)

        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.inputView as? TerminalControlKeyboardView)
        #expect(keyboard.intrinsicContentSize.height == 288)
        #expect(keyboard.frame.height == 288)
    }

    @Test func terminalControlKeyboardContainsOnlyUsefulMobileKeys() {
        #expect(
            TerminalControlKey.rows == [
                [.escape, .tab, .controlC, .controlD, .controlZ],
                [.home, .pageUp, .up, .pageDown, .end],
                [.backspace, .left, .down, .right, .enter],
            ])
    }

    @Test func terminalControlKeysEncodeExpectedBytes() {
        #expect(TerminalControlKey.escape.bytes(applicationCursor: false) == [0x1B])
        #expect(TerminalControlKey.tab.bytes(applicationCursor: false) == [0x09])
        #expect(TerminalControlKey.controlC.bytes(applicationCursor: false) == [0x03])
        #expect(TerminalControlKey.controlD.bytes(applicationCursor: false) == [0x04])
        #expect(TerminalControlKey.controlZ.bytes(applicationCursor: false) == [0x1A])
        #expect(TerminalControlKey.backspace.bytes(applicationCursor: false) == [0x7F])
        #expect(TerminalControlKey.enter.bytes(applicationCursor: false) == [0x0D])
        #expect(TerminalControlKey.up.bytes(applicationCursor: false) == [0x1B, 0x5B, 0x41])
        #expect(TerminalControlKey.up.bytes(applicationCursor: true) == [0x1B, 0x4F, 0x41])
        #expect(
            TerminalControlKey.pageUp.bytes(applicationCursor: false) == [
                0x1B, 0x5B, 0x35, 0x7E,
            ])
    }

    @MainActor
    @Test func terminalControlKeysFlowThroughTheGhosttySession() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })

        terminal.sendControlKey(.controlC)
        await Task.yield()
        #expect(sent == Data([0x03]))

        sent.removeAll()
        terminal.receive(Data("\u{1B}[?1h".utf8))
        terminal.sendControlKey(.up)
        await Task.yield()
        #expect(sent == Data([0x1B, 0x4F, 0x41]))
    }

    @Test func cursorModeTrackerHandlesSplitAndRepeatedModeChanges() {
        var tracker = TerminalCursorModeTracker()
        tracker.receive(Data([0x1B, 0x5B]))
        tracker.receive(Data([0x3F, 0x31, 0x68]))
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("noise\u{1B}[?1lmore\u{1B}[?1h".utf8))
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("\u{1B}[?1l".utf8))
        #expect(!tracker.usesApplicationCursorKeys)
    }

    @MainActor
    @Test func terminalSelectionRejectsOutOfBoundsAnchorRanges() {
        #expect(
            TerminalTextSelectionViewController.normalizedSelectionRange(
                NSRange(location: 2, length: 3), textLength: 8)
                == NSRange(location: 2, length: 3))
        #expect(
            TerminalTextSelectionViewController.normalizedSelectionRange(
                NSRange(location: 7, length: 4), textLength: 8)
                == NSRange(location: 0, length: 8))
        #expect(
            TerminalTextSelectionViewController.normalizedSelectionRange(
                nil, textLength: 8)
                == NSRange(location: 0, length: 8))
    }

    @Test func execsTheAttachCommandWithQuotedTargetAndSocketScope() throws {
        let line = try SSHTransport.attachBootstrapLine(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/home/u/.config/herdr/sessions/dev/herdr.sock")
        #expect(
            line == "exec /bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
                + "exec herdr agent attach \"$1\"' attach "
                + "'w1:p1' '/home/u/.config/herdr/sessions/dev/herdr.sock'\n")
    }

    @Test func takeoverAppendsHerdrsFlag() throws {
        let line = try SSHTransport.attachBootstrapLine(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(target: "w1:p1", takeover: true, cols: 80, rows: 24),
            socketPath: "/home/u/.config/herdr/herdr.sock")
        #expect(
            line == "exec /bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
                + "exec herdr agent attach \"$1\" --takeover' attach "
                + "'w1:p1' '/home/u/.config/herdr/herdr.sock'\n")
    }

    @Test func injectableAttachCommandRidesThrough() throws {
        // Tests substitute a script at the environment boundary, like the
        // wake command.
        let line = try SSHTransport.attachBootstrapLine(
            attachCommand: "/bin/sh /tmp/fake-attach.sh",
            request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
            socketPath: "/tmp/fake.sock")
        #expect(
            line == "exec /bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
                + "exec /bin/sh /tmp/fake-attach.sh \"$1\"' attach "
                + "'w1:p1' '/tmp/fake.sock'\n")
    }

    @Test(arguments: [
        "", "w1'p1", #"w1\p1"#, "w1\np1", "w1\rp1", "w1\u{1B}p1",
    ])
    func unquotableTargetsAreRefused(target: String) {
        // A Pane id with quotes or control characters could only come from a
        // hostile server; refusing beats handing it a shell.
        #expect(throws: TransportError.self) {
            _ = try SSHTransport.attachBootstrapLine(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: target, cols: 80, rows: 24),
                socketPath: "/tmp/fake.sock")
        }
    }

    @Test func unquotableSocketPathsAreRefused() {
        #expect(throws: TransportError.self) {
            _ = try SSHTransport.attachBootstrapLine(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
                socketPath: "/tmp/it's-a.sock")
        }
    }

    @Test func sessionDropsEmptyKeystrokeWrites() async {
        // An empty write must not ride down the channel as an empty
        // SSH_MSG_CHANNEL_DATA.
        let transport = ScriptedTransport()
        let session = try? await transport.attachTerminal(
            TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
        session?.send(Data())
        session?.send(Data("x".utf8))
        await session?.end()
        let inputs = await transport.attachInputs
        #expect(inputs == [.keystrokes(Data("x".utf8))])
    }
}
