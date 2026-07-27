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

/// The interactive Ghostty surface. PTY bytes flow into an in-memory Ghostty
/// session, while its write and resize callbacks flow back to Attach.
struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    var onSend: ((Data) -> Void)?
    var onPaste: ((_ text: String, _ bracketed: Bool) -> Void)?
    var onSnippet: ((_ text: String, _ bracketed: Bool) -> Void)?
    var isLocalInputEnabled = true
    var theme: TerminalTheme = .default
    var fontSize: Float = TerminalZoomSettings.defaultFontSize
    /// Pinch-to-zoom and the ⌘+/⌘- shortcut change the size in place; the
    /// screen forwards the new value so it lands in the global setting.
    var onFontSizeChanged: ((Float) -> Void)?
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> HerdrTerminalView {
        let view = Self.makeConfiguredTerminal(
            onSizeChanged: onSizeChanged,
            onSend: onSend,
            onPaste: onPaste,
            onSnippet: onSnippet,
            theme: theme,
            fontSize: fontSize)
        view.delegate = context.coordinator
        context.coordinator.terminalView = view
        feed.attach { [weak view] data in
            view?.receive(data)
        }
        return view
    }

    @MainActor
    static func makeConfiguredTerminal(
        onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)? = nil,
        onSend: ((Data) -> Void)? = nil,
        onPaste: ((_ text: String, _ bracketed: Bool) -> Void)? = nil,
        onSnippet: ((_ text: String, _ bracketed: Bool) -> Void)? = nil,
        theme: TerminalTheme = .default,
        fontSize: Float = TerminalZoomSettings.defaultFontSize
    ) -> HerdrTerminalView {
        let view = HerdrTerminalView(
            frame: .zero,
            onSizeChanged: onSizeChanged,
            onSend: onSend,
            onPaste: onPaste,
            onSnippet: onSnippet,
            theme: theme,
            fontSize: fontSize)
        view.installKeyboardSwitcher()
        return view
    }

    func updateUIView(_ view: HerdrTerminalView, context: Context) {
        view.updateCallbacks(
            onSizeChanged: onSizeChanged,
            onSend: onSend,
            onPaste: onPaste,
            onSnippet: onSnippet)
        view.setLocalInputEnabled(isLocalInputEnabled)
        view.applyTheme(theme)
        view.applyFontSize(fontSize)
        view.onFontSizeChanged = onFontSizeChanged
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
    var onSend: ((Data) -> Void)?
    var onPaste: ((String, Bool) -> Void)?
    var onSnippet: ((String, Bool) -> Void)?
    var onViewport: ((InMemoryTerminalViewport) -> Void)?

    init(
        onSizeChanged: ((Int, Int) -> Void)?,
        onSend: ((Data) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        onSnippet: ((String, Bool) -> Void)?
    ) {
        self.onSizeChanged = onSizeChanged
        self.onSend = onSend
        self.onPaste = onPaste
        self.onSnippet = onSnippet
    }

    nonisolated func send(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.onSend?(data)
        }
    }

    nonisolated func resize(_ viewport: InMemoryTerminalViewport) {
        Task { @MainActor [weak self] in
            self?.onViewport?(viewport)
            self?.onSizeChanged?(Int(viewport.columns), Int(viewport.rows))
        }
    }

    func paste(_ text: String, bracketed: Bool) {
        onPaste?(text, bracketed)
    }

    func snippet(_ text: String, bracketed: Bool) {
        onSnippet?(text, bracketed)
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
    var onFontSizeChanged: ((Float) -> Void)?
    private var zoomBaseFontSize: Float?
    private var terminalInputView: UIView?
    private var modeTracker = TerminalModeTracker()
    private var lastInputWindowSize: CGSize?
    private var allowsKeyboardActivation = false
    private(set) var isLocalInputEnabled = true
    private var terminalGridSize = (columns: 80, rows: 24)
    private var terminalCellSize = CGSize(width: 8, height: 16)
    private var touchScrollAccumulator = TerminalTouchScrollAccumulator()
    private var touchScrollMomentumDisplayLink: CADisplayLink?
    private var touchScrollMomentumVelocityY: CGFloat = 0
    private var touchScrollMomentumTimestamp: CFTimeInterval = 0
    var controlKeyboardHeight = TerminalControlKeyboardView.defaultHeight

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

    override var inputAccessoryView: UIView? {
        terminalKeyboardAccessory
    }

    /// Only a tap on the input row raises the keyboard, so the surface refuses
    /// first responder until asked. The flag tracks the *user's* intent and
    /// survives a UIKit-initiated resign on purpose: backgrounding the app or
    /// presenting a sheet resigns the first responder, and UIKit restores it
    /// afterwards by asking again. Clearing the flag there would have UIKit
    /// refused — leaving the accessory bar on screen with no keyboard behind
    /// it and no way to type. `dismissKeyboard()` is what clears it.
    override var canBecomeFirstResponder: Bool {
        allowsKeyboardActivation
    }

    init(
        frame: CGRect,
        onSizeChanged: ((Int, Int) -> Void)?,
        onSend: ((Data) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        onSnippet: ((String, Bool) -> Void)?,
        theme: TerminalTheme,
        fontSize: Float
    ) {
        let callbackBridge = TerminalSessionCallbackBridge(
            onSizeChanged: onSizeChanged,
            onSend: onSend,
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
            terminalConfiguration: TerminalConfiguration().fontSize(clampedFontSize))
        appliedTheme = theme
        appliedFontSize = clampedFontSize
        super.init(frame: frame)
        pasteConfiguration = UIPasteConfiguration(forAccepting: String.self)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        controller = terminalController
        callbackBridge.onViewport = { [weak self] viewport in
            self?.updateTouchScrollMetrics(viewport)
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
        onSend: ((Data) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        onSnippet: ((String, Bool) -> Void)?
    ) {
        callbackBridge.onSizeChanged = onSizeChanged
        callbackBridge.onSend = onSend
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

    /// Applies a zoom the user performed on this terminal and reports it, so
    /// the global setting follows the gesture instead of fighting it.
    private func zoom(to fontSize: Float) {
        guard applyFontSize(fontSize) else { return }
        onFontSizeChanged?(appliedFontSize)
    }

    func receive(_ data: Data) {
        modeTracker.receive(data)
        terminalSession.receive(data)
    }

    /// Raises the keyboard, and records that the user wants it up.
    func requestKeyboard() {
        allowsKeyboardActivation = true
        _ = becomeFirstResponder()
    }

    /// Takes the keyboard down on the user's behalf. This is the *only* way
    /// the keyboard goes away for good: a plain `resignFirstResponder()` is
    /// something UIKit does on its own (backgrounding, a sheet taking focus)
    /// and must stay recoverable.
    @discardableResult
    func dismissKeyboard() -> Bool {
        allowsKeyboardActivation = false
        return resignFirstResponder()
    }

    func setLocalInputEnabled(_ isEnabled: Bool) {
        guard isLocalInputEnabled != isEnabled else { return }
        isLocalInputEnabled = isEnabled
        terminalKeyboardAccessory.setPasteEnabled(isEnabled)
        terminalInputView?.isUserInteractionEnabled = isEnabled
        terminalInputView?.alpha = isEnabled ? 1 : 0.5
    }

    func requestPaste(_ text: String?) {
        guard isLocalInputEnabled, let text else { return }
        callbackBridge.paste(text, bracketed: usesBracketedPaste)
    }

    /// Sends a Snippet the user tapped in the Keys keyboard.
    func sendSnippet(_ snippet: Snippet) {
        guard isLocalInputEnabled else { return }
        callbackBridge.snippet(snippet.body, bracketed: usesBracketedPaste)
    }

    override func paste(_ sender: Any?) {
        requestPaste(UIPasteboard.general.string)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        reloadInputViewsAfterWindowResize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTouchScrollMomentum()
        }
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === touchScrollGesture {
            let velocity = touchScrollGesture.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        if gestureRecognizer === tapGesture {
            // A TUI that tracks the mouse wants every tap; otherwise only the
            // input row is interactive, and it just raises the keyboard.
            return modeTracker.tracksMouse
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
        return TerminalKeyboardTapTarget.region(caretRect: caret, in: bounds)
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
            rows: terminalGridSize.rows)
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
            for _ in 0..<rowCount {
                terminalSession.sendInput(sequence)
            }
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
        let location = gesture.location(in: self)
        clickTouch(at: location)
        // The click reaches the TUI, but the keyboard still only follows a tap
        // on the input row — a tap meant for a menu item must not raise it.
        if keyboardActivationRegion.contains(location) {
            requestKeyboard()
        }
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

    private func startTouchScrollMomentum(velocityY: CGFloat) {
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
}
