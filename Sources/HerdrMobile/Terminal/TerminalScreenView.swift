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
    private var cursorMode = TerminalCursorModeTracker()
    private var lastInputWindowSize: CGSize?
    var controlKeyboardHeight = TerminalControlKeyboardView.defaultHeight

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
        cursorMode.receive(data)
        terminalSession.receive(data)
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
        cursorMode.usesApplicationCursorKeys
    }

    func setTerminalInputView(_ inputView: UIView?) {
        terminalInputView = inputView
    }
}

struct TerminalCursorModeTracker {
    private static let enableSequence = Data([0x1B, 0x5B, 0x3F, 0x31, 0x68])
    private static let disableSequence = Data([0x1B, 0x5B, 0x3F, 0x31, 0x6C])
    private static let retainedByteCount = max(enableSequence.count, disableSequence.count) - 1

    private var pending = Data()
    private(set) var usesApplicationCursorKeys = false

    mutating func receive(_ data: Data) {
        pending.append(data)

        while true {
            let enableRange = pending.range(of: Self.enableSequence)
            let disableRange = pending.range(of: Self.disableSequence)
            let next: (range: Range<Data.Index>, enabled: Bool)?

            switch (enableRange, disableRange) {
            case (.some(let enable), .some(let disable)):
                next =
                    enable.lowerBound < disable.lowerBound
                    ? (enable, true)
                    : (disable, false)
            case (.some(let enable), .none):
                next = (enable, true)
            case (.none, .some(let disable)):
                next = (disable, false)
            case (.none, .none):
                next = nil
            }

            guard let next else { break }
            usesApplicationCursorKeys = next.enabled
            pending.removeSubrange(pending.startIndex..<next.range.upperBound)
        }

        if pending.count > Self.retainedByteCount {
            pending = Data(pending.suffix(Self.retainedByteCount))
        }
    }
}
