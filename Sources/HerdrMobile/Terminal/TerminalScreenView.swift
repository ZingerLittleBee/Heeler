import SwiftTerm
import SwiftUI
import UIKit

/// Presentation-specific terminal typography. Observe prioritizes fitting a
/// useful amount of a desktop transcript on a phone; Attach keeps SwiftTerm's
/// default size for interactive use.
enum TerminalScreenStyle: Equatable {
    case observe
    case attach

    fileprivate var font: UIFont? {
        switch self {
        case .observe:
            UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        case .attach:
            nil
        }
    }
}

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

/// Gates Observe history pagination to one request per visit to the top.
/// History snapshots are explicit events because applying one can move the
/// viewport while the original drag is still decelerating.
struct ObserveHistoryLoadGate {
    enum Event {
        case userScrolled(isAtTop: Bool)
        case historySnapshotApplied
    }

    private var requestedAtTop = false

    mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .userScrolled(isAtTop: true):
            guard !requestedAtTop else { return false }
            requestedAtTop = true
            return true
        case .userScrolled(isAtTop: false):
            requestedAtTop = false
            return false
        case .historySnapshotApplied:
            return false
        }
    }
}

/// The shared SwiftTerm surface: Observe (#9) renders it read-only, Attach
/// (#11) drives the same view with `allowsInput` and `onSend` wired. Bytes
/// arrive through a `TerminalByteFeed`; geometry flows out through
/// `onSizeChanged` so the store can start (or resize) the remote stream with
/// the real cols/rows.
struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    var style: TerminalScreenStyle = .observe
    var allowsInput = false
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    var onLoadEarlier: (() -> Bool)?
    /// Keystrokes the terminal wants sent to the remote; nil (Observe)
    /// discards them — this surface never sends input (CONTEXT.md).
    var onSend: ((Data) -> Void)?
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> SizeReportingTerminalView {
        let view = Self.makeConfiguredTerminal(style: style, allowsInput: allowsInput)
        view.terminalDelegate = context.coordinator
        view.onSizeReport = { [weak coordinator = context.coordinator] cols, rows in
            coordinator?.onSizeChanged?(cols, rows)
        }
        view.onLoadEarlier = { [weak coordinator = context.coordinator] in
            coordinator?.onLoadEarlier?() ?? false
        }
        feed.attachDeliveries { [weak view] delivery in
            view?.consume(delivery)
        }
        return view
    }

    @MainActor
    static func makeConfiguredTerminal(
        style: TerminalScreenStyle, allowsInput: Bool
    ) -> SizeReportingTerminalView {
        let view = SizeReportingTerminalView(frame: .zero, font: style.font)
        // SwiftTerm installs a terminal shortcut bar by default. Attach uses
        // only the standard iOS keyboard, with no app-provided accessory UI.
        view.inputAccessoryView = nil
        view.allowsInput = allowsInput
        if style == .observe {
            // herdr exposes up to 1,000 logical lines. Phone-width wrapping
            // can turn those into several thousand terminal rows.
            view.changeScrollback(5_000)
        }
        return view
    }

    func updateUIView(_ view: SizeReportingTerminalView, context: Context) {
        view.allowsInput = allowsInput
        context.coordinator.onSizeChanged = onSizeChanged
        context.coordinator.onLoadEarlier = onLoadEarlier
        context.coordinator.onSend = onSend
        context.coordinator.onOpenLink = { url in openURL(url) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSizeChanged: onSizeChanged, onLoadEarlier: onLoadEarlier, onSend: onSend,
            onOpenLink: { url in openURL(url) })
    }

    /// SwiftTerm's delegate protocol is not actor-annotated but the view
    /// only calls it on the main thread (a UIView driving UIKit callbacks);
    /// the nonisolated shims hop back in via `assumeIsolated`, which traps —
    /// loudly, by design — if SwiftTerm ever grows an off-main call site.
    @MainActor
    final class Coordinator: TerminalViewDelegate {
        var onSizeChanged: ((Int, Int) -> Void)?
        var onLoadEarlier: (() -> Bool)?
        var onSend: ((Data) -> Void)?
        var onOpenLink: ((URL) -> Void)?

        init(
            onSizeChanged: ((Int, Int) -> Void)?, onLoadEarlier: (() -> Bool)? = nil,
            onSend: ((Data) -> Void)?, onOpenLink: ((URL) -> Void)? = nil
        ) {
            self.onSizeChanged = onSizeChanged
            self.onLoadEarlier = onLoadEarlier
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

/// TerminalView with three app-side behaviors: input is opt-in (read-only
/// Observe never pops a keyboard or displays a cursor), interactive Attach
/// grabs focus on appearance, and the current cols/rows are reported from
/// layout. The stock view only reports *changes*, which would leave a store
/// waiting forever when the laid-out size equals SwiftTerm's 80x25 default.
final class SizeReportingTerminalView: TerminalView {
    var allowsInput = true {
        didSet {
            guard oldValue != allowsInput else { return }
            if allowsInput {
                getTerminal().showCursor()
            } else {
                getTerminal().hideCursor()
            }
        }
    }
    var onSizeReport: ((_ cols: Int, _ rows: Int) -> Void)?
    var onLoadEarlier: (() -> Bool)?
    private var lastReported: (cols: Int, rows: Int)?
    private var lastInputWindowSize: CGSize?
    private var defersScrollerUpdates = false
    private var pendingReadOnlySnapshot: Data?
    private var appliesReadOnlySnapshot = false
    private var browsesHistory = false
    private var historyLoadGate = ObserveHistoryLoadGate()

    private struct ViewportAnchor {
        let signature: [String]
        let row: Int
        let totalRows: Int
    }

    /// Feeds one transport delivery as an atomic visual update. Observe
    /// replaces its entire snapshot in one delivery; SwiftTerm otherwise
    /// updates `contentSize` for every rebuilt line, which makes the scroll
    /// indicator collapse and grow. While the user browses history, keep only
    /// the latest snapshot pending and apply it on returning to the bottom.
    /// Attach keeps SwiftTerm's normal incremental behavior.
    func consume(_ delivery: TerminalByteFeed.Delivery) {
        let data = delivery.data
        guard !data.isEmpty else { return }
        guard !allowsInput else {
            feed(byteArray: ArraySlice([UInt8](data)))
            return
        }

        if case .historySnapshot = delivery {
            let anchor = captureViewportAnchor()
            pendingReadOnlySnapshot = nil
            applyReadOnlySnapshot(data)
            restoreViewportAnchor(anchor)
            _ = historyLoadGate.handle(.historySnapshotApplied)
            browsesHistory = !isAtBottom
            return
        }

        if browsesHistory, !appliesReadOnlySnapshot {
            pendingReadOnlySnapshot = data
            return
        }

        applyReadOnlySnapshot(data)
    }

    private func applyReadOnlySnapshot(_ data: Data) {
        let terminal = getTerminal()
        appliesReadOnlySnapshot = true
        defersScrollerUpdates = true
        feed(byteArray: ArraySlice([UInt8](data)))
        defersScrollerUpdates = false
        super.scrolled(source: terminal, yDisp: terminal.getTopVisibleRow())
        appliesReadOnlySnapshot = false
    }

    private func captureViewportAnchor() -> ViewportAnchor? {
        let terminal = getTerminal()
        let row = terminal.getTopVisibleRow()
        let signature = (0..<min(8, terminal.rows)).compactMap { visibleRow in
            terminal.getLine(row: visibleRow)?.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true)
        }
        guard !signature.isEmpty else { return nil }
        return ViewportAnchor(signature: signature, row: row, totalRows: totalTerminalRows)
    }

    private func restoreViewportAnchor(_ anchor: ViewportAnchor?) {
        guard let anchor else { return }
        let terminal = getTerminal()
        let maximumTopRow = max(0, totalTerminalRows - terminal.rows)
        let predictedRow = min(
            maximumTopRow, max(0, anchor.row + totalTerminalRows - anchor.totalRows))
        var matchingRow: Int?
        var matchingDistance = Int.max

        for candidate in 0...maximumTopRow {
            let matches = anchor.signature.enumerated().allSatisfy { offset, expected in
                terminal.getScrollInvariantLine(row: candidate + offset)?.translateToString(
                    trimRight: true, skipNullCellsFollowingWide: true) == expected
            }
            guard matches else { continue }
            let distance = abs(candidate - predictedRow)
            if distance < matchingDistance {
                matchingRow = candidate
                matchingDistance = distance
            }
        }

        scrollTo(row: matchingRow ?? predictedRow, notifyAccessibility: false)
    }

    private var totalTerminalRows: Int {
        let lineHeight = max(1, ceil(font.lineHeight))
        return max(0, Int((contentSize.height / lineHeight).rounded()))
    }

    override func scrolled(source: Terminal, yDisp: Int) {
        guard !defersScrollerUpdates else { return }
        super.scrolled(source: source, yDisp: yDisp)
    }

    override var contentOffset: CGPoint {
        didSet {
            guard !allowsInput, !appliesReadOnlySnapshot else { return }
            guard isTracking || (browsesHistory && isDecelerating) else { return }
            handleUserScroll()
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !allowsInput else { return super.accessibilityScroll(direction) }
        let terminal = getTerminal()
        let originalRow = terminal.getTopVisibleRow()
        switch direction {
        case .up, .left, .previous:
            scrollUp(lines: terminal.rows)
        case .down, .right, .next:
            scrollDown(lines: terminal.rows)
        default:
            return super.accessibilityScroll(direction)
        }

        let didScroll = terminal.getTopVisibleRow() != originalRow
        guard didScroll else { return false }
        handleUserScroll()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return didScroll
    }

    private func handleUserScroll() {
        if historyLoadGate.handle(.userScrolled(isAtTop: isAtTop)) {
            _ = onLoadEarlier?()
        }
        updateHistoryBrowsing()
    }

    private func updateHistoryBrowsing() {
        if isAtBottom {
            browsesHistory = false
            guard let pendingReadOnlySnapshot else { return }
            self.pendingReadOnlySnapshot = nil
            consume(.bytes(pendingReadOnlySnapshot))
        } else {
            browsesHistory = true
        }
    }

    private var isAtBottom: Bool {
        let maximumOffset = max(
            0, contentSize.height - bounds.height + adjustedContentInset.bottom)
        return contentOffset.y >= maximumOffset - max(1, font.lineHeight / 2)
    }

    private var isAtTop: Bool {
        contentOffset.y <= max(1, font.lineHeight / 2)
    }

    override func showCursor(source: Terminal) {
        guard allowsInput else {
            source.hideCursor()
            return
        }
        super.showCursor(source: source)
    }

    override var canBecomeFirstResponder: Bool {
        allowsInput && super.canBecomeFirstResponder
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, allowsInput {
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
        guard allowsInput, let windowSize = window?.bounds.size else { return }
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
