import UIKit

/// The zoomable sheet a row's thumbnail opens. A long press previews it
/// and becomes the sheet when committed.
@MainActor
final class ChatImagePreviewController: UIViewController, UIScrollViewDelegate {
    typealias Loader = @MainActor (String) async throws -> Data
    /// Turns what was read into the picture to show; a still picture at
    /// most 4,096 pixels on its long edge unless the caller says otherwise.
    typealias Decoder = @Sendable (Data) async throws -> UIImage
    let path: String
    /// The row's thumbnail, shown until the file is read.
    private let placeholder: UIImage?
    private let onDone: (() -> Void)?
    private let loadImage: Loader
    private let decodeImage: Decoder
    /// Whether an animated GIF or PNG plays rather than shows its first
    /// frame.
    private let animatesImages: Bool
    private let scroll = UIScrollView()
    private let imageView = AnimatedImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let message = UILabel()
    private let retry = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?
    private var lastSize = CGSize.zero
    private(set) var isLoaded = false

    init(
        path: String,
        displayTitle: String? = nil,
        placeholder: UIImage? = nil,
        onDone: (() -> Void)? = nil,
        decodeImage: @escaping Decoder = ChatImagePreviewController.stillImage,
        animatesImages: Bool = false,
        loadImage: @escaping Loader
    ) {
        self.path = path
        self.placeholder = placeholder
        self.onDone = onDone
        self.decodeImage = decodeImage
        self.animatesImages = animatesImages
        self.loadImage = loadImage
        super.init(nibName: nil, bundle: nil)
        title = displayTitle ?? (path as NSString).lastPathComponent
        preferredContentSize = CGSize(width: 340, height: 340)
    }

    required init?(coder: NSCoder) { nil }

    /// A still picture at most 4,096 pixels on its long edge.
    nonisolated static func stillImage(_ data: Data) async throws -> UIImage {
        UIImage(cgImage: try await ChatImagePreviewDecoder.shared.decode(data))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "chat.image-preview"
        scroll.delegate = self
        scroll.maximumZoomScale = 6
        scroll.accessibilityIdentifier = "chat.image-preview.zoom"
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
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
        retry.setTitle(String(localized: "Retry"), for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.startLoading() }, for: .touchUpInside)
        view.addSubview(retry)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                if let onDone = self?.onDone {
                    onDone()
                } else {
                    self?.dismiss(animated: true)
                }
            })
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

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard isLoaded || imageView.image != nil else { return }
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
            return
        }
        let targetScale: CGFloat = 2.5
        let point = recognizer.location(in: imageView)
        let size = CGSize(
            width: scroll.bounds.width / targetScale,
            height: scroll.bounds.height / targetScale)
        let origin = CGPoint(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2)
        scroll.zoom(to: CGRect(origin: origin, size: size), animated: true)
    }

    private func startLoading() {
        loadTask?.cancel()
        message.text = nil
        retry.isHidden = true
        if !isLoaded { imageView.image = placeholder }
        spinner.startAnimating()
        loadTask = Task { [weak self, path, loadImage, decodeImage] in
            do {
                let data = try await loadImage(path)
                let decoded = try await decodeImage(data)
                try Task.checkCancellation()
                guard let self else { return }
                imageView.image = decoded
                if animatesImages, AnimatedImageView.isAnimated(data) { imageView.animationData = data }
                isLoaded = true
                spinner.stopAnimating()
                loadTask = nil
                view.setNeedsLayout()
            } catch {
                guard !Task.isCancelled, let self else { return }
                spinner.stopAnimating()
                imageView.image = nil
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
