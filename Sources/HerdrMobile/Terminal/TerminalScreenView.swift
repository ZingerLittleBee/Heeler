import SwiftTerm
import SwiftUI
import UIKit

/// Remote terminal output is untrusted. Only ordinary web links cross from
/// SwiftTerm into the system URL opener; local files and executable schemes do not.
enum TerminalLinkPolicy {
    static func url(for link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard (scheme == "http" || scheme == "https"), url.host != nil else { return nil }
        return url
    }
}

/// The interactive SwiftTerm surface. PTY bytes flow into the view, geometry
/// changes flow to the remote PTY, and keystrokes flow back to Attach.
struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    var onSend: ((Data) -> Void)?
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> SizeReportingTerminalView {
        let view = Self.makeConfiguredTerminal()
        view.terminalDelegate = context.coordinator
        view.onSizeReport = { [weak coordinator = context.coordinator] cols, rows in
            coordinator?.onSizeChanged?(cols, rows)
        }
        feed.attach { [weak view] data in
            view?.feed(byteArray: ArraySlice([UInt8](data)))
        }
        return view
    }

    @MainActor
    static func makeConfiguredTerminal() -> SizeReportingTerminalView {
        let view = SizeReportingTerminalView(frame: .zero, font: nil)
        view.inputAccessoryView = nil
        view.keyboardDismissMode = .interactive
        view.installAlternateScreenScrolling()
        return view
    }

    func updateUIView(_ view: SizeReportingTerminalView, context: Context) {
        context.coordinator.onSizeChanged = onSizeChanged
        context.coordinator.onSend = onSend
        context.coordinator.onOpenLink = { url in openURL(url) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSizeChanged: onSizeChanged, onSend: onSend,
            onOpenLink: { url in openURL(url) })
    }

    @MainActor
    final class Coordinator: TerminalViewDelegate {
        var onSizeChanged: ((Int, Int) -> Void)?
        var onSend: ((Data) -> Void)?
        var onOpenLink: ((URL) -> Void)?

        init(
            onSizeChanged: ((Int, Int) -> Void)?, onSend: ((Data) -> Void)?,
            onOpenLink: ((URL) -> Void)? = nil
        ) {
            self.onSizeChanged = onSizeChanged
            self.onSend = onSend
            self.onOpenLink = onOpenLink
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { onSizeChanged?(newCols, newRows) }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated { onSend?(bytes) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(
            source: TerminalView, link: String, params: [String: String]
        ) {
            guard let url = TerminalLinkPolicy.url(for: link) else { return }
            MainActor.assumeIsolated { onOpenLink?(url) }
        }
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Reports initial terminal geometry and adds direct touch scrolling for
/// alternate-screen TUIs. SwiftTerm's native UIScrollView remains untouched
/// for the normal buffer and its local scrollback.
final class SizeReportingTerminalView: TerminalView, UIGestureRecognizerDelegate {
    var onSizeReport: ((_ cols: Int, _ rows: Int) -> Void)?
    private var lastReported: (cols: Int, rows: Int)?
    private var lastInputWindowSize: CGSize?
    private var installedAlternateScreenScrolling = false
    private var alternateScrollRemainder: CGFloat = 0
    private var scrollMomentumDisplayLink: CADisplayLink?
    private var scrollMomentumVelocityY: CGFloat = 0
    private var scrollMomentumTimestamp: CFTimeInterval = 0
    private lazy var alternateScreenPan = UIPanGestureRecognizer(
        target: self, action: #selector(handleAlternateScreenPan(_:)))

    var alternateScrollStep: CGFloat {
        max(1, font.lineHeight)
    }

    func installAlternateScreenScrolling() {
        guard !installedAlternateScreenScrolling else { return }
        installedAlternateScreenScrolling = true
        alternateScreenPan.delegate = self
        alternateScreenPan.cancelsTouchesInView = false
        addGestureRecognizer(alternateScreenPan)
    }

    /// Converts finger travel into terminal wheel rows. Alternate buffers do
    /// not own local scrollback, so the remote TUI remains the source of truth.
    @discardableResult
    func scrollAlternateScreen(translationY: CGFloat) -> Int {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate, !hasActiveSelection else {
            alternateScrollRemainder = 0
            return 0
        }
        if alternateScrollRemainder * translationY < 0 {
            alternateScrollRemainder = 0
        }
        alternateScrollRemainder += translationY
        let lineCount = Int(abs(alternateScrollRemainder) / alternateScrollStep)
        guard lineCount > 0 else { return 0 }
        let movesTowardOlderContent = alternateScrollRemainder > 0
        alternateScrollRemainder.formTruncatingRemainder(dividingBy: alternateScrollStep)
        sendScrollRows(lineCount, towardOlderContent: movesTowardOlderContent)
        return lineCount
    }

    @objc private func handleAlternateScreenPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopScrollMomentum()
            alternateScrollRemainder = 0
        case .changed:
            _ = scrollAlternateScreen(translationY: gesture.translation(in: self).y)
            gesture.setTranslation(.zero, in: self)
        case .ended:
            startScrollMomentum(velocityY: gesture.velocity(in: self).y)
        case .cancelled, .failed:
            stopScrollMomentum()
            alternateScrollRemainder = 0
        default:
            break
        }
    }

    private func sendScrollRows(_ count: Int, towardOlderContent: Bool) {
        let terminal = getTerminal()
        switch terminal.mouseMode {
        case .off:
            let bytes =
                towardOlderContent
                ? (terminal.applicationCursor
                    ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                : (terminal.applicationCursor
                    ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0..<count {
                send(bytes)
            }
        default:
            let button = towardOlderContent ? 4 : 5
            let buttonFlags = terminal.encodeButton(
                button: button, release: false, shift: false, meta: false, control: false)
            let column = max(0, (terminal.cols - 1) / 2)
            let row = max(0, (terminal.rows - 1) / 2)
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let pixelX = Int(bounds.midX * scale)
            let pixelY = Int(bounds.midY * scale)
            for _ in 0..<count {
                terminal.sendEvent(
                    buttonFlags: buttonFlags, x: column, y: row,
                    pixelX: pixelX, pixelY: pixelY)
            }
        }
    }

    private func startScrollMomentum(velocityY: CGFloat) {
        guard abs(velocityY) >= 80, getTerminal().isCurrentBufferAlternate else {
            alternateScrollRemainder = 0
            return
        }
        stopScrollMomentum()
        scrollMomentumVelocityY = max(-4_000, min(4_000, velocityY))
        scrollMomentumTimestamp = 0
        let displayLink = CADisplayLink(target: self, selector: #selector(advanceScrollMomentum(_:)))
        scrollMomentumDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func advanceScrollMomentum(_ displayLink: CADisplayLink) {
        guard getTerminal().isCurrentBufferAlternate, abs(scrollMomentumVelocityY) >= 20 else {
            stopScrollMomentum()
            alternateScrollRemainder = 0
            return
        }
        guard scrollMomentumTimestamp > 0 else {
            scrollMomentumTimestamp = displayLink.timestamp
            return
        }
        let elapsed = min(1.0 / 30.0, displayLink.timestamp - scrollMomentumTimestamp)
        scrollMomentumTimestamp = displayLink.timestamp
        _ = scrollAlternateScreen(translationY: scrollMomentumVelocityY * elapsed)
        scrollMomentumVelocityY *= pow(0.998, elapsed * 1_000)
    }

    private func stopScrollMomentum() {
        scrollMomentumDisplayLink?.invalidate()
        scrollMomentumDisplayLink = nil
        scrollMomentumVelocityY = 0
        scrollMomentumTimestamp = 0
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === alternateScreenPan else { return true }
        let velocity = alternateScreenPan.velocity(in: self)
        return getTerminal().isCurrentBufferAlternate
            && !hasActiveSelection
            && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === alternateScreenPan && otherGestureRecognizer === panGestureRecognizer)
            || (otherGestureRecognizer === alternateScreenPan
                && gestureRecognizer === panGestureRecognizer)
    }

    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        prioritizeAlternateScreenScrollGesture()
    }

    private func prioritizeAlternateScreenScrollGesture() {
        for case let gesture as UIPanGestureRecognizer in gestureRecognizers ?? []
        where gesture !== alternateScreenPan && gesture !== panGestureRecognizer {
            gesture.require(toFail: alternateScreenPan)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            _ = becomeFirstResponder()
        } else {
            stopScrollMomentum()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reloadInputViewsAfterWindowResize()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let terminal = getTerminal()
        let size = (cols: terminal.cols, rows: terminal.rows)
        if let lastReported, lastReported == size { return }
        lastReported = size
        onSizeReport?(size.cols, size.rows)
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
}
