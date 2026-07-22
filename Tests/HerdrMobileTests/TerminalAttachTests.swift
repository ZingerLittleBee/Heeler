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
@Suite("Terminal attach bootstrap line")
struct TerminalAttachTests {
    @MainActor
    @Test func attachUsesOnlyTheIOSSystemKeyboard() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        #expect(terminal.inputView == nil)
        #expect(terminal.inputAccessoryView == nil)
        #expect(terminal.keyboardDismissMode == .interactive)
    }

    @MainActor
    @Test func alternateScreenVerticalDragSendsPageCommands() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
        var sent = Data()
        let coordinator = TerminalScreenView.Coordinator(
            onSizeChanged: nil,
            onSend: { sent.append($0) })
        terminal.terminalDelegate = coordinator

        terminal.feed(text: "\u{1B}[?1049h")
        #expect(!terminal.scrollAlternateScreen(translationY: 20))
        #expect(terminal.scrollAlternateScreen(translationY: 160))
        #expect(sent == Data([0x1B, 0x5B, 0x35, 0x7E]))

        sent.removeAll()
        #expect(terminal.scrollAlternateScreen(translationY: -160))
        #expect(sent == Data([0x1B, 0x5B, 0x36, 0x7E]))

        sent.removeAll()
        terminal.feed(text: "\u{1B}[?1049l")
        #expect(!terminal.scrollAlternateScreen(translationY: 160))
        #expect(sent.isEmpty)
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
