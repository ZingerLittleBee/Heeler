import GhosttyTerminal
import UIKit

/// The selection sheet writes the highlighted text straight to the system
/// pasteboard. Keep that IPC behind a seam so unit tests never depend on the
/// Simulator pasteboard service being responsive.
@MainActor
struct TerminalTextSelectionCopy {
    let write: (String) -> Void

    static let system = TerminalTextSelectionCopy(
        write: { UIPasteboard.general.string = $0 })
}

@MainActor
enum TerminalTextSelectionPresenter {
    static func present(_ request: TerminalTextSelectionRequest, from sourceView: UIView) {
        guard let presentingViewController = sourceView.nearestPresentingViewController else {
            return
        }

        let selection = TerminalTextSelectionViewController(
            text: request.text,
            anchorRange: request.anchorRange,
            copy: .system)
        let navigation = UINavigationController(rootViewController: selection)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        presentingViewController.present(navigation, animated: true)
    }
}

/// Long-press selection sheet over a snapshot of the terminal buffer. The
/// highlight copies itself once it settles, so selecting text here behaves
/// like the pane's own copy-on-select instead of needing a second tap.
@MainActor
final class TerminalTextSelectionViewController: UIViewController {
    private let text: String
    private let anchorRange: NSRange?
    private let copy: TerminalTextSelectionCopy
    private let textView = UITextView()
    private var lastCopied: String?
    private var pendingCopy: Task<Void, Never>?

    init(text: String, anchorRange: NSRange?, copy: TerminalTextSelectionCopy) {
        self.text = text
        self.anchorRange = anchorRange
        self.copy = copy
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Dragging the selection handles fires the delegate continuously; wait
    /// for the highlight to settle before copying, the same debounce shape
    /// the keyboard inset uses to coalesce its own bursts.
    private static let copySettleDelay = Duration.milliseconds(350)

    /// The sheet falls back to selecting the whole buffer when the long-press
    /// anchor is unusable. Auto-copying that would silently replace the user's
    /// clipboard with the entire scrollback, so only a strict subrange copies.
    static func copyableRange(_ selection: NSRange, textLength: Int) -> NSRange? {
        guard selection.location != NSNotFound,
            selection.length > 0,
            selection.location <= textLength,
            selection.length <= textLength - selection.location,
            selection.length < textLength
        else { return nil }
        return selection
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Select Text"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissSelection))

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.text = text
        textView.accessibilityIdentifier = "terminal.text-selection"
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        textView.delegate = self
        textView.selectedRange = Self.normalizedSelectionRange(
            anchorRange,
            textLength: (text as NSString).length)
        copyInitialSelection()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    static func normalizedSelectionRange(_ range: NSRange?, textLength: Int) -> NSRange {
        guard let range,
            range.location <= textLength,
            range.length <= textLength - range.location
        else {
            return NSRange(location: 0, length: textLength)
        }
        return range
    }

    /// The long-press anchor already names the word under the press, so copy
    /// it right away instead of waiting for a settle delay that never comes.
    private func copyInitialSelection() {
        guard let anchorRange,
            anchorRange.location != NSNotFound,
            anchorRange.location <= (text as NSString).length,
            anchorRange.length <= (text as NSString).length - anchorRange.location
        else { return }
        copyCurrentSelection()
    }

    private func scheduleCopy() {
        pendingCopy?.cancel()
        pendingCopy = Task { [weak self] in
            try? await Task.sleep(for: Self.copySettleDelay)
            guard !Task.isCancelled, let self else { return }
            self.copyCurrentSelection()
        }
    }

    private func copyCurrentSelection() {
        guard let range = Self.copyableRange(
            textView.selectedRange,
            textLength: (text as NSString).length)
        else { return }
        let selected = (text as NSString).substring(with: range)
        guard selected != lastCopied else { return }
        lastCopied = selected
        copy.write(selected)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        navigationItem.prompt = "Copied"
        UIAccessibility.post(notification: .announcement, argument: "Copied")
    }

    @objc private func dismissSelection() {
        dismiss(animated: true)
    }
}

extension TerminalTextSelectionViewController: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        navigationItem.prompt = nil
        scheduleCopy()
    }
}

extension UIView {
    fileprivate var nearestPresentingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController.topmostPresentedViewController
            }
            responder = current.next
        }
        return window?.rootViewController?.topmostPresentedViewController
    }
}

extension UIViewController {
    fileprivate var topmostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topmostPresentedViewController
        }
        if let navigation = self as? UINavigationController,
            let visible = navigation.visibleViewController
        {
            return visible.topmostPresentedViewController
        }
        if let tab = self as? UITabBarController,
            let selected = tab.selectedViewController
        {
            return selected.topmostPresentedViewController
        }
        return self
    }
}
