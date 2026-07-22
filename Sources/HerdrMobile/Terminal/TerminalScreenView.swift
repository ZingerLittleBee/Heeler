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
    private lazy var alternateScreenPan = UIPanGestureRecognizer(
        target: self, action: #selector(handleAlternateScreenPan(_:)))

    func installAlternateScreenScrolling() {
        guard !installedAlternateScreenScrolling else { return }
        installedAlternateScreenScrolling = true
        alternateScreenPan.delegate = self
        alternateScreenPan.cancelsTouchesInView = false
        addGestureRecognizer(alternateScreenPan)
    }

    /// Converts one vertical drag threshold into one terminal page command.
    /// A downward finger movement requests older content; upward requests newer.
    @discardableResult
    func scrollAlternateScreen(translationY: CGFloat) -> Bool {
        guard getTerminal().isCurrentBufferAlternate, !hasActiveSelection else { return false }
        let threshold = max(44, bounds.height * 0.18)
        guard abs(translationY) >= threshold else { return false }
        if translationY > 0 {
            pageUp()
        } else {
            pageDown()
        }
        return true
    }

    @objc private func handleAlternateScreenPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        if scrollAlternateScreen(translationY: gesture.translation(in: self).y) {
            gesture.setTranslation(.zero, in: self)
        }
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
        gestureRecognizer === alternateScreenPan || otherGestureRecognizer === alternateScreenPan
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            _ = becomeFirstResponder()
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
