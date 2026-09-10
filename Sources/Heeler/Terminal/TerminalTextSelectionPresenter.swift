import GhosttyTerminal
import UIKit

@MainActor
enum TerminalTextSelectionPresenter {
    static func present(_ request: TerminalTextSelectionRequest, from sourceView: UIView) {
        guard let presentingViewController = sourceView.nearestPresentingViewController else {
            return
        }

        let selection = TerminalTextSelectionViewController(
            text: request.text,
            anchorRange: request.anchorRange)
        let navigation = UINavigationController(rootViewController: selection)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        presentingViewController.present(navigation, animated: true)
    }
}

@MainActor
final class TerminalTextSelectionViewController: UIViewController {
    private let text: String
    private let anchorRange: NSRange?
    private let textView = UITextView()

    init(text: String, anchorRange: NSRange?) {
        self.text = text
        self.anchorRange = anchorRange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
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

        textView.selectedRange = Self.normalizedSelectionRange(
            anchorRange,
            textLength: (text as NSString).length)
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

    @objc private func dismissSelection() {
        dismiss(animated: true)
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
