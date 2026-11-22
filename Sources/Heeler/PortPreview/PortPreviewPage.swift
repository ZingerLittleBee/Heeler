import SwiftUI
import WebKit

/// The web view of one port preview, and what it has loaded.
///
/// Its website data lives only as long as the preview: every Host has a
/// `localhost`, and a cookie one Host's page set must not go to another's.
/// The web view connects to `localhost` on this device, where the preview
/// listens on each port a page is opened on, so nothing loads before
/// `carries` has answered for its port (ADR 0062).
@MainActor @Observable
final class PortPreviewPage: NSObject {
    enum Failure: Equatable {
        /// This device could not listen on the port.
        case portTaken(port: Int)
        case refused(port: Int)
        case forwardingDenied
        case unreachable(detail: String)
        /// The connection was made and the page still did not load, as when
        /// the port's program does not speak HTTP.
        case other(message: String)
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(Failure)
    }

    private(set) var phase = Phase.loading
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The page on screen or on its way: what the address shows, Copy Link
    /// copies and Try Again loads.
    private(set) var current: PortPreviewTarget
    /// Asks pages for the layout this kind of device does not get by default.
    var swapsContentMode = false {
        didSet { if oldValue != swapsContentMode { reload() } }
    }

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Counts the loads asked for, so one that waited for its port does not
    /// start after a later one.
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private let carries: @MainActor (Int) async -> Bool
    @ObservationIgnored private let recentFailure: (Int) -> PortPreviewFailure?
    @ObservationIgnored private let openExternally: (URL) -> Void

    /// `carries` makes a port on this device lead to the same port on the
    /// Host, and says whether it does.
    init(
        target: PortPreviewTarget, carries: @escaping @MainActor (Int) async -> Bool,
        recentFailure: @escaping (Int) -> PortPreviewFailure?, openExternally: @escaping (URL) -> Void
    ) {
        current = target
        self.carries = carries
        self.recentFailure = recentFailure
        self.openExternally = openExternally

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
        ]
        load(target)
    }

    func load(_ target: PortPreviewTarget) {
        load(target, as: URLRequest(url: target.url))
    }

    /// Loads `request`, which is addressed to `target`.
    private func load(_ target: PortPreviewTarget, as request: URLRequest) {
        current = target
        onceCarried(target.port) { $0.load(request) }
    }

    /// Loads the page again. After a failure that is the page that failed,
    /// which the web view itself never took as its own.
    func reload() {
        if case .failed = phase {
            load(current)
        } else if webView.url == nil {
            load(current)
        } else {
            onceCarried(current.port) { $0.reload() }
        }
    }

    /// Starts a load once this device listens on `port`, or says it cannot.
    /// A load asked for meanwhile takes this one's place.
    private func onceCarried(_ port: Int, _ start: @escaping (WKWebView) -> Void) {
        phase = .loading
        loads += 1
        let load = loads
        Task {
            let isCarried = await carries(port)
            guard load == loads else { return }
            if isCarried {
                start(webView)
            } else {
                webView.stopLoading()
                phase = .failed(.portTaken(port: port))
            }
        }
    }

    /// The page that failed, asked for over TLS: a port opened by its number
    /// is tried over plain HTTP first, and a server that only speaks TLS
    /// drops that.
    var secureRetry: PortPreviewTarget? {
        guard case .failed(.other) = phase else { return nil }
        return current.secured
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    /// What the page shows now, as a PNG.
    func snapshot() async -> Data? {
        let image = try? await webView.takeSnapshot(configuration: nil)
        return image?.pngData()
    }

    /// Stops the page: the preview is closing.
    func close() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func sync() {
        progress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if case .failed = phase { return }
        if let url = webView.url, let shown = PortPreviewTarget(link: url) {
            current = shown
        }
    }

    /// Where a request that would replace the page goes: a loopback address
    /// loads here, under `localhost`, and anything else on the web opens in
    /// the browser, which reaches it without the Host. What loads here is
    /// the request the page made, so a form keeps its method and its data.
    private func place(_ request: URLRequest) {
        guard let url = request.url else { return }
        if let target = PortPreviewTarget(link: url) {
            var request = request
            request.url = target.url
            load(target, as: request)
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            openExternally(url)
        }
    }

    private func policy(for action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        let isWeb = scheme == "http" || scheme == "https"
        guard let frame = action.targetFrame else {
            // A new window: `createWebViewWith` places it.
            return isWeb ? .allow : .cancel
        }
        // A frame inside the page loads what the page asks for.
        guard frame.isMainFrame else { return .allow }
        guard isWeb else {
            return ["about", "blob", "data"].contains(scheme) ? .allow : .cancel
        }
        guard let target = PortPreviewTarget(link: url), !target.isRewritten else {
            // After this decision returns: a load started inside it would
            // be the navigation being cancelled.
            let request = action.request
            Task { @MainActor in self.place(request) }
            return .cancel
        }
        // A link or a redirect to a port no page was opened on yet.
        guard await carries(target.port) else {
            current = target
            phase = .failed(.portTaken(port: target.port))
            return .cancel
        }
        return .allow
    }

    private func fail(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        // "Frame load interrupted": a navigation this page's policy cancelled.
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL, let failed = PortPreviewTarget(link: url) {
            current = failed
        }
        switch recentFailure(current.port) {
        case .refused(let port): phase = .failed(.refused(port: port))
        case .forwardingDenied: phase = .failed(.forwardingDenied)
        case .unreachable(let detail): phase = .failed(.unreachable(detail: detail))
        case nil: phase = .failed(.other(message: error.localizedDescription))
        }
    }
}

extension PortPreviewPage: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if swapsContentMode {
            preferences.preferredContentMode = UIDevice.current.userInterfaceIdiom == .pad ? .mobile : .desktop
        } else {
            preferences.preferredContentMode = .recommended
        }
        return (await policy(for: navigationAction), preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        phase = .loading
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        phase = .loading
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        phase = .loaded
        sync()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }

    /// A development server's certificate for `localhost` is its own, or
    /// from an authority only that machine trusts. It is accepted here
    /// because of how the page arrived: through the Host's SSH connection,
    /// whose key this device already checked, to the Host's own loopback
    /// interface. Every other name keeps the system's judgment.
    func webView(
        _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host.lowercased() == "localhost", let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

extension PortPreviewPage: WKUIDelegate {
    /// A link or script that asks for a new window gets this one, or the
    /// browser: a preview shows one page.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        place(navigationAction.request)
        return nil
    }
}

/// The page's web view in SwiftUI. The page owns it, so a redraw of the
/// sheet never makes another.
struct PortPreviewWebView: UIViewRepresentable {
    let page: PortPreviewPage

    func makeUIView(context: Context) -> WKWebView {
        page.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
