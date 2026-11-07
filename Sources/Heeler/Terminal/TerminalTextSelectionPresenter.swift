import UIKit

@MainActor
enum TerminalTextSelectionPresenter {
    /// Chat's Select Text: the whole message in the reading font, selected.
    static func present(
        text: String, font: UIFont, adjustsFontForContentSizeCategory: Bool,
        accessibilityIdentifier: String, from sourceView: UIView
    ) {
        present(
            TerminalTextSelectionViewController(
                text: text, font: font,
                adjustsFontForContentSizeCategory: adjustsFontForContentSizeCategory,
                accessibilityIdentifier: accessibilityIdentifier),
            from: sourceView)
    }

    private static func present(_ selection: TerminalTextSelectionViewController, from sourceView: UIView) {
        guard let presentingViewController = sourceView.nearestPresentingViewController else {
            return
        }
        let navigation = UINavigationController(rootViewController: selection)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        presentingViewController.present(navigation, animated: true)
    }
}

@MainActor
final class TerminalTextSelectionViewController: UIViewController {
    private let text: String
    private let font: UIFont
    private let adjustsFontForContentSizeCategory: Bool
    private let textAccessibilityIdentifier: String
    private let textView = UITextView()

    init(
        text: String, font: UIFont,
        adjustsFontForContentSizeCategory: Bool,
        accessibilityIdentifier: String
    ) {
        self.text = text
        self.font = font
        self.adjustsFontForContentSizeCategory = adjustsFontForContentSizeCategory
        textAccessibilityIdentifier = accessibilityIdentifier
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
        textView.font = font
        textView.adjustsFontForContentSizeCategory = adjustsFontForContentSizeCategory
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.text = text
        textView.accessibilityIdentifier = textAccessibilityIdentifier
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        textView.selectedRange = NSRange(location: 0, length: (text as NSString).length)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    @objc private func dismissSelection() {
        dismiss(animated: true)
    }
}

extension UIView {
    /// The view controller a sheet presents from: the one showing this view,
    /// or whatever it already presents.
    var nearestPresentingViewController: UIViewController? {
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
