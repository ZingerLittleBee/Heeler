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
    @Test func keyboardAccessoryExposesSystemPasteControlInBothModes() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)

        #expect(accessory.pasteControl.target === terminal)
        #expect(accessory.pasteControl.accessibilityLabel == "Paste")
        #expect(accessory.pasteControl.isEnabled)

        terminal.setKeyboardMode(.controls)
        #expect(accessory.pasteControl.isDescendant(of: accessory))
    }

    @MainActor
    @Test func pasteControlAndHardwarePasteUseTheReviewedPasteCallback() {
        var pastes: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onPaste: { text, _ in pastes.append(text) })

        terminal.requestPaste("one\n two")
        #expect(pastes == ["one\n two"])

        terminal.setLocalInputEnabled(false)
        terminal.requestPaste("blocked")
        #expect(pastes == ["one\n two"])
        #expect(
            (terminal.inputAccessoryView as? TerminalKeyboardAccessory)?
                .pasteControl.isEnabled == false)
    }

    @MainActor
    @Test func systemPasteControlLoadsTextFromItsItemProvider() async throws {
        var pastes: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onPaste: { text, _ in pastes.append(text) })

        terminal.paste(
            itemProviders: [NSItemProvider(object: "provider paste" as NSString)])
        let deadline = ContinuousClock.now + .seconds(2)
        while pastes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(pastes == ["provider paste"])
    }

    @MainActor
    @Test func pausedTerminalControlsDoNotEmitInput() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })

        terminal.setLocalInputEnabled(false)
        terminal.sendControlKey(.enter)
        await Task.yield()

        #expect(sent.isEmpty)
    }

    @MainActor
    @Test func terminalTouchPolicyKeepsKeyboardBehindTheCurrentInputRow() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)

        #expect(!terminal.canBecomeFirstResponder)
        #expect(
            terminal.gestureRecognizers?.contains { gesture in
                guard let pan = gesture as? UIPanGestureRecognizer else { return false }
                return pan.allowedTouchTypes.contains(
                    directTouch)
            } == true)
        #expect(
            terminal.gestureRecognizers?.contains { gesture in
                guard let tap = gesture as? UITapGestureRecognizer else { return false }
                return tap.isEnabled && tap.allowedTouchTypes.contains(directTouch)
            } == true)

        terminal.requestKeyboard()
        #expect(terminal.canBecomeFirstResponder)

        terminal.dismissKeyboard()
        #expect(!terminal.canBecomeFirstResponder)
    }

    /// UIKit resigns the first responder on its own — backgrounding the app,
    /// presenting a sheet — and restores it afterwards by asking the view to
    /// become first responder again. If those resigns also cleared the user's
    /// intent, the view would refuse, and the accessory bar would come back
    /// with no keyboard behind it and no way to type (the >20s-in-background
    /// report). Only an explicit dismiss ends the session.
    @MainActor
    @Test func aSystemResignLeavesTheKeyboardRecoverable() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.requestKeyboard()

        _ = terminal.resignFirstResponder()

        #expect(terminal.canBecomeFirstResponder)
    }

    /// Ghostty's `UITerminalView` raises the keyboard from `touchesBegan` and
    /// takes it down from `touchesEnded` — on any body touch. Once the user
    /// had raised the keyboard once, that turned every body tap into a
    /// keyboard toggle, bypassing the input-row policy entirely. Responder
    /// changes arriving mid-touch are Ghostty's and are refused; the same
    /// requests pass again once the touch ends (UIKit's restore path).
    @MainActor
    @Test func bodyTouchesCannotToggleTheKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        window.addSubview(terminal)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        terminal.requestKeyboard()
        #expect(terminal.isFirstResponder)

        // Ghostty's touchesEnded dismisses the keyboard after any body tap;
        // that resign lands mid-touch and must be refused.
        let touch = UITouch()
        terminal.touchesBegan([touch], with: nil)
        #expect(!terminal.resignFirstResponder())
        #expect(terminal.isFirstResponder)
        // A short backgrounding hides the keyboard but keeps the first
        // responder, and UIKit answers a re-assert on the current first
        // responder without consulting canBecomeFirstResponder. The override
        // swallows it mid-touch; the swallowed re-present itself is only
        // observable on a device, so this pins down status and return value.
        #expect(terminal.becomeFirstResponder())
        #expect(terminal.isFirstResponder)
        terminal.touchesEnded([touch], with: nil)

        // A UIKit-style resign outside any touch still goes through, keeping
        // sheets and backgrounding working.
        _ = terminal.resignFirstResponder()
        #expect(!terminal.isFirstResponder)

        // Ghostty's touchesBegan re-raises the keyboard on the next body tap;
        // with no user request driving it the surface refuses.
        terminal.touchesBegan([touch], with: nil)
        #expect(!terminal.becomeFirstResponder())
        terminal.touchesEnded([touch], with: nil)

        // Outside the touch, UIKit's restore-after-resign path still passes.
        #expect(terminal.canBecomeFirstResponder)
    }

    @Test func responderGateRefusesGhosttysTouchDrivenChanges() {
        var gate = TerminalKeyboardResponderGate()
        gate.beginUserDrivenChange(wantsKeyboard: true)
        gate.endUserDrivenChange()

        gate.directTouchesBegan(1)
        #expect(!gate.mayBecomeFirstResponder)
        #expect(!gate.mayResignFirstResponder)

        gate.directTouchesEnded(1)
        #expect(gate.mayBecomeFirstResponder)
        #expect(gate.mayResignFirstResponder)
    }

    /// The input-row tap and the accessory's dismiss button both fire while
    /// their own touch may still be active, so user-driven changes pass the
    /// gate mid-touch.
    @Test func responderGatePassesUserDrivenChangesMidTouch() {
        var gate = TerminalKeyboardResponderGate()
        gate.directTouchesBegan(1)

        gate.beginUserDrivenChange(wantsKeyboard: true)
        #expect(gate.mayBecomeFirstResponder)
        gate.endUserDrivenChange()

        gate.beginUserDrivenChange(wantsKeyboard: false)
        #expect(gate.mayResignFirstResponder)
        gate.endUserDrivenChange()

        #expect(!gate.mayBecomeFirstResponder)
    }

    @Test func keyboardTapTargetCoversOnlyTheCurrentInputRow() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.region(
            caretRect: CGRect(x: 72, y: 650, width: 9, height: 20),
            in: bounds)

        #expect(region == CGRect(x: 0, y: 638, width: 390, height: 44))
        #expect(region.contains(CGPoint(x: 20, y: 660)))
        #expect(!region.contains(CGPoint(x: 20, y: 500)))
    }

    @MainActor
    @Test func ghosttyCursorProvidesAVisibleKeyboardTapTarget() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.frame = terminal.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        terminal.receive(Data("$ ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        #expect(!terminal.keyboardActivationRegion.isNull)
        #expect(terminal.bounds.contains(terminal.keyboardActivationRegion))
    }

    /// The shell above is not what Attach actually shows: every agent is a
    /// full-screen TUI that takes the alternate screen and grabs the mouse, and
    /// the keyboard has exactly one entry point. If the cursor stopped yielding
    /// a caret under those modes the target would silently vanish, and the only
    /// symptom would be a user tapping a terminal that never answers.
    @MainActor
    @Test func aMouseGrabbingTUIStillOffersTheKeyboardTapTarget() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.frame = terminal.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // Alternate screen + SGR mouse tracking, then a prompt parked on a low
        // row: an agent's input box, in as few bytes as it takes.
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        terminal.receive(Data("\u{1B}[20;3H> ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        let region = terminal.keyboardActivationRegion
        #expect(!region.isNull)
        #expect(terminal.bounds.contains(region))
        // Thumb-sized, or the single entry point is unhittable in practice.
        #expect(region.height >= TerminalKeyboardTapTarget.minimumHeight)
        // Full width: the row is the target, not the glyph the cursor sits on.
        #expect(region.width == terminal.bounds.width)
    }

    /// #90: the 44 pt band sits on the caret, and an agent TUI parks its caret
    /// below the prompt the user actually reads. Aiming at Claude Code's `>`
    /// missed four times running in a real session, so the whole surface has to
    /// answer once the alternate screen is up — there is no native scrollback
    /// left to protect there.
    @MainActor
    @Test func anyTapRaisesTheKeyboardOnceATUIOwnsTheScreen() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let farFromTheCaret = CGPoint(x: 195, y: 120)

        #expect(terminal.tapAction(at: farFromTheCaret) == .report(raisesKeyboard: false))

        terminal.receive(Data("\u{1B}[?1049h".utf8))

        #expect(terminal.tapAction(at: farFromTheCaret) == .report(raisesKeyboard: true))
    }

    /// The normal buffer keeps the old contract: scrollback is scrolled by
    /// touch, and a stray tap must not answer with a viewport resize.
    @MainActor
    @Test func theNormalBufferStillOnlyAnswersTheInputRow() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1049l".utf8))

        #expect(terminal.tapAction(at: CGPoint(x: 195, y: 120)) == .report(raisesKeyboard: false))
    }

    /// Tapping to stop a flick is the oldest gesture on the platform. Now that
    /// a tap can raise the keyboard, that tap must be spent on the halt alone —
    /// otherwise stopping a scroll costs you the bottom half of the screen.
    @MainActor
    @Test func theTapThatHaltsAFlickDoesNothingElse() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        terminal.receive(Data("\u{1B}[?1049h".utf8))

        terminal.startTouchScrollMomentum(velocityY: 2_000)
        #expect(terminal.isTouchScrollMomentumRunning)

        // The same tap that raises the keyboard in the test above.
        terminal.handleTap(at: CGPoint(x: 195, y: 120))

        #expect(!terminal.isTouchScrollMomentumRunning)
        #expect(!terminal.canBecomeFirstResponder)
    }

    @MainActor
    @Test func terminalTouchPanEmitsRemoteTUIMouseWheelInput() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let enabledTouchPans: [UIPanGestureRecognizer] =
            terminal.gestureRecognizers?.compactMap { gesture in
                guard let pan = gesture as? UIPanGestureRecognizer,
                    pan.isEnabled,
                    pan.allowedTouchTypes.contains(directTouch)
                else { return nil }
                return pan
            } ?? []
        #expect(enabledTouchPans.count == 1)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(terminal.scrollTouch(translationY: 32) == 2)
        await Task.yield()

        #expect(
            sent == Data("\u{1B}[<64;40;12M\u{1B}[<64;40;12M".utf8))
    }

    @MainActor
    @Test func attachSwitchesBetweenTextAndTerminalKeys() {
        let terminal = TerminalScreenView.makeConfiguredTerminal()

        terminal.setKeyboardMode(.controls)
        #expect(terminal.keyboardMode == .controls)
        #expect(terminal.inputView is TerminalKeysKeyboardView)

        terminal.setKeyboardMode(.text)
        #expect(terminal.keyboardMode == .text)
        #expect(terminal.inputView == nil)
    }

    /// The dismiss button is the only way out of the keyboard, so it must
    /// work even when the accessory has outlived its terminal's first
    /// responder status.
    @MainActor
    @Test func dismissButtonTakesTheKeyboardDownFromTheAccessory() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        window.addSubview(terminal)
        window.makeKeyAndVisible()
        terminal.requestKeyboard()
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)
        let dismiss = try #require(
            accessory.subviews.compactMap { $0 as? UIButton }.first {
                $0.accessibilityLabel == "Dismiss keyboard"
            })

        dismiss.sendActions(for: .touchUpInside)
        #expect(!terminal.isFirstResponder)

        // Stranded accessory: no first responder left to ask, and the button
        // must still be a no-crash no-op rather than a dead end.
        dismiss.sendActions(for: .touchUpInside)
        #expect(!terminal.isFirstResponder)
    }

    @MainActor
    @Test func terminalKeysReuseTheMeasuredSystemKeyboardHeight() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.recordTextKeyboardHeight(totalHeight: 336, accessoryHeight: 48)
        terminal.recordTextKeyboardHeight(totalHeight: 48, accessoryHeight: 48)

        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.inputView as? TerminalKeysKeyboardView)
        #expect(keyboard.intrinsicContentSize.height == 288)
        #expect(keyboard.frame.height == 288)
    }

    @Test func terminalControlKeyboardContainsOnlyUsefulMobileKeys() {
        #expect(
            TerminalControlKey.rows == [
                [.escape, .tab, .controlC, .controlD, .backspace],
                [.home, .pageUp, .up, .pageDown, .end],
                [.controlZ, .left, .down, .right, .enter],
            ])
        // Every row is the same width, so no key ends up wider than its
        // neighbours just because a row was left short.
        #expect(Set(TerminalControlKey.rows.map(\.count)).count == 1)
        // Rearranging the rows must not quietly drop a key on the floor.
        let placed = TerminalControlKey.rows.flatMap { $0 }
        #expect(placed.count == TerminalControlKey.allCases.count)
        for key in TerminalControlKey.allCases {
            #expect(placed.contains(key), "\(key) fell off the keyboard")
        }
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

    @Test func terminalModeTrackerHandlesSplitAndRepeatedModeChanges() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data([0x1B, 0x5B]))
        tracker.receive(Data([0x3F, 0x31, 0x68]))
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("noise\u{1B}[?1lmore\u{1B}[?1h".utf8))
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("\u{1B}[?1l".utf8))
        #expect(!tracker.usesApplicationCursorKeys)
    }

    @Test func terminalModeTrackerEncodesMouseAndAlternateScreenScrolling() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?1049h\u{1B}[?1002;1006h".utf8))

        #expect(tracker.isAlternateScreen)
        #expect(tracker.tracksMouse)
        #expect(tracker.usesSGRMouseEncoding)
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: true,
                columns: 80,
                rows: 24)
                == Data("\u{1B}[<64;40;12M".utf8))

        tracker.receive(Data("\u{1B}[?1002;1006l".utf8))
        #expect(!tracker.tracksMouse)
        #expect(!tracker.usesSGRMouseEncoding)
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: false,
                columns: 80,
                rows: 24)
                == Data([0x1B, 0x5B, 0x42]))

        tracker.receive(Data("\u{1B}[?1049l".utf8))
        #expect(
            tracker.remoteScrollSequence(
                towardOlderContent: true,
                columns: 80,
                rows: 24) == nil)
    }

    @Test func touchScrollAccumulatorPreservesSubrowMovementAndDirectionChanges() {
        var accumulator = TerminalTouchScrollAccumulator()

        #expect(accumulator.rows(for: 7, pointsPerRow: 16) == 0)
        #expect(accumulator.rows(for: 10, pointsPerRow: 16) == 1)
        #expect(accumulator.rows(for: -15, pointsPerRow: 16) == 0)
        #expect(accumulator.rows(for: -2, pointsPerRow: 16) == -1)
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
