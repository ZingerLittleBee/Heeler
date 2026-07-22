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
    var keyboardRequestID = 0
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> HerdrTerminalView {
        let view = Self.makeConfiguredTerminal(
            onSizeChanged: onSizeChanged,
            onSend: onSend)
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
        onSend: ((Data) -> Void)? = nil
    ) -> HerdrTerminalView {
        let view = HerdrTerminalView(
            frame: .zero,
            onSizeChanged: onSizeChanged,
            onSend: onSend)
        view.installKeyboardSwitcher()
        return view
    }

    func updateUIView(_ view: HerdrTerminalView, context: Context) {
        view.updateCallbacks(onSizeChanged: onSizeChanged, onSend: onSend)
        context.coordinator.onOpenLink = { url in openURL(url) }
        if context.coordinator.keyboardRequestID != keyboardRequestID {
            context.coordinator.keyboardRequestID = keyboardRequestID
            view.requestKeyboard()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            keyboardRequestID: keyboardRequestID,
            onOpenLink: { url in openURL(url) })
    }

    @MainActor
    final class Coordinator: NSObject, TerminalSurfaceOpenURLDelegate,
        TerminalSurfaceTextSelectionRequestDelegate
    {
        weak var terminalView: HerdrTerminalView?
        var keyboardRequestID: Int
        var onOpenLink: ((URL) -> Void)?

        init(keyboardRequestID: Int, onOpenLink: ((URL) -> Void)? = nil) {
            self.keyboardRequestID = keyboardRequestID
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
    var onViewport: ((InMemoryTerminalViewport) -> Void)?

    init(
        onSizeChanged: ((Int, Int) -> Void)?,
        onSend: ((Data) -> Void)?
    ) {
        self.onSizeChanged = onSizeChanged
        self.onSend = onSend
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
}

/// The app-owned seam around libghostty-spm. It keeps keyboard policy and the
/// host-managed session lifecycle out of the SwiftUI screen.
final class HerdrTerminalView: UITerminalView {
    private let callbackBridge: TerminalSessionCallbackBridge
    let terminalSession: InMemoryTerminalSession
    private var terminalInputView: UIView?
    private var modeTracker = TerminalModeTracker()
    private var lastInputWindowSize: CGSize?
    private var allowsKeyboardActivation = false
    private var terminalGridSize = (columns: 80, rows: 24)
    private var touchScrollPointsPerRow: CGFloat = 16
    private var touchScrollAccumulator = TerminalTouchScrollAccumulator()
    private var touchScrollMomentumDisplayLink: CADisplayLink?
    private var touchScrollMomentumVelocityY: CGFloat = 0
    private var touchScrollMomentumTimestamp: CFTimeInterval = 0
    var controlKeyboardHeight = TerminalControlKeyboardView.defaultHeight

    private lazy var touchScrollGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTouchScrollGesture(_:)))

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

    override var canBecomeFirstResponder: Bool {
        allowsKeyboardActivation
    }

    init(
        frame: CGRect,
        onSizeChanged: ((Int, Int) -> Void)?,
        onSend: ((Data) -> Void)?
    ) {
        let callbackBridge = TerminalSessionCallbackBridge(
            onSizeChanged: onSizeChanged,
            onSend: onSend)
        self.callbackBridge = callbackBridge
        terminalSession = InMemoryTerminalSession(
            write: { [weak callbackBridge] data in
                callbackBridge?.send(data)
            },
            resize: { [weak callbackBridge] viewport in
                callbackBridge?.resize(viewport)
            })
        super.init(frame: frame)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        controller = TerminalController()
        callbackBridge.onViewport = { [weak self] viewport in
            self?.updateTouchScrollMetrics(viewport)
        }
        installTouchScrolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func updateCallbacks(
        onSizeChanged: ((Int, Int) -> Void)?,
        onSend: ((Data) -> Void)?
    ) {
        callbackBridge.onSizeChanged = onSizeChanged
        callbackBridge.onSend = onSend
    }

    func receive(_ data: Data) {
        modeTracker.receive(data)
        terminalSession.receive(data)
    }

    func requestKeyboard() {
        allowsKeyboardActivation = true
        _ = becomeFirstResponder()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        allowsKeyboardActivation = false
        return resigned
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

    func setTerminalInputView(_ inputView: UIView?) {
        terminalInputView = inputView
    }

    @discardableResult
    func scrollTouch(translationY: CGFloat) -> Int {
        let rows = touchScrollAccumulator.rows(
            for: translationY,
            pointsPerRow: touchScrollPointsPerRow)
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

    private func updateTouchScrollMetrics(_ viewport: InMemoryTerminalViewport) {
        terminalGridSize = (Int(viewport.columns), Int(viewport.rows))
        guard viewport.cellHeightPixels > 0 else { return }
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        guard scale > 0 else { return }
        touchScrollPointsPerRow = max(8, CGFloat(viewport.cellHeightPixels) / scale)
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
