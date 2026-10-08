import UIKit

/// The long-press preview also becomes the zoomable sheet when committed.
@MainActor
final class ChatImagePreviewController: UIViewController, UIScrollViewDelegate {
    typealias Loader = @MainActor (String) async throws -> Data
    let path: String
    private let loadImage: Loader
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let message = UILabel()
    private let retry = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?
    private var lastSize = CGSize.zero
    private(set) var isLoaded = false

    init(path: String, loadImage: @escaping Loader) {
        self.path = path
        self.loadImage = loadImage
        super.init(nibName: nil, bundle: nil)
        title = (path as NSString).lastPathComponent
        preferredContentSize = CGSize(width: 340, height: 340)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "chat.image-preview"
        scroll.delegate = self
        scroll.maximumZoomScale = 6
        scroll.accessibilityIdentifier = "chat.image-preview.zoom"
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = title
        scroll.addSubview(imageView)
        view.addSubview(scroll)
        view.addSubview(spinner)
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.accessibilityIdentifier = "chat.image-preview.message"
        view.addSubview(message)
        retry.setTitle("Retry", for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.startLoading() }, for: .touchUpInside)
        view.addSubview(retry)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        startLoading()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isLoaded, loadTask == nil { startLoading() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.safeAreaLayoutGuide.layoutFrame
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let textSize = message.sizeThatFits(CGSize(width: max(0, view.bounds.width - 40), height: .greatestFiniteMagnitude))
        message.frame = CGRect(x: 20, y: max(20, view.bounds.midY - textSize.height / 2 - 22),
                               width: max(0, view.bounds.width - 40), height: textSize.height)
        retry.frame = CGRect(x: 20, y: message.frame.maxY + 8, width: max(0, view.bounds.width - 40), height: 44)
        if scroll.bounds.size != lastSize {
            lastSize = scroll.bounds.size
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    private func startLoading() {
        loadTask?.cancel()
        message.text = nil
        retry.isHidden = true
        spinner.startAnimating()
        loadTask = Task { [weak self, path, loadImage] in
            do {
                let data = try await loadImage(path)
                let decoded = try await ChatImagePreviewDecoder.shared.decode(data)
                try Task.checkCancellation()
                guard let self else { return }
                imageView.image = UIImage(cgImage: decoded)
                isLoaded = true
                spinner.stopAnimating()
                loadTask = nil
                view.setNeedsLayout()
            } catch {
                guard !Task.isCancelled, let self else { return }
                spinner.stopAnimating()
                message.text = error.localizedDescription
                retry.isHidden = false
                loadTask = nil
                view.setNeedsLayout()
            }
        }
    }

    func present(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        presenter.present(navigation, animated: true)
    }
}
