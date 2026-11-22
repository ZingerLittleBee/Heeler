import Foundation

/// One open port preview: the sheet over a detail that shows a Host's
/// `localhost` pages. It owns what the pages travel on, an SSH connection of
/// its own and the proxy that feeds it, from the moment the sheet opens until
/// it closes (ADR 0062).
@MainActor @Observable
final class PortPreviewSession: Identifiable {
    enum Proxy: Equatable {
        case starting
        case ready(PortPreviewProxy.Access)
        /// This device could not listen on its own loopback interface.
        case failed(String)
    }

    let hostName: String
    /// Where the Agent or terminal this preview opened from works, for the
    /// ports its own programs most likely hold.
    let directory: String?
    /// The page the sheet shows; nil while it shows only Ports.
    private(set) var target: PortPreviewTarget?
    private(set) var proxy = Proxy.starting
    /// The SSH connection under the pages ended and has not come back.
    private(set) var isLinkLost = false
    /// Counts the times the connection came back, for the page to reload on.
    private(set) var recoveries = 0
    let ports: HostPortsList

    @ObservationIgnored private let link: PortPreviewLink
    @ObservationIgnored private var listener: PortPreviewProxy?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    init(link: PortPreviewLink, hostName: String, directory: String?, target: PortPreviewTarget?) {
        self.link = link
        self.hostName = hostName
        self.directory = directory
        self.target = target
        ports = HostPortsList(link: link, directory: directory)
    }

    /// Starts the proxy. The SSH connection waits for the first page or the
    /// first look at Ports.
    func start() async {
        guard listener == nil, !isClosed else { return }
        do {
            let started = try await PortPreviewProxy.start(link: link) { [weak self] in
                Task { @MainActor in self?.linkLost() }
            }
            guard !isClosed else {
                started.stop()
                return
            }
            listener = started
            proxy = .ready(started.access)
        } catch {
            proxy = .failed(error.localizedDescription)
        }
    }

    func open(_ target: PortPreviewTarget) {
        self.target = target
    }

    /// Why the latest connection to `port` failed, when it just did.
    func recentFailure(port: Int) -> PortPreviewFailure? {
        listener?.recentFailure(port: port)
    }

    /// The Console's connection to the Host went away or came back. It is
    /// not the preview's connection, but it takes the same road: losing it is
    /// a reason to check this one, and its return the moment to try again.
    func hostConnectionChanged(isConnected: Bool) {
        guard !isClosed else { return }
        if isConnected {
            if isLinkLost { recover() }
        } else {
            let link = link
            Task { [weak self] in
                if await !link.stillAnswers() { self?.linkLost() }
            }
        }
    }

    /// The sheet closed: the proxy stops, every page connection ends and the
    /// SSH connection closes.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        recovery?.cancel()
        recovery = nil
        listener?.stop()
        listener = nil
        let link = link
        Task { await link.close() }
    }

    private func linkLost() {
        guard !isClosed, !isLinkLost else { return }
        isLinkLost = true
        recover()
    }

    /// Dials until the Host answers, waiting longer between tries. Only the
    /// wait is cancelled when a newer attempt replaces this one: a dial in
    /// progress runs to its end inside the link.
    private func recover() {
        recovery?.cancel()
        let link = link
        recovery = Task { [weak self] in
            var wait = Duration.seconds(1)
            while !Task.isCancelled {
                if (try? await link.ensureConnected()) != nil {
                    guard !Task.isCancelled else { return }
                    self?.linkReturned()
                    return
                }
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, .seconds(15))
            }
        }
    }

    private func linkReturned() {
        guard !isClosed, isLinkLost else { return }
        isLinkLost = false
        recoveries += 1
        recovery = nil
    }
}

/// What listens on the Host, as Ports lists it: read when the list is first
/// shown and again when asked.
@MainActor @Observable
final class HostPortsList {
    enum Phase: Equatable {
        case idle
        case reading
        case read
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// The ports of programs working in the preview's directory.
    private(set) var nearby: [HostListeningPort] = []
    private(set) var others: [HostListeningPort] = []

    @ObservationIgnored private let link: PortPreviewLink
    @ObservationIgnored private let directory: String?
    @ObservationIgnored private var reading: Task<Void, Never>?

    init(link: PortPreviewLink, directory: String?) {
        self.link = link
        self.directory = directory
    }

    func readIfNeeded() {
        if phase == .idle { read() }
    }

    func read() {
        guard reading == nil else { return }
        if phase != .read { phase = .reading }
        let link = link
        // In a task of its own: a read the Host has yet to answer is not
        // dropped because the list went off screen.
        reading = Task { [weak self] in
            let result: Result<[HostListeningPort], any Error>
            do {
                result = .success(try await link.listeningPorts())
            } catch {
                result = .failure(error)
            }
            self?.finish(result)
        }
    }

    /// A read the caller waits for, as pull to refresh does.
    func refresh() async {
        read()
        await reading?.value
    }

    private func finish(_ result: Result<[HostListeningPort], any Error>) {
        reading = nil
        switch result {
        case .success(let ports):
            nearby = ports.filter { $0.isInside(directory) }
            others = ports.filter { !$0.isInside(directory) }
            phase = .read
        case .failure(let error):
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let failure as PortPreviewFailure:
            switch failure {
            case .unreachable(let detail): detail
            case .refused, .forwardingDenied: String(localized: "The Host did not answer.")
            }
        case let error as TransportError:
            error.presentation.message
        case is HostListeningPorts.MalformedOutput:
            String(localized: "The Host's answer could not be read.")
        default:
            error.localizedDescription
        }
    }
}
