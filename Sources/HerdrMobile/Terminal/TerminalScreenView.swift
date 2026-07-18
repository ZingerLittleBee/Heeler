import SwiftTerm
import SwiftUI
import UIKit

/// The shared SwiftTerm surface: Observe (#9) renders it read-only, Attach
/// (#11) drives the same view with `allowsInput` and `onSend` wired. Bytes
/// arrive through a `TerminalByteFeed`; geometry flows out through
/// `onSizeChanged` so the store can start (or resize) the remote stream with
/// the real cols/rows.
struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    var allowsInput = false
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    /// Keystrokes the terminal wants sent to the remote; nil (Observe)
    /// discards them — this surface never sends input (CONTEXT.md).
    var onSend: ((Data) -> Void)?

    func makeUIView(context: Context) -> SizeReportingTerminalView {
        let view = SizeReportingTerminalView(frame: .zero)
        view.allowsInput = allowsInput
        view.terminalDelegate = context.coordinator
        view.onSizeReport = { [weak coordinator = context.coordinator] cols, rows in
            coordinator?.onSizeChanged?(cols, rows)
        }
        feed.attach { [weak view] data in
            view?.feed(byteArray: ArraySlice([UInt8](data)))
        }
        return view
    }

    func updateUIView(_ view: SizeReportingTerminalView, context: Context) {
        view.allowsInput = allowsInput
        context.coordinator.onSizeChanged = onSizeChanged
        context.coordinator.onSend = onSend
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSizeChanged: onSizeChanged, onSend: onSend)
    }

    /// SwiftTerm's delegate protocol is not actor-annotated but the view
    /// only calls it on the main thread (a UIView driving UIKit callbacks);
    /// the nonisolated shims hop back in via `assumeIsolated`, which traps —
    /// loudly, by design — if SwiftTerm ever grows an off-main call site.
    @MainActor
    final class Coordinator: TerminalViewDelegate {
        var onSizeChanged: ((Int, Int) -> Void)?
        var onSend: ((Data) -> Void)?

        init(onSizeChanged: ((Int, Int) -> Void)?, onSend: ((Data) -> Void)?) {
            self.onSizeChanged = onSizeChanged
            self.onSend = onSend
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
        ) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// TerminalView with three app-side behaviors: input is opt-in (read-only
/// Observe must never pop a keyboard) and grabs focus on appearance so both
/// the soft keyboard and iPad hardware keyboards work without a preliminary
/// tap, and the current cols/rows are reported from layout — the stock view
/// only reports *changes*, which would leave a store waiting forever when
/// the laid-out size happens to equal SwiftTerm's 80x25 default.
final class SizeReportingTerminalView: TerminalView {
    var allowsInput = false
    var onSizeReport: ((_ cols: Int, _ rows: Int) -> Void)?
    private var lastReported: (cols: Int, rows: Int)?

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
        guard bounds.width > 0, bounds.height > 0 else { return }
        let terminal = getTerminal()
        let size = (cols: terminal.cols, rows: terminal.rows)
        if let lastReported, lastReported == size { return }
        lastReported = size
        onSizeReport?(size.cols, size.rows)
    }
}
