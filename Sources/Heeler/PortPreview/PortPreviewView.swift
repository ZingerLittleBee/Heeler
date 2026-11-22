import SwiftUI
import UIKit

/// The port preview sheet: a page a program serves on the Host's loopback
/// interface, or the list of Ports when it opened without one.
struct PortPreviewView: View {
    let session: PortPreviewSession
    /// The Host's connection is up, as the detail under the sheet sees it.
    let isHostConnected: Bool
    /// Puts a picture of the page in the Agent's message; nil where no
    /// message takes one.
    var sendScreenshot: ((Data) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page: PortPreviewPage?
    @State private var isShowingPorts = false

    var body: some View {
        Group {
            if session.target == nil {
                NavigationStack {
                    PortsListView(session: session, close: { dismiss() }) { session.open($0) }
                }
            } else {
                NavigationStack {
                    pageContent
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { pageToolbar }
                }
                .sheet(isPresented: $isShowingPorts) {
                    NavigationStack {
                        PortsListView(session: session, close: { isShowingPorts = false }) { target in
                            isShowingPorts = false
                            session.open(target)
                        }
                    }
                }
            }
        }
        // A pull at the top of a page would close the sheet, and with it the
        // page and what was typed into it. A page closes by its button.
        .interactiveDismissDisabled(session.target != nil)
        .task { await session.start() }
        .onChange(of: PageRequest(target: session.target, proxy: session.proxy), initial: true) { _, request in
            show(request)
        }
        .onChange(of: isHostConnected) { _, isConnected in
            session.hostConnectionChanged(isConnected: isConnected)
        }
        .onChange(of: session.recoveries) { page?.reload() }
        .onDisappear { page?.close() }
    }

    /// What decides the page on screen: the address asked for, and the proxy
    /// a web view needs before it can be made.
    private struct PageRequest: Equatable {
        let target: PortPreviewTarget?
        let proxy: PortPreviewSession.Proxy
    }

    private func show(_ request: PageRequest) {
        guard let target = request.target, case .ready(let access) = request.proxy else { return }
        if let page {
            page.load(target)
        } else {
            let session = session
            let openURL = openURL
            page = PortPreviewPage(
                target: target, access: access,
                recentFailure: { session.recentFailure(port: $0) },
                openExternally: { openURL($0) })
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if let page {
                PortPreviewWebView(page: page)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .accessibilityIdentifier("port-preview-page")
                if case .failed(let failure) = page.phase {
                    PortPreviewFailureView(
                        failure: failure, hostName: session.hostName,
                        retry: { page.reload() },
                        retrySecurely: page.secureRetry.map { secured in { page.load(secured) } },
                        showPorts: { isShowingPorts = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                } else if session.isLinkLost {
                    // The page as it last loaded, set back while its Host is away.
                    Color(uiColor: .systemBackground).opacity(0.7)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }
            } else if case .failed(let message) = session.proxy {
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let page, page.phase == .loading {
                    ProgressView(value: max(page.progress, 0.05))
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                        .accessibilityLabel("Loading")
                }
                if session.isLinkLost {
                    reconnectingNote
                }
            }
        }
    }

    private var reconnectingNote: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 1) {
                Text("Reconnecting to \(session.hostName)…")
                    .font(.subheadline.weight(.semibold))
                Text("The page reloads when the Host is back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("port-preview-reconnecting")
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Back", systemImage: "chevron.backward") { page?.goBack() }
                .disabled(page?.canGoBack != true)
            Button("Forward", systemImage: "chevron.forward") { page?.goForward() }
                .disabled(page?.canGoForward != true)
        }
        ToolbarItem(placement: .principal) {
            Button {
                isShowingPorts = true
            } label: {
                VStack(spacing: 1) {
                    Text(verbatim: (page?.current ?? session.target)?.address ?? "")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "on \(session.hostName)",
                        comment: "Under a page's address in a port preview: the Host whose localhost the page comes from.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the Host's ports")
            .accessibilityIdentifier("port-preview-address")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            moreMenu
            Button("Close", systemImage: "xmark") { dismiss() }
                .accessibilityIdentifier("port-preview-close")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Reload", systemImage: "arrow.clockwise") { page?.reload() }
            if let sendScreenshot {
                Button("Send Screenshot to Agent", systemImage: "camera.viewfinder") {
                    guard let page else { return }
                    Task {
                        if let picture = await page.snapshot() { sendScreenshot(picture) }
                    }
                }
                .disabled(page?.phase != .loaded)
            }
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.string = (page?.current ?? session.target)?.url.absoluteString
            }
            if let page {
                Button(
                    contentModeTitle(isSwapped: page.swapsContentMode),
                    systemImage: showsDesktopNext(isSwapped: page.swapsContentMode) ? "desktopcomputer" : "iphone"
                ) {
                    page.swapsContentMode.toggle()
                }
            }
            Divider()
            Button("Ports", systemImage: PortPreviewCopy.symbol) { isShowingPorts = true }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("port-preview-more")
    }

    /// An iPad asks pages for their desktop layout to begin with, and an
    /// iPhone for the mobile one.
    private func showsDesktopNext(isSwapped: Bool) -> Bool {
        (UIDevice.current.userInterfaceIdiom == .pad) == isSwapped
    }

    private func contentModeTitle(isSwapped: Bool) -> LocalizedStringKey {
        showsDesktopNext(isSwapped: isSwapped) ? "Request Desktop Website" : "Request Mobile Website"
    }
}

/// Why a page did not load, and what to do about it.
private struct PortPreviewFailureView: View {
    let failure: PortPreviewPage.Failure
    let hostName: String
    let retry: () -> Void
    /// Loads the page over TLS, where that has not been tried.
    let retrySecurely: (() -> Void)?
    let showPorts: () -> Void

    var body: some View {
        ContentUnavailableView {
            switch failure {
            case .refused(let port):
                Label("Nothing Is Listening on Port \(String(port))", systemImage: "network.slash")
            case .forwardingDenied:
                Label("Port Forwarding Is Not Allowed", systemImage: "lock")
            case .unreachable:
                Label("Can't Reach \(hostName)", systemImage: "wifi.slash")
            case .other:
                Label("Can't Open This Page", systemImage: "exclamationmark.triangle")
            }
        } description: {
            switch failure {
            case .refused:
                Text("\(hostName) refused the connection. The server may have stopped, or it may be using another port.")
            case .forwardingDenied:
                VStack(spacing: 14) {
                    Text(
                        "The SSH server on \(hostName) refused to open the connection. Allow forwarding in its sshd_config, restart sshd, then try again.")
                    CommandBlock(command: "AllowTcpForwarding local")
                }
            case .unreachable(let detail):
                Text(detail)
            case .other(let message):
                Text(message)
            }
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("port-preview-retry")
            if let retrySecurely {
                Button("Try HTTPS", action: retrySecurely)
                    .accessibilityIdentifier("port-preview-retry-https")
            }
            switch failure {
            case .refused, .other:
                Button("Show Ports", action: showPorts)
            case .forwardingDenied, .unreachable:
                EmptyView()
            }
        }
        .accessibilityIdentifier("port-preview-failure")
    }
}
