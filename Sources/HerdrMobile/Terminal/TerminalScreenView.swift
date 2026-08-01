import GhosttyTerminal
import SwiftUI
import UIKit

/// Remote terminal output is untrusted. Only ordinary web links cross from
/// Ghostty into the system URL opener; local files and executable schemes do not.
enum TerminalLinkPolicy {
    static func url(for link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// A handle on the live terminal's keyboard, for chrome that sits outside the
/// terminal — the Agent strip's toggle. The reference is weak and set by the
/// surface itself, so an Agent switch rebuilding the terminal cannot leave the
/// toggle driving a dead one.
@MainActor
final class TerminalKeyboardControl {
    weak var terminal: HerdrTerminalView?

    var isKeyboardUp: Bool { terminal?.isFirstResponder ?? false }

    func toggleKeyboard() {
        guard let terminal else { return }
        if terminal.isFirstResponder {
            terminal.dismissKeyboard()
        } else {
            terminal.requestKeyboard()
        }
    }
}

/// The interactive Ghostty surface. PTY bytes flow into an in-memory Ghostty
/// session, while its write and resize callbacks flow back to Attach.
struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    var onViewportTextChanged: ((String) -> Void)?
    var onSend: ((Data) -> Void)?
    var onScroll: ((_ sequence: Data, _ rows: Int) -> Void)?
    var onPaste: ((_ text: String, _ bracketed: Bool) -> Void)?
    var onSnippet: ((_ text: String, _ bracketed: Bool) -> Void)?
    /// Fills the Keys keyboard's Snippets and Appearance tabs. Without one the
    /// keyboard shows the control keys alone.
    var keysContext: TerminalKeysContext?
    /// Asked exactly once, as the surface is created: does this terminal
    /// inherit the keyboard from the one it replaced? Asking through a
    /// closure rather than a stored flag keeps the answer tied to the
    /// surface's creation instead of to how often SwiftUI evaluates the body.
    var claimsKeyboard: (@MainActor () -> Bool)?
    /// Handed the surface once it exists, so the Agent strip's toggle can
    /// raise and lower this terminal's keyboard.
    var keyboardControl: TerminalKeyboardControl?
    var isLocalInputEnabled = true
    var theme: TerminalTheme = .default
    var fontSize: Float = TerminalZoomSettings.defaultFontSize
    var fontFamily: String?
    /// Pinch-to-zoom and the ⌘+/⌘- shortcut change the size in place; the
    /// screen forwards the new value so it lands in the global setting.
    var onFontSizeChanged: ((Float) -> Void)?
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> HerdrTerminalView {
        let view = Self.makeConfiguredTerminal(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            onSnippet: onSnippet,
            keysContext: keysContext,
            theme: theme,
            fontSize: fontSize,
            fontFamily: fontFamily)
        view.delegate = context.coordinator
        // Only here, never in updateUIView: the intent belongs to this
        // terminal's first appearance, not to every state change after it.
        view.raisesKeyboardWhenReady = claimsKeyboard?() ?? false
        keyboardControl?.terminal = view
        context.coordinator.terminalView = view
        feed.attach { [weak view] data in
            view?.receive(data)
        }
        return view
    }

    @MainActor
    static func makeConfiguredTerminal(
        onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)? = nil,
        onViewportTextChanged: ((String) -> Void)? = nil,
        onSend: ((Data) -> Void)? = nil,
        onScroll: ((_ sequence: Data, _ rows: Int) -> Void)? = nil,
        onPaste: ((_ text: String, _ bracketed: Bool) -> Void)? = nil,
        onSnippet: ((_ text: String, _ bracketed: Bool) -> Void)? = nil,
        keysContext: TerminalKeysContext? = nil,
        theme: TerminalTheme = .default,
        fontSize: Float = TerminalZoomSettings.defaultFontSize,
        fontFamily: String? = nil
    ) -> HerdrTerminalView {
        let view = HerdrTerminalView(
            frame: .zero,
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            onSnippet: onSnippet,
            keysContext: keysContext,
            theme: theme,
            fontSize: fontSize,
            fontFamily: fontFamily)
        view.installKeyboardSwitcher()
        return view
    }

    func updateUIView(_ view: HerdrTerminalView, context: Context) {
        view.updateCallbacks(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            onSnippet: onSnippet)
        view.keysContext = keysContext
        keyboardControl?.terminal = view
        view.setLocalInputEnabled(isLocalInputEnabled)
        view.applyTheme(theme)
        view.applyFontSize(fontSize)
        view.applyFontFamily(fontFamily)
        view.onFontSizeChanged = onFontSizeChanged
        // Deliberately no viewport read here. A SwiftUI update must not write
        // back into the state it was driven by: reporting the viewport text
        // feeds the Attach Link index, whose observers include this very view,
        // and the update loops on itself until the app is wedged. Terminal
        // output already schedules a snapshot in `receive`.
        context.coordinator.onOpenLink = { url in openURL(url) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenLink: { url in openURL(url) })
    }

    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceOpenURLDelegate,
        TerminalSurfaceTextSelectionRequestDelegate
    {
        weak var terminalView: HerdrTerminalView?
        var onOpenLink: ((URL) -> Void)?

        init(onOpenLink: ((URL) -> Void)? = nil) {
            self.onOpenLink = onOpenLink
        }

        func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
            guard let url = TerminalLinkPolicy.url(for: url) else { return }
            onOpenLink?(url)
        }

        func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
            guard let terminalView else { return }
            TerminalTextSelectionPresenter.present(request, from: terminalView)
        }
    }
}

/// Bridges Ghostty's sendable session callbacks onto the UI's main-actor
/// closures without making the transport layer depend on Ghostty types.
@MainActor
private final class TerminalSessionCallbackBridge {
    var onSizeChanged: ((Int, Int) -> Void)?
    var onViewportTextChanged: ((String) -> Void)?
    var onSend: ((Data) -> Void)?
    var onScroll: ((Data, Int) -> Void)?
    var onPaste: ((String, Bool) -> Void)?
    var onSnippet: ((String, Bool) -> Void)?
    var onViewport: ((InMemoryTerminalViewport) -> Void)?
    var onReliableInput: (() -> Void)?
    var onTerminalInput: ((Data) -> Void)?
    private var defersSizeReports = false
    private var deferredSize: (columns: Int, rows: Int)?

    init(
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        onSnippet: ((String, Bool) -> Void)?
    ) {
        self.onSizeChanged = onSizeChanged
        self.onViewportTextChanged = onViewportTextChanged
        self.onSend = onSend
        self.onScroll = onScroll
        self.onPaste = onPaste
        self.onSnippet = onSnippet
    }

    nonisolated func send(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.onReliableInput?()
            self?.onTerminalInput?(data)
            self?.onSend?(data)
        }
    }

    func scroll(_ sequence: Data, rows: Int) {
        onScroll?(sequence, rows)
    }

    nonisolated func resize(_ viewport: InMemoryTerminalViewport) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            onViewport?(viewport)
            let size = (columns: Int(viewport.columns), rows: Int(viewport.rows))
            if defersSizeReports {
                deferredSize = size
            } else {
                onSizeChanged?(size.columns, size.rows)
            }
        }
    }

    func beginSizeReportDeferral() {
        defersSizeReports = true
        deferredSize = nil
    }

    func finishSizeReportDeferral() {
        guard defersSizeReports else { return }
        defersSizeReports = false
        guard let deferredSize else { return }
        self.deferredSize = nil
        onSizeChanged?(deferredSize.columns, deferredSize.rows)
    }

    func cancelSizeReportDeferral() {
        defersSizeReports = false
        deferredSize = nil
    }

    func paste(_ text: String, bracketed: Bool) {
        onPaste?(text, bracketed)
    }

    func snippet(_ text: String, bracketed: Bool) {
        onSnippet?(text, bracketed)
    }

    func viewportTextDidChange(_ text: String) {
        onViewportTextChanged?(text)
    }
}

private final class TerminalInputTextPosition: UITextPosition {
    let index: Int

    init(index: Int) {
        self.index = index
        super.init()
    }
}

private final class TerminalInputTextRange: UITextRange {
    private let startPosition: TerminalInputTextPosition
    private let endPosition: TerminalInputTextPosition

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.index == endPosition.index }
    var location: Int { startPosition.index }
    var length: Int { endPosition.index - startPosition.index }

    init(location: Int, length: Int) {
        startPosition = TerminalInputTextPosition(index: location)
        endPosition = TerminalInputTextPosition(index: location + length)
        super.init()
    }
}

/// The app-owned seam around libghostty-spm. It keeps keyboard policy and the
/// host-managed session lifecycle out of the SwiftUI screen.
final class HerdrTerminalView: UITerminalView {
    private let callbackBridge: TerminalSessionCallbackBridge
    private let terminalController: TerminalController
    let terminalSession: InMemoryTerminalSession
    private(set) var appliedTheme: TerminalTheme
    private(set) var appliedFontSize: Float
    private(set) var appliedFontFamily: String?
    var onFontSizeChanged: ((Float) -> Void)?
    /// Rebuilt into the Keys keyboard the next time it is raised; a live
    /// keyboard keeps the context it was built with.
    var keysContext: TerminalKeysContext?
    /// Raises the keyboard once this surface reaches a window. An Agent switch
    /// rebuilds the whole terminal, and the user who tapped a switcher chip
    /// was mid-conversation — dropping the keyboard would hide the switcher
    /// along with it.
    var raisesKeyboardWhenReady = false
    /// How many times the input views have been rebuilt. Nothing else observes
    /// the rebuild that republishes the keyboard's settled frame after a
    /// handoff, and a lost rebuild costs the terminal a toolbar's worth of
    /// height without a crash to show for it.
    private(set) var inputViewRebuildCount = 0
    private var zoomBaseFontSize: Float?
    private var terminalInputView: UIView?
    private var modeTracker = TerminalModeTracker()
    private var lastInputWindowSize: CGSize?
    private var defersLayoutForKeyboardTransition = false
    /// What ends the current freeze. A dismissal waits for `keyboardDidHide`;
    /// an inherited keyboard never leaves, so its settled signal is the frame
    /// change instead.
    private var keyboardTransitionEndsOnFrameChange = false
    private var keyboardTransitionFallbackTask: Task<Void, Never>?
    private var keyboardGridReportTask: Task<Void, Never>?
    /// How long Ghostty gets to answer a settled layout before its grid is
    /// forwarded to the Host — long enough to coalesce one layout pass's
    /// several viewport reports into the final one.
    private static let gridSettleDelay: TimeInterval = 0.05
    private var responderGate = TerminalKeyboardResponderGate()
    private var viewportSnapshotTask: Task<Void, Never>?
    private(set) var isLocalInputEnabled = true
    // Ghostty keeps only marked text in its UITextInput document. UIKit needs
    // committed text to remain in that document so Backspace can observe a
    // shrinking selection and continue its native key repeat.
    private var textInputStorage = ""
    private var textInputSelection = NSRange(location: 0, length: 0)
    private var terminalGridSize = (columns: 80, rows: 24)
    private var terminalCellSize = CGSize(width: 8, height: 16)
    private var touchScrollAccumulator = TerminalTouchScrollAccumulator()
    private var touchScrollMomentumDisplayLink: CADisplayLink?
    private var touchScrollMomentumVelocityY: CGFloat = 0
    private var touchScrollMomentumTimestamp: CFTimeInterval = 0
    var controlKeyboardHeight = TerminalKeysKeyboardView.defaultHeight

    private lazy var touchScrollGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTouchScrollGesture(_:)))

    private lazy var zoomGesture = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handleHerdrZoomGesture(_:)))

    private lazy var tapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTap(_:)))

    private lazy var terminalKeyboardAccessory = TerminalKeyboardAccessory(
        frame: CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: TerminalKeyboardAccessory.preferredHeight),
        terminalView: self)

    override var inputView: UIView? {
        terminalInputView
    }

    override var beginningOfDocument: UITextPosition {
        guard super.markedTextRange == nil else {
            return super.beginningOfDocument
        }
        return TerminalInputTextPosition(index: 0)
    }

    override var endOfDocument: UITextPosition {
        guard super.markedTextRange == nil else {
            return super.endOfDocument
        }
        return TerminalInputTextPosition(index: textInputStorage.utf16.count)
    }

    override var selectedTextRange: UITextRange? {
        get {
            guard super.markedTextRange == nil else {
                return super.selectedTextRange
            }
            return TerminalInputTextRange(
                location: textInputSelection.location,
                length: textInputSelection.length)
        }
        set {
            guard super.markedTextRange == nil,
                  let range = newValue as? TerminalInputTextRange
            else {
                super.selectedTextRange = newValue
                return
            }
            let length = textInputStorage.utf16.count
            let location = min(max(range.location, 0), length)
            let end = min(max(range.location + range.length, location), length)
            textInputSelection = NSRange(location: location, length: end - location)
        }
    }

    override func textRange(
        from fromPosition: UITextPosition,
        to toPosition: UITextPosition
    ) -> UITextRange? {
        guard super.markedTextRange == nil,
              let from = fromPosition as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition
        else {
            return super.textRange(from: fromPosition, to: toPosition)
        }
        return TerminalInputTextRange(
            location: min(from.index, to.index),
            length: abs(to.index - from.index))
    }

    override func position(
        from position: UITextPosition,
        offset: Int
    ) -> UITextPosition? {
        guard super.markedTextRange == nil,
              let position = position as? TerminalInputTextPosition
        else {
            return super.position(from: position, offset: offset)
        }
        let index = position.index + offset
        guard index >= 0, index <= textInputStorage.utf16.count else { return nil }
        return TerminalInputTextPosition(index: index)
    }

    override func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    ) -> UITextPosition? {
        guard position is TerminalInputTextPosition else {
            return super.position(from: position, in: direction, offset: offset)
        }
        return self.position(from: position, offset: offset)
    }

    override func compare(
        _ position: UITextPosition,
        to other: UITextPosition
    ) -> ComparisonResult {
        guard let lhs = position as? TerminalInputTextPosition,
              let rhs = other as? TerminalInputTextPosition
        else {
            return super.compare(position, to: other)
        }
        if lhs.index < rhs.index { return .orderedAscending }
        if lhs.index > rhs.index { return .orderedDescending }
        return .orderedSame
    }

    override func offset(
        from: UITextPosition,
        to toPosition: UITextPosition
    ) -> Int {
        guard let from = from as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition
        else {
            return super.offset(from: from, to: toPosition)
        }
        return to.index - from.index
    }

    override func text(in range: UITextRange) -> String? {
        guard super.markedTextRange == nil,
              let range = range as? TerminalInputTextRange
        else {
            return super.text(in: range)
        }
        let text = textInputStorage as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= text.length
        else { return nil }
        return text.substring(
            with: NSRange(location: range.location, length: range.length))
    }

    override var inputAccessoryView: UIView? {
        terminalKeyboardAccessory
    }

    /// Only a tap on the input row raises the keyboard, so the surface refuses
    /// first responder until asked. The gate tracks the *user's* intent, and
    /// that intent survives a UIKit-initiated resign on purpose: backgrounding
    /// the app or presenting a sheet resigns the first responder, and UIKit
    /// restores it afterwards by asking again. Refusing there would leave the
    /// accessory bar on screen with no keyboard behind it and no way to type.
    /// `dismissKeyboard()` is what clears the intent.
    ///
    /// The gate also refuses mid-touch requests: Ghostty's `touchesBegan`
    /// calls `becomeFirstResponder()` on every body touch, which with the
    /// intent armed would raise the keyboard from taps the input-row policy
    /// never approved.
    override var canBecomeFirstResponder: Bool {
        responderGate.mayBecomeFirstResponder
    }

    /// UIKit skips the `canBecomeFirstResponder` check when the view already
    /// *is* first responder — and a short backgrounding leaves exactly that
    /// state behind: the keyboard hides but the first responder survives.
    /// Ghostty's `touchesBegan` re-assert would then re-present the keyboard
    /// from any body tap, so the gate has to be applied here as well.
    @discardableResult
    override func becomeFirstResponder() -> Bool {
        if isFirstResponder, !responderGate.mayBecomeFirstResponder {
            return true
        }
        // UIKit reads the accessory hierarchy while installing the software
        // keyboard. Restore its content before that transaction starts.
        terminalKeyboardAccessory.resetDismissalAppearance()
        return super.becomeFirstResponder()
    }

    /// Ghostty's `touchesEnded` dismisses the keyboard after any body tap or
    /// scroll. The accessory's dismiss button is this app's only intended
    /// dismissal, so a resign arriving mid-touch is Ghostty's and is refused;
    /// UIKit's resigns (sheets, backgrounding) arrive outside touch sequences
    /// and pass.
    @discardableResult
    override func resignFirstResponder() -> Bool {
        guard responderGate.mayResignFirstResponder else { return false }
        return super.resignFirstResponder()
    }

    init(
        frame: CGRect,
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        onSnippet: ((String, Bool) -> Void)?,
        keysContext: TerminalKeysContext?,
        theme: TerminalTheme,
        fontSize: Float,
        fontFamily: String?
    ) {
        self.keysContext = keysContext
        let callbackBridge = TerminalSessionCallbackBridge(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            onSnippet: onSnippet)
        self.callbackBridge = callbackBridge
        terminalSession = InMemoryTerminalSession(
            write: { [weak callbackBridge] data in
                callbackBridge?.send(data)
            },
            resize: { [weak callbackBridge] viewport in
                callbackBridge?.resize(viewport)
            })
        // Font size rides the controller's per-session configuration rather
        // than the surface's one-shot option, so later changes reach the live
        // surface through the same path the initial value took.
        let clampedFontSize = TerminalZoomSettings.clamped(fontSize)
        terminalController = TerminalController(
            theme: theme,
            terminalConfiguration: Self.fontConfiguration(
                size: clampedFontSize, family: fontFamily))
        appliedTheme = theme
        appliedFontSize = clampedFontSize
        appliedFontFamily = fontFamily
        super.init(frame: frame)
        callbackBridge.onTerminalInput = { [weak self] data in
            self?.recordTerminalInput(data)
        }
        pasteConfiguration = UIPasteConfiguration(forAccepting: String.self)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        controller = terminalController
        callbackBridge.onViewport = { [weak self] viewport in
            self?.updateTouchScrollMetrics(viewport)
        }
        callbackBridge.onReliableInput = { [weak self] in
            self?.reliableInputDidBegin()
        }
        installTouchScrolling()
        installZoom()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func updateCallbacks(
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        onSnippet: ((String, Bool) -> Void)?
    ) {
        callbackBridge.onSizeChanged = onSizeChanged
        callbackBridge.onViewportTextChanged = onViewportTextChanged
        callbackBridge.onSend = onSend
        callbackBridge.onScroll = onScroll
        callbackBridge.onPaste = onPaste
        callbackBridge.onSnippet = onSnippet
    }

    @discardableResult
    func applyTheme(_ theme: TerminalTheme) -> Bool {
        guard theme != appliedTheme, terminalController.setTheme(theme) else {
            return false
        }
        appliedTheme = theme
        return true
    }

    @discardableResult
    func applyFontSize(_ fontSize: Float) -> Bool {
        let clamped = TerminalZoomSettings.clamped(fontSize)
        guard clamped != appliedFontSize,
            terminalController.setTerminalConfiguration(
                TerminalConfiguration().fontSize(clamped))
        else {
            return false
        }
        appliedFontSize = clamped
        return true
    }

    @discardableResult
    func applyFontFamily(_ family: String?) -> Bool {
        guard family != appliedFontFamily,
            terminalController.setTerminalConfiguration(
                Self.fontConfiguration(size: nil, family: family))
        else {
            return false
        }
        appliedFontFamily = family
        return true
    }

    /// ghostty treats `font-family` as a set that repeated values append to,
    /// so switching fonts has to clear it with an empty value first or the
    /// old family stays in the fallback chain ahead of the new one.
    private static func fontConfiguration(size: Float?, family: String?) -> TerminalConfiguration {
        var configuration = TerminalConfiguration()
        if let size {
            configuration = configuration.fontSize(size)
        }
        configuration = configuration.fontFamily("")
        if let family {
            configuration = configuration.fontFamily(family)
        }
        return configuration
    }

    /// Applies a zoom the user performed on this terminal and reports it, so
    /// the global setting follows the gesture instead of fighting it.
    private func zoom(to fontSize: Float) {
        guard applyFontSize(fontSize) else { return }
        onFontSizeChanged?(appliedFontSize)
    }

    func receive(_ data: Data) {
        modeTracker.receive(data)
        terminalSession.receive(data)
        scheduleViewportSnapshot()
    }

    /// Viewport reads are supplemental to raw-stream discovery. Ghostty
    /// parses host output off-main, so coalescing briefly lets redraw bursts
    /// settle without making terminal rendering wait on link collection.
    func reportViewportText() {
        guard let text = terminalSession.readViewportText() else { return }
        callbackBridge.viewportTextDidChange(text)
    }

    private func scheduleViewportSnapshot() {
        viewportSnapshotTask?.cancel()
        viewportSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.reportViewportText()
        }
    }

    /// Takes over the keyboard from the terminal this one replaced.
    ///
    /// The keyboard must not drop between the two: it carries the switcher, so
    /// a dip would make every switch flash the row the user is switching from.
    /// So the surface claims first responder in the same pass it reaches the
    /// window — and freezes its grid until UIKit has settled the keyboard,
    /// because Ghostty's first viewport report on a fresh surface carries a
    /// zero cell size. Measured against that half-built grid, the surface
    /// draws a band shorter than the view and leaves an unpainted strip above
    /// the toolbar.
    private func inheritKeyboard() {
        guard raisesKeyboardWhenReady, window != nil else { return }
        raisesKeyboardWhenReady = false
        // A keyboard that never left reports no did-show, only a frame change.
        beginKeyboardTransitionLayoutDeferral(endsOnFrameChange: true)
        raiseKeyboard()
    }

    /// Raises the keyboard, and records that the user wants it up.
    func requestKeyboard() {
        finishKeyboardTransitionLayout()
        raiseKeyboard()
    }

    private func raiseKeyboard() {
        responderGate.beginUserDrivenChange(wantsKeyboard: true)
        defer { responderGate.endUserDrivenChange() }
        _ = becomeFirstResponder()
    }

    /// Takes the keyboard down on the user's behalf. This is the *only* way
    /// the keyboard goes away for good: a plain `resignFirstResponder()` is
    /// something UIKit does on its own (backgrounding, a sheet taking focus)
    /// and must stay recoverable.
    @discardableResult
    func dismissKeyboard() -> Bool {
        responderGate.beginUserDrivenChange(wantsKeyboard: false)
        defer { responderGate.endUserDrivenChange() }
        return resignFirstResponder()
    }

    func setLocalInputEnabled(_ isEnabled: Bool) {
        guard isLocalInputEnabled != isEnabled else { return }
        isLocalInputEnabled = isEnabled
        terminalKeyboardAccessory.setInputEnabled(isEnabled)
        if let keysKeyboard {
            keysKeyboard.localInputEnabledDidChange()
        } else {
            terminalInputView?.isUserInteractionEnabled = isEnabled
            terminalInputView?.alpha = isEnabled ? 1 : 0.5
        }
    }

    func requestPaste(_ text: String?) {
        guard isLocalInputEnabled, let text else { return }
        reliableInputDidBegin()
        recordCommittedText(text)
        callbackBridge.paste(text, bracketed: usesBracketedPaste)
    }

    /// Sends a Snippet the user tapped in the Keys keyboard.
    func sendSnippet(_ snippet: Snippet) {
        guard isLocalInputEnabled else { return }
        reliableInputDidBegin()
        recordCommittedText(snippet.body)
        callbackBridge.snippet(snippet.body, bracketed: usesBracketedPaste)
    }

    override func deleteBackward() {
        guard isLocalInputEnabled else { return }

        // Ghostty already synchronizes marked-text deletion with UIKit. Raw
        // terminal deletion also changes the remote document, so it must send
        // the same notifications or the software keyboard stops key repeat.
        guard markedTextRange == nil else {
            super.deleteBackward()
            return
        }

        guard let deletionRange = textInputDeletionRange() else {
            super.deleteBackward()
            return
        }

        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        deleteFromTextInputStorage(in: deletionRange)
        super.deleteBackward()
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
    }

    private func recordTerminalInput(_ data: Data) {
        guard !data.contains(0x1B), !data.contains(0x7F),
              !data.contains(where: { $0 < 0x20 && $0 != 0x0A && $0 != 0x0D }),
              let text = String(data: data, encoding: .utf8)
        else { return }
        recordCommittedText(text)
    }

    private func recordCommittedText(_ text: String) {
        let storage = NSMutableString(string: textInputStorage)
        storage.replaceCharacters(in: textInputSelection, with: text)
        textInputStorage = storage as String

        if let lineBreak = textInputStorage.rangeOfCharacter(
            from: .newlines, options: .backwards)
        {
            textInputStorage = String(textInputStorage[lineBreak.upperBound...])
        }
        textInputSelection = NSRange(
            location: textInputStorage.utf16.count,
            length: 0)
    }

    private func textInputDeletionRange() -> NSRange? {
        let storage = NSMutableString(string: textInputStorage)
        if textInputSelection.length > 0 {
            return textInputSelection
        }
        guard textInputSelection.location > 0 else { return nil }
        return storage.rangeOfComposedCharacterSequence(
            at: textInputSelection.location - 1)
    }

    private func deleteFromTextInputStorage(in deletionRange: NSRange) {
        let storage = NSMutableString(string: textInputStorage)
        storage.deleteCharacters(in: deletionRange)
        textInputStorage = storage as String
        textInputSelection = NSRange(location: deletionRange.location, length: 0)
    }

    override func paste(_ sender: Any?) {
        guard isLocalInputEnabled, let text = UIPasteboard.general.string else { return }

        // The keyboard's clipboard suggestion invokes this standard action
        // directly, bypassing Ghostty's text-input handler. Tell UIKit about
        // the external document change or the IME keeps its pre-paste context
        // and subsequent phonetic input can remain Latin marked text.
        inputDelegate?.textWillChange(self)
        requestPaste(text)
        inputDelegate?.textDidChange(self)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard isLocalInputEnabled else { return }
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                Task { @MainActor [weak self] in
                    self?.requestPaste(text)
                }
            }
            return
        }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        isLocalInputEnabled
            && itemProviders.contains {
                $0.canLoadObject(ofClass: NSString.self)
            }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return isLocalInputEnabled && UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func reloadInputViews() {
        inputViewRebuildCount += 1
        super.reloadInputViews()
    }

    override func layoutSubviews() {
        guard !defersLayoutForKeyboardTransition else { return }
        super.layoutSubviews()
        reloadInputViewsAfterWindowResize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTouchScrollMomentum()
            responderGate.invalidateTouches()
            cancelKeyboardTransitionLayoutDeferral()
        } else {
            inheritKeyboard()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        responderGate.directTouchesBegan(Self.directTouchCount(in: touches))
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Ghostty's touchesEnded is where its tap-to-dismiss resign fires, so
        // the touches stay counted until super returns.
        super.touchesEnded(touches, with: event)
        responderGate.directTouchesEnded(Self.directTouchCount(in: touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        responderGate.directTouchesEnded(Self.directTouchCount(in: touches))
    }

    private static func directTouchCount(in touches: Set<UITouch>) -> Int {
        touches.count { $0.type == .direct }
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === touchScrollGesture {
            let velocity = touchScrollGesture.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        if gestureRecognizer === tapGesture {
            // A TUI wants every tap — to click, to raise the keyboard, or both.
            // In the normal buffer only the input row is interactive. A running
            // flick claims any tap regardless, to halt itself.
            return modeTracker.tracksMouse
                || modeTracker.isAlternateScreen
                || isTouchScrollMomentumRunning
                || keyboardActivationRegion.contains(tapGesture.location(in: self))
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private func reloadInputViewsAfterWindowResize() {
        guard let windowSize = window?.bounds.size else { return }
        defer { lastInputWindowSize = windowSize }
        guard let lastInputWindowSize, lastInputWindowSize != windowSize, isFirstResponder else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFirstResponder else { return }
            UIView.performWithoutAnimation {
                self.reloadInputViews()
            }
        }
    }

    /// Ghostty synchronizes its grid and reports a PTY resize from every
    /// `layoutSubviews` pass, and a keyboard changing hands passes through
    /// several transient heights — both accessories ride the keyboard at once
    /// while it does. Each one would cost a full-screen TUI redraw, so the
    /// grid stays fixed until the keyboard has settled.
    ///
    /// Only a handoff needs this. An ordinary presentation or dismissal moves
    /// in one step, because the terminal sizes itself to the keyboard's own
    /// frame rather than through SwiftUI's two-stage avoidance — see
    /// ``TerminalKeyboardInset``.
    private func beginKeyboardTransitionLayoutDeferral(endsOnFrameChange: Bool = false) {
        defersLayoutForKeyboardTransition = true
        keyboardTransitionEndsOnFrameChange = endsOnFrameChange
        callbackBridge.beginSizeReportDeferral()
        keyboardTransitionFallbackTask?.cancel()
        keyboardTransitionFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.finishKeyboardTransitionLayout()
        }
    }

    private func scheduleGridReport(after delay: TimeInterval) {
        keyboardGridReportTask?.cancel()
        keyboardGridReportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.keyboardGridReportTask = nil
            self?.callbackBridge.finishSizeReportDeferral()
        }
    }

    @objc func keyboardTransitionDidFinish(_: Notification) {
        finishKeyboardTransitionLayout()
    }

    /// The keyboard reached its end frame. An inherited keyboard never leaves,
    /// so this is the only settled signal it gets — there is no did-show to
    /// wait for.
    func keyboardFrameDidSettle() {
        guard keyboardTransitionEndsOnFrameChange else { return }
        finishKeyboardTransitionLayout()
    }

    func finishKeyboardTransitionLayout() {
        guard defersLayoutForKeyboardTransition else { return }
        let inheritedTheKeyboard = keyboardTransitionEndsOnFrameChange
        defersLayoutForKeyboardTransition = false
        keyboardTransitionEndsOnFrameChange = false
        keyboardTransitionFallbackTask?.cancel()
        keyboardTransitionFallbackTask = nil
        if inheritedTheKeyboard {
            // Both terminals' accessories were on the keyboard while it
            // changed hands, and that is the frame the keyboard published:
            // one accessory too tall. UIKit does not publish another when the
            // outgoing one leaves, so the layout keeps reserving room for an
            // accessory that is gone. Rebuilding the input views makes it
            // publish the settled frame.
            UIView.performWithoutAnimation { reloadInputViews() }
        }
        setNeedsLayout()
        layoutIfNeeded()
        scheduleGridReport(after: Self.gridSettleDelay)
    }

    private func cancelKeyboardTransitionLayoutDeferral() {
        defersLayoutForKeyboardTransition = false
        keyboardTransitionEndsOnFrameChange = false
        keyboardTransitionFallbackTask?.cancel()
        keyboardTransitionFallbackTask = nil
        keyboardGridReportTask?.cancel()
        keyboardGridReportTask = nil
        callbackBridge.cancelSizeReportDeferral()
    }

    var usesApplicationCursorKeys: Bool {
        modeTracker.usesApplicationCursorKeys
    }

    var usesBracketedPaste: Bool {
        modeTracker.usesBracketedPaste
    }

    func setTerminalInputView(_ inputView: UIView?) {
        terminalInputView = inputView
    }

    var keyboardActivationRegion: CGRect {
        let caret = caretRect(for: endOfDocument)
        return TerminalKeyboardTapTarget.region(
            caretRect: caret,
            in: bounds,
            minimumHeight: modeTracker.isAlternateScreen
                ? TerminalKeyboardTapTarget.alternateScreenMinimumHeight
                : TerminalKeyboardTapTarget.minimumHeight)
    }

    /// Reports a touch as a left click when the remote application asked for
    /// mouse tracking. Returns whether anything was sent.
    @discardableResult
    func clickTouch(at point: CGPoint) -> Bool {
        guard isLocalInputEnabled,
            let cell = gridPointMapper.cell(at: point),
            let report = modeTracker.remoteClickSequence(
                column: cell.column,
                row: cell.row)
        else { return false }

        terminalSession.sendInput(report)
        return true
    }

    /// Where Ghostty's grid currently sits inside the view, rebuilt from the
    /// metrics of the last resize.
    var gridPointMapper: TerminalGridPointMapper {
        TerminalGridPointMapper(
            viewSize: bounds.size,
            cellSize: terminalCellSize,
            columns: terminalGridSize.columns,
            rows: terminalGridSize.rows,
            scale: window?.screen.nativeScale ?? traitCollection.displayScale)
    }

    @discardableResult
    func scrollTouch(translationY: CGFloat) -> Int {
        let rows = touchScrollAccumulator.rows(
            for: translationY,
            pointsPerRow: max(8, terminalCellSize.height))
        guard rows != 0 else { return 0 }

        let towardOlderContent = rows > 0
        let rowCount = abs(rows)
        if let sequence = modeTracker.remoteScrollSequence(
            towardOlderContent: towardOlderContent,
            columns: terminalGridSize.columns,
            rows: terminalGridSize.rows)
        {
            callbackBridge.scroll(sequence, rows: rowCount)
        } else {
            let localRows = towardOlderContent ? -rowCount : rowCount
            _ = performBindingAction("scroll_page_lines:\(localRows)")
        }
        return rows
    }

    private func installTouchScrolling() {
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        for case let pan as UIPanGestureRecognizer in gestureRecognizers ?? []
        where pan.allowedTouchTypes.contains(directTouch) {
            pan.isEnabled = false
        }

        touchScrollGesture.allowedTouchTypes = [directTouch]
        touchScrollGesture.maximumNumberOfTouches = 1
        touchScrollGesture.cancelsTouchesInView = false
        touchScrollGesture.delegate = self
        addGestureRecognizer(touchScrollGesture)

        tapGesture.allowedTouchTypes = [directTouch]
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)
    }

    /// Ghostty ships its own pinch handler that mutates the surface font size
    /// behind the app's back. Zoom has to be app state to persist, so that
    /// gesture steps aside for one that routes through `onFontSizeChanged`.
    private func installZoom() {
        for case let pinch as UIPinchGestureRecognizer in gestureRecognizers ?? [] {
            pinch.isEnabled = false
        }
        addGestureRecognizer(zoomGesture)
    }

    @objc private func handleHerdrZoomGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoomBaseFontSize = appliedFontSize
        case .changed:
            guard let zoomBaseFontSize else { return }
            zoom(to: zoomBaseFontSize * Float(gesture.scale))
        case .ended, .cancelled, .failed:
            zoomBaseFontSize = nil
        default:
            break
        }
    }

    /// ⌘+ / ⌘- would otherwise reach Ghostty's own font-size keybinds, which
    /// leaves the global setting stale. Handle them here and swallow both the
    /// press and its release so Ghostty never sees the shortcut.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var forwarded: Set<UIPress> = []
        for press in presses {
            guard let step = Self.zoomShortcutStep(for: press) else {
                forwarded.insert(press)
                continue
            }
            zoom(to: appliedFontSize + step)
        }
        guard !forwarded.isEmpty else { return }
        super.pressesBegan(forwarded, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = presses.filter { Self.zoomShortcutStep(for: $0) == nil }
        guard !forwarded.isEmpty else { return }
        super.pressesEnded(Set(forwarded), with: event)
    }

    private static func zoomShortcutStep(for press: UIPress) -> Float? {
        guard let key = press.key, key.modifierFlags.contains(.command) else { return nil }
        switch key.charactersIgnoringModifiers {
        case "+", "=": return 1
        case "-", "_": return -1
        default: return nil
        }
    }

    @objc private func handleHerdrTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        handleTap(at: gesture.location(in: self))
    }

    func handleTap(at location: CGPoint) {
        switch tapAction(at: location) {
        case .haltMomentum:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        case .report(let raisesKeyboard):
            clickTouch(at: location)
            if raisesKeyboard {
                requestKeyboard()
            }
        }
    }

    /// What a tap means, given what the terminal is currently doing.
    ///
    /// In the normal buffer the keyboard follows the input row alone, so that a
    /// touch meant for native scrollback is never answered with a keyboard-driven
    /// viewport resize.
    ///
    /// The alternate screen reaches further, two ways. The caret band grows to
    /// three rows' worth, because an agent TUI parks its caret below the row
    /// the user reads as the prompt (Claude Code's visible `>` measured
    /// 16–40 pt above it, #90). And the bottom quarter always answers, because
    /// chat-style TUIs (Claude Code, Codex, Amp, Droid, …) pin their input box
    /// there while parking the caret in tool-specific spots the band cannot
    /// chase. Whole-screen activation was tried first (#92) and answered every
    /// output-area tap with the keyboard.
    func tapAction(at location: CGPoint) -> TerminalTapAction {
        if isTouchScrollMomentumRunning { return .haltMomentum }
        if keyboardActivationRegion.contains(location) {
            return .report(raisesKeyboard: true)
        }
        let inBottomBand = modeTracker.isAlternateScreen
            && TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: bounds)
                .contains(location)
        return .report(raisesKeyboard: inBottomBand)
    }

    var isTouchScrollMomentumRunning: Bool {
        touchScrollMomentumDisplayLink != nil
    }

    @objc private func handleHerdrTouchScrollGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        case .changed:
            _ = scrollTouch(translationY: gesture.translation(in: self).y)
            gesture.setTranslation(.zero, in: self)
        case .ended:
            startTouchScrollMomentum(velocityY: gesture.velocity(in: self).y)
        case .cancelled, .failed:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        default:
            break
        }
    }

    /// Ghostty reports cell metrics in surface pixels; touches arrive in
    /// points, so the grid has to be converted once per resize.
    private func updateTouchScrollMetrics(_ viewport: InMemoryTerminalViewport) {
        terminalGridSize = (Int(viewport.columns), Int(viewport.rows))
        guard viewport.cellWidthPixels > 0, viewport.cellHeightPixels > 0 else { return }
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        guard scale > 0 else { return }
        terminalCellSize = CGSize(
            width: CGFloat(viewport.cellWidthPixels) / scale,
            height: CGFloat(viewport.cellHeightPixels) / scale)
    }

    func startTouchScrollMomentum(velocityY: CGFloat) {
        guard abs(velocityY) >= 80 else {
            touchScrollAccumulator.reset()
            return
        }
        stopTouchScrollMomentum()
        touchScrollMomentumVelocityY = max(-4_000, min(4_000, velocityY))
        touchScrollMomentumTimestamp = 0
        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(advanceTouchScrollMomentum(_:)))
        touchScrollMomentumDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func advanceTouchScrollMomentum(_ displayLink: CADisplayLink) {
        guard abs(touchScrollMomentumVelocityY) >= 20 else {
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
            return
        }
        guard touchScrollMomentumTimestamp > 0 else {
            touchScrollMomentumTimestamp = displayLink.timestamp
            return
        }

        let elapsed = min(1.0 / 30.0, displayLink.timestamp - touchScrollMomentumTimestamp)
        touchScrollMomentumTimestamp = displayLink.timestamp
        _ = scrollTouch(translationY: touchScrollMomentumVelocityY * elapsed)
        touchScrollMomentumVelocityY *= pow(0.998, elapsed * 1_000)
    }

    private func stopTouchScrollMomentum() {
        touchScrollMomentumDisplayLink?.invalidate()
        touchScrollMomentumDisplayLink = nil
        touchScrollMomentumVelocityY = 0
        touchScrollMomentumTimestamp = 0
    }

    private func reliableInputDidBegin() {
        stopTouchScrollMomentum()
        touchScrollAccumulator.reset()
    }
}
