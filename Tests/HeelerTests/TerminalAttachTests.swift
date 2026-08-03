import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The attach bootstrap line (#11): the command typed into the PTY channel's
/// login shell. It must `exec` the attach process (so its exit ends the
/// channel), pin the herdr CLI to the Host's socket via `HERDR_SOCKET_PATH`
/// (a named-session target is "not found" on the default socket), quote the
/// target and socket safely for POSIX shells and fish alike, and refuse
/// targets that cannot be quoted safely for both.
@Suite("Terminal attach")
struct TerminalAttachTests {
    private enum WriterProbeError: Error {
        case rejectedResize
    }

    @Test func writerPropagatesResizeFailure() async {
        let input = TerminalAttachInputQueue()
        input.resize(cols: 120, rows: 40)

        await #expect(throws: WriterProbeError.self) {
            try await SSHTransport.writeTerminalAttachInput(
                input,
                write: { _ in },
                resize: { _, _ in throw WriterProbeError.rejectedResize })
        }
    }

    /// A slow SSH writer must not let lossy momentum-scroll input hold
    /// reliable keyboard input hostage. Sixty rows model one ordinary flick;
    /// the 20 ms drain delay makes the old unbounded FIFO take about 1.2 s.
    @MainActor
    @Test func weakNetworkScrollBacklogDoesNotDelayKeyboardInput() async throws {
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        let session = TerminalAttachSession(
            output: output,
            input: input,
            ender: { outputContinuation.finish() })
        let inputController = TerminalInputController()
        let generation = inputController.beginSession(
            writer: { session.send($0) },
            scroller: { sequence, rows in session.scroll(sequence, rows: rows) })
        defer { inputController.endSession(generation) }

        let marker = Data("x".utf8)
        var markerArrival: ContinuousClock.Instant?
        let writer = Task { @MainActor in
            while let item = await input.next() {
                switch item {
                case .keystrokes(let data):
                    if data == marker {
                        markerArrival = .now
                        return
                    }
                case .scroll:
                    try? await Task.sleep(for: .milliseconds(20))
                case .resize:
                    break
                }
            }
        }
        defer { writer.cancel() }

        var emitted = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { inputController.send($0) },
            onScroll: { sequence, rows in
                emitted += rows
                inputController.scroll(sequence, rows: rows)
            })
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(terminal.scrollTouch(translationY: 960) == 60)
        #expect(emitted == 60)

        let typedAt = ContinuousClock.now
        terminal.terminalSession.sendInput(marker)
        let arrivalDeadline = typedAt + .seconds(3)
        while markerArrival == nil, ContinuousClock.now < arrivalDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        let arrivedAt = try #require(markerArrival)
        let latency = typedAt.duration(to: arrivedAt)
        #expect(
            latency < .milliseconds(250),
            "keyboard input waited behind scroll backlog: \(latency)")
        await session.end()
    }

    @Test func reliableInputDiscardsPendingScrollMomentum() async {
        let input = TerminalAttachInputQueue()
        let scroll = Data("scroll".utf8)
        let key = Data("x".utf8)

        input.scroll(scroll, rows: 60)
        input.send(key)

        #expect(await input.next() == .keystrokes(key))
        input.finish()
        #expect(await input.next() == nil)
    }

    @Test func scrollDirectionChangeReplacesPendingMomentum() async {
        let input = TerminalAttachInputQueue()
        let older = Data("older".utf8)
        let newer = Data("newer".utf8)

        input.scroll(older, rows: 8)
        input.scroll(newer, rows: 2)

        #expect(await input.next() == .scroll(newer + newer))
        input.finish()
    }

    @Test func scrollBacklogIsBoundedAndWrittenInSmallBatches() async {
        let input = TerminalAttachInputQueue()
        let sequence = Data("wheel".utf8)
        let batch = sequence + sequence + sequence

        input.scroll(sequence, rows: 60)

        for _ in 0..<4 {
            #expect(await input.next() == .scroll(batch))
        }
        input.finish()
        #expect(await input.next() == nil)
    }

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
    @Test func keyboardAccessoryInsertsANewLineWithoutSubmitting() async throws {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)

        #expect(accessory.newLineButton.configuration?.image != nil)
        #expect(accessory.newLineButton.configuration?.title == nil)
        #expect(accessory.newLineButton.accessibilityLabel == "Insert New Line")
        accessory.newLineButton.sendActions(for: .touchUpInside)
        await Task.yield()
        #expect(sent == Data([0x0A]))

        sent.removeAll()
        terminal.setKeyboardMode(.controls)
        accessory.newLineButton.sendActions(for: .touchUpInside)
        await Task.yield()
        #expect(sent == Data([0x0A]))

        terminal.setLocalInputEnabled(false)
        #expect(!accessory.newLineButton.isEnabled)
        accessory.newLineButton.sendActions(for: .touchUpInside)
        await Task.yield()
        #expect(sent == Data([0x0A]))
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
    @Test func systemKeyboardPasteSynchronizesTheTextInputContext() {
        var events: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onPaste: { text, _ in events.append("paste:\(text)") })
        let inputDelegate = TextInputDelegateRecorder(events: { events.append($0) })
        terminal.inputDelegate = inputDelegate
        UIPasteboard.general.string = "keyboard suggestion"
        defer { UIPasteboard.general.items = [] }

        terminal.paste(nil)

        #expect(
            events == [
                "textWillChange",
                "paste:keyboard suggestion",
                "textDidChange",
            ])
    }

    @MainActor
    @Test func systemKeyboardBackspaceSynchronizesTheTextInputContext() async {
        var sent = Data()
        var events: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        let inputDelegate = TextInputDelegateRecorder(events: { events.append($0) })
        terminal.inputDelegate = inputDelegate

        terminal.terminalSession.sendInput(Data("abc".utf8))
        let insertDeadline = ContinuousClock.now + .seconds(1)
        while sent != Data("abc".utf8), ContinuousClock.now < insertDeadline {
            await Task.yield()
        }
        #expect(sent == Data("abc".utf8))
        sent.removeAll()
        events.removeAll()

        terminal.deleteBackward()
        let deleteDeadline = ContinuousClock.now + .seconds(1)
        while sent.isEmpty, ContinuousClock.now < deleteDeadline {
            await Task.yield()
        }

        #expect(sent == Data([0x7F]))
        #expect(
            events == [
                "textWillChange",
                "selectionWillChange",
                "selectionDidChange",
                "textDidChange",
            ])
        #expect(terminal.offset(
            from: terminal.beginningOfDocument,
            to: terminal.endOfDocument) == 2)
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

    /// The alternate-screen band stays caret-centred, just three times as
    /// tall — wide enough for the whole bordered input box #90 measured.
    @Test func alternateScreenTapTargetTriplesTheCaretBand() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.region(
            caretRect: CGRect(x: 72, y: 400, width: 9, height: 20),
            in: bounds,
            minimumHeight: TerminalKeyboardTapTarget.alternateScreenMinimumHeight)

        #expect(region == CGRect(x: 0, y: 344, width: 390, height: 132))
    }

    /// Every chat-style agent TUI pins its input box to the bottom rows, but
    /// each parks the caret somewhere of its own, so the bottom quarter is
    /// the tool-agnostic floor the caret band cannot be.
    @Test func alternateScreenBottomQuarterIsAlwaysATapTarget() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let region = TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: bounds)

        #expect(region == CGRect(x: 0, y: 540, width: 390, height: 180))
        #expect(TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: .zero).isNull)
    }

    @MainActor
    @Test func ghosttyCursorProvidesAVisibleKeyboardTapTarget() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        terminal.receive(Data("$ ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        #expect(!terminal.keyboardActivationRegion.isNull)
        #expect(terminal.bounds.contains(terminal.keyboardActivationRegion))
    }

    @MainActor
    @Test func renderedOutputReportsViewportTextToTheHost() async throws {
        var snapshots: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onViewportTextChanged: { snapshots.append($0) })
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        terminal.receive(
            Data("\u{001B}[2J\u{001B}[Hhttps://viewport.example/result\n".utf8))
        terminal.layoutIfNeeded()

        let deadline = ContinuousClock.now + .seconds(2)
        while !snapshots.contains(where: { $0.contains("https://viewport.example/result") }),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            snapshots.contains {
                $0.contains("https://viewport.example/result")
            })
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
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
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
        // Reaches the visible prompt above the parked caret (#90), or the
        // single entry point is unhittable in practice.
        #expect(region.height >= TerminalKeyboardTapTarget.alternateScreenMinimumHeight)
        // Full width: the row is the target, not the glyph the cursor sits on.
        #expect(region.width == terminal.bounds.width)
    }

    /// #90 measured Claude Code's visible `>` prompt 16–40 pt above the parked
    /// caret, so the alternate screen keeps the caret anchor but triples the
    /// band to cover the whole bordered input box. The output area stays
    /// inert: #92's whole-screen activation answered every output-area tap
    /// with a keyboard nobody asked for.
    @MainActor
    @Test func aTUITapRaisesTheKeyboardOnlyAroundItsInputBox() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        // A TUI on the alternate screen with its prompt parked on row 20.
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[20;3H> ".utf8))
        terminal.layoutIfNeeded()
        await Task.yield()

        let region = terminal.keyboardActivationRegion
        let insideTheBand = CGPoint(x: 195, y: region.midY)
        let outputArea = CGPoint(x: 195, y: 20)
        // Chat TUIs pin the input box to the bottom rows; a tap there must
        // answer even when the caret band sits elsewhere.
        let bottomQuarter = CGPoint(x: 195, y: 700)
        #expect(!region.contains(outputArea))
        #expect(terminal.tapAction(at: insideTheBand) == .report(raisesKeyboard: true))
        #expect(terminal.tapAction(at: outputArea) == .report(raisesKeyboard: false))
        #expect(terminal.tapAction(at: bottomQuarter) == .report(raisesKeyboard: true))
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
    @Test func terminalTouchPanEmitsSemanticRemoteTUIMouseWheelInput() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows += rows
            })
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

        #expect(scrolledSequence == Data("\u{1B}[<64;40;12M".utf8))
        #expect(scrolledRows == 2)
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

    /// The keyboard toggle rides the Agent strip, which outlives the keyboard,
    /// so it has to work both ways — and a dismissal has to leave the keyboard
    /// recoverable, or the toggle is a one-way trip out of typing.
    @MainActor
    @Test func theKeyboardToggleRaisesAndLowersTheTerminalsKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        window.addSubview(terminal)
        window.makeKeyAndVisible()
        let control = TerminalKeyboardControl()
        control.terminal = terminal

        #expect(!control.isKeyboardUp)
        control.toggleKeyboard()
        #expect(terminal.isFirstResponder)
        #expect(control.isKeyboardUp)

        control.toggleKeyboard()
        #expect(!terminal.isFirstResponder)
        #expect(!control.isKeyboardUp)

        control.toggleKeyboard()
        #expect(terminal.isFirstResponder)
    }

    /// An Agent switch rebuilds the terminal under the strip that survives it.
    /// A toggle still pointing at the replaced surface would raise a keyboard
    /// on a terminal that is no longer on screen.
    @MainActor
    @Test func theKeyboardToggleForgetsAReplacedTerminal() {
        let control = TerminalKeyboardControl()
        do {
            let replaced = TerminalScreenView.makeConfiguredTerminal()
            control.terminal = replaced
            #expect(control.terminal != nil)
        }
        #expect(control.terminal == nil)
        #expect(!control.isKeyboardUp)
        // Nothing to drive, and nothing to crash on.
        control.toggleKeyboard()
    }

    /// UIKit animates the keyboard away without taking the accessory's content
    /// with it, so the toolbar hung at the bottom of the screen after the
    /// keyboard had gone.
    @MainActor
    @Test func theKeyboardRowLeavesInSyncWithTheKeyboard() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        window.addSubview(terminal)
        window.makeKeyAndVisible()
        terminal.requestKeyboard()
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillHideNotification, object: nil,
            userInfo: [UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.0)])

        #expect(accessory.alpha == 1)
        #expect(accessory.transform == .identity)
        #expect(accessory.toolbarContentView.alpha == 0)
        #expect(
            accessory.toolbarContentView.transform.ty
                == TerminalKeyboardAccessory.preferredHeight)

        // Typing again puts it back, or the row would stay gone for good.
        terminal.requestKeyboard()
        #expect(accessory.toolbarContentView.alpha == 1)
        #expect(accessory.toolbarContentView.transform == .identity)
    }

    /// A SwiftUI update must not write back into the state that drove it.
    /// Reporting the viewport text from `updateUIView` fed the Attach Link
    /// index, whose observers include this very view, so every update queued
    /// the next one — measured on device at 18,871 updates in a few seconds,
    /// with the app wedged for as long as the terminal stayed on screen.
    /// Terminal output schedules its own snapshot (see
    /// `renderedOutputReportsViewportTextToTheHost`); nothing else may.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aSwiftUIUpdateDoesNotReportTheViewportBack() async throws {
        final class Counters {
            var updates = 0
            var reports = 0
        }
        struct Harness: View {
            let counters: Counters
            let keyboardControl: TerminalKeyboardControl
            let feed: TerminalByteFeed
            /// Some state the terminal is sized by, exactly as the keyboard
            /// inset is when the keyboard comes and goes.
            let fontSize: Float

            var body: some View {
                counters.updates += 1
                var screen = TerminalScreenView(feed: feed)
                screen.onViewportTextChanged = { _ in counters.reports += 1 }
                screen.keyboardControl = keyboardControl
                screen.fontSize = fontSize
                return screen
            }
        }

        let counters = Counters()
        let keyboardControl = TerminalKeyboardControl()
        let feed = TerminalByteFeed()
        func harness(fontSize: Float) -> Harness {
            Harness(
                counters: counters, keyboardControl: keyboardControl,
                feed: feed, fontSize: fontSize)
        }
        let controller = UIHostingController(rootView: harness(fontSize: 13))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        let rounds = 10
        for round in 1...rounds {
            controller.rootView = harness(fontSize: round.isMultiple(of: 2) ? 13 : 15)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
        }
        // Long enough for a snapshot one of those updates had scheduled to fire.
        try await Task.sleep(for: .milliseconds(200))

        // Every one of those rounds reached the terminal, and not one of them
        // asked it for its viewport.
        #expect(counters.updates > rounds)
        #expect(keyboardControl.terminal != nil, "the terminal never took an update")
        #expect(
            counters.reports == 0,
            "a SwiftUI update reported the viewport \(counters.reports) times")
    }

    /// A keyboard changing hands passes through several transient heights —
    /// both terminals' accessories ride it at once while it does. Forwarding
    /// each one to Ghostty and the remote PTY makes a full-screen TUI redraw
    /// per step, so only the settled geometry may escape the handoff.
    @MainActor
    @Test func aKeyboardHandoffCoalescesItsTransientGridsIntoOneResize() async throws {
        var reportedGrids: [(columns: Int, rows: Int)] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append((columns, rows))
            })
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        try await waitForGridReportsToSettle(&reportedGrids)
        let initialRows = try #require(reportedGrids.last?.rows)
        reportedGrids.removeAll()

        // The handoff itself: the replacement surface claims the keyboard as
        // it reaches the window, and freezes its grid until that settles.
        terminal.removeFromSuperview()
        terminal.raisesKeyboardWhenReady = true
        host.view.addSubview(terminal)

        for height: CGFloat in [440, 520, 600] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }

        #expect(reportedGrids.isEmpty)
        terminal.finishKeyboardTransitionLayout()
        try await waitForGridReportsToSettle(&reportedGrids)

        #expect(reportedGrids.count == 1)
        #expect(reportedGrids.last?.rows ?? 0 > initialRows)
    }

    /// A dismissal is the case that has to be exact, so it does not wait on
    /// anything: SwiftUI's own avoidance retracted in two stages, the second
    /// landing a third of a second after the keyboard had gone, which cost the
    /// terminal a second reflow, a second PTY resize, and a visibly late TUI
    /// redraw.
    @MainActor
    @Test func aDismissalDropsTheKeyboardInsetInOneStep() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await Task.sleep(for: .milliseconds(120))
        #expect(inset.height == 402)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
    }

    /// Backgrounding hides the keyboard — animating the accessory out — but
    /// leaves the first responder in place, so the re-presentation on return
    /// never passes through `becomeFirstResponder`. The keyboard came back
    /// wearing a fully transparent toolbar until will-show restored it.
    @MainActor
    @Test func aRepresentedKeyboardRestoresItsDismissedAccessory() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)

        // UIView.animate applies the model values immediately; this is the
        // state a backgrounding leaves behind.
        accessory.animateDismissal(duration: 0)
        #expect(accessory.toolbarContentView.alpha == 0)

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])

        #expect(accessory.toolbarContentView.alpha == 1)
        #expect(accessory.toolbarContentView.transform == .identity)
    }

    /// UIKit measures the input accessory after the keyboard itself, so a
    /// presentation can arrive as two frames. The terminal must not resize
    /// twice on the way up either.
    @MainActor
    @Test func aPresentationsFollowUpFrameFoldsIntoTheFirst() async throws {
        let center = NotificationCenter()
        var measured: [CGFloat] = [314, 402]
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in
            measured.isEmpty ? nil : measured.removeFirst()
        }
        var observedHeights: [CGFloat] = []
        let observation = Task { @MainActor in
            var last = inset.height
            while !Task.isCancelled {
                if inset.height != last {
                    last = inset.height
                    observedHeights.append(last)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { observation.cancel() }

        let frame = CGRect(x: 0, y: 554, width: 440, height: 436)
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])

        try await Task.sleep(for: .milliseconds(200))
        #expect(inset.height == 402)
        #expect(observedHeights == [402], "the terminal resized more than once: \(observedHeights)")
    }

    /// The keyboard's frame is measured from the bottom of the screen; the
    /// terminal stops at the home indicator. Not subtracting that safe area
    /// left a strip of background between the last row and the toolbar.
    @Test func theKeyboardInsetExcludesTheHomeIndicatorSafeArea() {
        #expect(TerminalKeyboardInset.insetHeight(covered: 436, bottomSafeArea: 34) == 402)
        #expect(TerminalKeyboardInset.insetHeight(covered: 436, bottomSafeArea: 0) == 436)
        #expect(TerminalKeyboardInset.insetHeight(covered: 20, bottomSafeArea: 34) == 0)
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

    @MainActor
    private func waitForGridReportsToSettle(
        _ reports: inout [(columns: Int, rows: Int)]
    ) async throws {
        var stablePolls = 0
        var previousCount = reports.count
        while stablePolls < 20 {
            try await Task.sleep(for: .milliseconds(10))
            if reports.count == previousCount {
                stablePolls += 1
            } else {
                previousCount = reports.count
                stablePolls = 0
            }
        }
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
                + "printf \"\\033_heeler-attach\\033\\134\"; "
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
                + "printf \"\\033_heeler-attach\\033\\134\"; "
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
                + "printf \"\\033_heeler-attach\\033\\134\"; "
                + "exec /bin/sh /tmp/fake-attach.sh \"$1\"' attach "
                + "'w1:p1' '/tmp/fake.sock'\n")
    }

    @Test func libssh2ExecUsesTheSameSocketAndTakeoverCommandWithoutBootstrap() throws {
        let command = try HeelerSSHTransport.attachExecCommand(
            attachCommand: "herdr agent attach",
            request: TerminalAttachRequest(
                target: "w1:p1",
                takeover: true,
                cols: 80,
                rows: 24),
            socketPath: "/home/u/.config/herdr/sessions/dev/herdr.sock")

        #expect(
            command == "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
                + "exec herdr agent attach \"$1\" --takeover' attach "
                + "'w1:p1' '/home/u/.config/herdr/sessions/dev/herdr.sock'")
        #expect(!command.contains("heeler-attach"))
        #expect(!command.contains("printf"))
        #expect(!command.hasSuffix("\n"))
    }

    @Test(arguments: [
        "", "w1'p1", #"w1\p1"#, "w1\np1", "w1\rp1", "w1\u{1B}p1",
    ])
    func libssh2ExecRefusesUnquotableTargets(target: String) {
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.attachExecCommand(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: target, cols: 80, rows: 24),
                socketPath: "/tmp/fake.sock")
        }
    }

    @Test func libssh2ExecRefusesUnquotableSocketPaths() {
        #expect(throws: TransportError.self) {
            _ = try HeelerSSHTransport.attachExecCommand(
                attachCommand: "herdr agent attach",
                request: TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24),
                socketPath: "/tmp/it's-a.sock")
        }
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

    @Test func gateWithholdsTheLoginShellNoiseUntilTheHandshake() {
        var gate = AttachBootstrapGate()
        // What the real channel says before the bootstrap runs: a banner, a
        // prompt, and the shell's echo of the line that prints the marker.
        // The echo carries the literal text of the escape, which is exactly
        // why it cannot be mistaken for the marker itself.
        let noise = Data(
            ("Last login: Sun Aug  2 13:28:08 2026\r\n"
                + "\u{1B}[32muser@host\u{1B}[0m ~ % "
                + #"exec /bin/sh -c 'printf "\033_heeler-attach\033\134"; exec herdr'"#
                + "\r\n").utf8)
        #expect(gate.admit(noise).isEmpty)
        #expect(!gate.isOpen)

        let opened = gate.admit(AttachBootstrapHandshake.marker + Data("\u{1B}[2JTUI".utf8))
        #expect(gate.isOpen)
        #expect(opened == Data("\u{1B}[2JTUI".utf8))
        // Open for good: no rescanning, no second handshake.
        #expect(gate.admit(Data("more".utf8)) == Data("more".utf8))
        #expect(gate.flush().isEmpty)
    }

    @Test func gateMatchesAHandshakeSplitAcrossChunks() {
        var gate = AttachBootstrapGate()
        let marker = AttachBootstrapHandshake.marker
        for index in 1..<marker.count {
            var split = AttachBootstrapGate()
            #expect(split.admit(Data(marker.prefix(index))).isEmpty)
            #expect(split.admit(Data(marker.suffix(from: index)) + Data("go".utf8))
                == Data("go".utf8))
        }
        // And byte by byte, the worst case a slow link can produce.
        for byte in marker {
            #expect(gate.admit(Data([byte])).isEmpty)
        }
        #expect(gate.isOpen)
    }

    @Test func gateHandsBackTheNoiseWhenTheHandshakeNeverCame() {
        // herdr missing from the Host's PATH: the shell's complaint is the
        // only diagnosis the user will ever get, so it must survive.
        var gate = AttachBootstrapGate()
        let failure = Data("sh: herdr: command not found\r\n".utf8)
        #expect(gate.admit(failure).isEmpty)
        #expect(gate.flush() == failure)
        #expect(gate.flush().isEmpty)
    }

    @Test func gateBoundsTheWithheldNoiseWithoutLosingTheHandshake() {
        var gate = AttachBootstrapGate()
        let flood = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        #expect(gate.admit(flood).isEmpty)
        // A copy, so the bound can be read without spending the gate.
        var counted = gate
        #expect(counted.flush().count <= AttachBootstrapGate.maximumWithheldBytes)
        // Trimming must not eat a marker that straddles the boundary.
        let marker = AttachBootstrapHandshake.marker
        #expect(gate.admit(Data(marker.prefix(3))).isEmpty)
        #expect(gate.admit(Data(marker.suffix(from: 3)) + Data("tui".utf8)) == Data("tui".utf8))
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

@MainActor
private final class TextInputDelegateRecorder: NSObject, UITextInputDelegate {
    private let record: (String) -> Void

    init(events record: @escaping (String) -> Void) {
        self.record = record
    }

    func selectionWillChange(_: (any UITextInput)?) {
        record("selectionWillChange")
    }

    func selectionDidChange(_: (any UITextInput)?) {
        record("selectionDidChange")
    }

    func textWillChange(_: (any UITextInput)?) {
        record("textWillChange")
    }

    func textDidChange(_: (any UITextInput)?) {
        record("textDidChange")
    }

    func conversationContext(_: UIConversationContext?, didChange _: (any UITextInput)?) {}
}
