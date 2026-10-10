import CTailscale
import Darwin
import Foundation

/// One tsnet node (libtailscale) per configured tailnet, running Tailscale's
/// userspace network stack in-process. Each node keeps its own state
/// directory, so separate tailnets stay separate.
///
/// Every libtailscale call runs on a dedicated thread: `tailscale_dial`
/// blocks until the peer answers and cannot be cancelled, and even status
/// reads go through tsnet's LocalAPI.
actor TailscaleNode: OverlayNode {
    nonisolated let kind = OverlayKind.tailscale
    private let configuration: TailscaleConfiguration
    private let native: any TailscaleNative

    /// The libtailscale server handle, once created.
    private var handle: Int32?
    private var lastStatus: OverlayNodeStatus = .stopped
    private var startGeneration = 0
    /// Starts in progress; a cancelled one closes the server only when it
    /// was the last.
    private var startWaiters = 0
    /// Whether the current server has been online, so it may carry streams.
    private var cameOnline = false
    /// When the current server first came online.
    private var onlineSince: ContinuousClock.Instant?
    private var creation: Task<Result<Int32, OverlayError>, Never>?
    /// The last server creation or close. Each new one waits for it, so
    /// two tsnet servers never run on the same state directory: a start
    /// that follows a stop only creates its server once the old one closed.
    private var lifecycleTail: Task<Void, Never>?

    private static let statusPollInterval: Duration = .milliseconds(250)
    /// How long after coming online the network map may still lack peers.
    private let networkMapSettle: Duration

    init(
        configuration: TailscaleConfiguration,
        native: any TailscaleNative = LiveTailscaleNative(),
        networkMapSettle: Duration = .seconds(5)
    ) {
        self.configuration = configuration
        self.native = native
        self.networkMapSettle = networkMapSettle
    }

    func start(timeout: Duration) async throws {
        startWaiters += 1
        do {
            try await startUntilOnline(timeout: timeout)
            startWaiters -= 1
        } catch {
            startWaiters -= 1
            guard Task.isCancelled else { throw error }
            abandonStartIfUnused()
            throw OverlayError.cancelled
        }
    }

    /// A caller gave up on a start (Cancel while connecting). When nobody
    /// else is waiting for it and the server never came online, close it —
    /// queued behind its creation like any close — so a cancelled Connect
    /// leaves no half-started tsnet server running. Not awaited: the caller
    /// returns at once, and the next start's creation waits for the close.
    private func abandonStartIfUnused() {
        guard startWaiters == 0, !cameOnline else { return }
        _ = beginStop()
    }

    private func startUntilOnline(timeout: Duration) async throws {
        let deadline = OverlayDeadline(after: timeout)
        let generation = startGeneration
        let handle = try await ensureHandle()
        guard !Task.isCancelled else { throw OverlayError.cancelled }

        while true {
            if let status = await readStatus(handle) {
                guard generation == startGeneration, self.handle == handle else {
                    throw OverlayError.cancelled
                }
                switch status.progress {
                case .online(let addresses):
                    lastStatus = .online(addresses: addresses)
                    cameOnline = true
                    if onlineSince == nil { onlineSince = .now }
                    return
                case .needsLogin(let url):
                    lastStatus = .needsLogin(url)
                    throw OverlayError.loginRequired(url)
                case .failed(let message):
                    lastStatus = status.nodeStatus
                    throw OverlayError.startFailed(message)
                case .waiting:
                    lastStatus = .starting
                }
            }
            try await deadline.pause(Self.statusPollInterval)
            guard generation == startGeneration, self.handle == handle else {
                throw OverlayError.cancelled
            }
        }
    }

    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        let trimmedHost = OverlayAddress.unbracketed(host)
        guard !trimmedHost.isEmpty, port != 0 else {
            throw OverlayError.invalidConfiguration("A Tailscale dial needs a host and a port.")
        }
        let deadline = OverlayDeadline(after: timeout)
        try await start(timeout: deadline.remaining)
        guard let handle else { throw OverlayError.cancelled }
        // Names (MagicDNS) are left to tsnet.
        if let ip = OverlayAddress.ipLiteral(trimmedHost) {
            try await refuseUnroutable(ip, handle: handle, deadline: deadline)
        }
        guard self.handle == handle else { throw OverlayError.cancelled }

        let address = OverlayAddress.hostPort(host: trimmedHost, port: port)
        let native = native
        let result = try await BlockingCall.run(
            name: "tailscale.dial",
            timeout: deadline.remaining,
            abandon: { result in
                // The dial outlived its caller: nobody owns this descriptor.
                if case .success(let descriptor) = result { Darwin.close(descriptor) }
            }
        ) { () -> Result<Int32, OverlayError> in
            native.dial(handle, address: address)
        }
        let descriptor = try result.get()
        // libtailscale pumps the other socketpair end itself and stops when
        // this end closes, so there is nothing more to release.
        return OverlayDialedStream(descriptor: descriptor, release: {})
    }

    /// tsnet does not refuse an address no peer owns: the dial would hang
    /// until its deadline. This fails it at once when the network map routes
    /// nothing there (no peer address, subnet route, or exit node). tsnet
    /// reports Running before the network map lists every peer, so within
    /// `networkMapSettle` of coming online an unroutable address is checked
    /// again until it routes or that window ends. An unreadable status, or
    /// one without a network map, leaves the dial to tsnet.
    private func refuseUnroutable(_ ip: String, handle: Int32, deadline: OverlayDeadline) async throws {
        while let status = await readStatus(handle), self.handle == handle, status.canRoute(to: ip) == false {
            guard let onlineSince, ContinuousClock.now - onlineSince < networkMapSettle else {
                throw OverlayError.dialFailed("\(ip) is not on this tailnet.")
            }
            try await deadline.pause(Self.statusPollInterval)
        }
    }

    func status() async -> OverlayNodeStatus {
        guard let handle else { return lastStatus }
        if let status = await readStatus(handle), self.handle == handle {
            lastStatus = status.nodeStatus
        }
        return lastStatus
    }

    func stop() async {
        await beginStop()?.value
    }

    /// Detaches the server (or the one being created) and queues its close;
    /// the returned task finishes once it is closed. nil when none exists.
    private func beginStop() -> Task<Void, Never>? {
        startGeneration += 1
        lastStatus = .stopped
        cameOnline = false
        onlineSince = nil
        let native = native
        let closing: Task<Void, Never>
        if let handle {
            self.handle = nil
            // Closing the server also fails any dial still blocked inside it.
            closing = enqueueLifecycle {
                await BlockingCall.run(name: "tailscale.close") { native.close(handle) }
            }
        } else if let creation {
            // The server being created belongs to no one now; close it as
            // soon as it exists. Its waiters see the new generation.
            closing = enqueueLifecycle {
                if case .success(let handle) = await creation.value {
                    await BlockingCall.run(name: "tailscale.close") { native.close(handle) }
                }
            }
        } else {
            return nil
        }
        creation = nil
        return closing
    }

    /// The running node's view of itself and its peers; empty while no
    /// server exists. Never creates one.
    func details() async -> OverlayNodeDetails {
        guard let handle else { return OverlayNodeDetails() }
        guard let status = await readStatus(handle), self.handle == handle else {
            return OverlayNodeDetails()
        }
        return status.details
    }

    /// Stops the node, then signs it out: a server is started on the state
    /// directory without the auth key, LocalAPI's logout tells the
    /// coordination server and drops the node key, the server closes, and
    /// the state directory is emptied (the directory itself, with its
    /// protection, stays). A directory without tsnet state was never logged
    /// in and is only emptied, offline.
    ///
    /// When the coordination server cannot be told, this throws and leaves
    /// the directory as tsnet left it. That state is already marked logged
    /// out (LocalBackend.Logout saves `LoggedOut` before contacting the
    /// server) yet still holds the node key, and a retry is not guaranteed
    /// to reach the server again. Deleting it (as the app does) forgets the
    /// key locally; the node then stays listed until a tailnet admin removes
    /// it or its key expires.
    func logout(timeout: Duration) async throws {
        await stop()
        let configuration = configuration
        let native = native
        let milliseconds = Int32(clamping: max(1, timeout.milliseconds))
        // Queued like a creation, so no other server runs on the directory.
        let result = await enqueueLifecycle {
            await BlockingCall.run(name: "tailscale.logout") {
                native.logout(configuration, timeoutMilliseconds: milliseconds)
            }
        }.value
        try result.get()
    }

    /// Runs `operation` after every earlier creation or close has finished.
    private func enqueueLifecycle<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) -> Task<Value, Never> {
        let previous = lifecycleTail
        let task = Task.detached {
            await previous?.value
            return await operation()
        }
        lifecycleTail = Task.detached { _ = await task.value }
        return task
    }

    // MARK: - Native

    /// Creates and starts the libtailscale server once; concurrent callers
    /// share the same creation. Creation is prompt (tsnet starts its backend
    /// in the background), so it is not raced against the caller's deadline.
    private func ensureHandle() async throws -> Int32 {
        if let handle { return handle }
        let generation = startGeneration
        let creation: Task<Result<Int32, OverlayError>, Never>
        if let existing = self.creation {
            creation = existing
        } else {
            try validateConfiguration()
            lastStatus = .starting
            let configuration = configuration
            let native = native
            creation = enqueueLifecycle {
                await BlockingCall.run(name: "tailscale.start") {
                    native.createAndStart(configuration)
                }
            }
            self.creation = creation
        }

        let created = await creation.value
        if self.creation == creation { self.creation = nil }
        switch created {
        case .success(let newHandle):
            if let handle, handle == newHandle { return handle }
            guard generation == startGeneration, self.handle == nil else {
                // Stopped while the server was being created; `stop`
                // queued its close.
                throw OverlayError.cancelled
            }
            handle = newHandle
            return newHandle
        case .failure(let error):
            if case .startFailed(let message) = error { lastStatus = .failed(message) }
            throw error
        }
    }

    private func validateConfiguration() throws {
        guard configuration.stateDirectory.isFileURL else {
            throw OverlayError.invalidConfiguration("The Tailscale state directory must be a local path.")
        }
        let hostname = configuration.hostname.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty else {
            throw OverlayError.invalidConfiguration("A Tailscale machine name is required.")
        }
        if let controlURL = configuration.controlURL,
           !["https", "http"].contains(controlURL.scheme?.lowercased() ?? "") {
            throw OverlayError.invalidConfiguration("The coordination server must be an http(s) URL.")
        }
    }

    /// Status reads are frequent while starting; one serial queue per node
    /// keeps them off the cooperative pool without a thread per read.
    private let statusQueue = DispatchQueue(
        label: "dev.bybee.heeler.overlay.tailscale.status", qos: .utility)

    private func readStatus(_ handle: Int32) async -> TailscaleStatus? {
        let native = native
        return await BlockingCall.run(on: statusQueue) { () -> TailscaleStatus? in
            native.status(handle)
        }
    }
}

/// The libtailscale calls a `TailscaleNode` makes, all blocking; a seam so
/// the node's lifecycle can be tested without tsnet.
protocol TailscaleNative: Sendable {
    func createAndStart(_ configuration: TailscaleConfiguration) -> Result<Int32, OverlayError>
    func close(_ handle: Int32)
    func status(_ handle: Int32) -> TailscaleStatus?
    func dial(_ handle: Int32, address: String) -> Result<Int32, OverlayError>
    /// Signs the node on `configuration`'s state directory out and empties
    /// that directory; no other server may be running on it.
    func logout(_ configuration: TailscaleConfiguration, timeoutMilliseconds: Int32) -> Result<Void, OverlayError>
}

struct LiveTailscaleNative: TailscaleNative {
    /// Opts the process out of Tailscale's log upload before the first node
    /// exists. This must happen inside the Go runtime: Go copies the
    /// environment at startup, so setenv(3) from here would never reach
    /// tsnet, and tsnet's uploader only stops through logtail.Disable.
    private static let disableLogUpload: Void = {
        heeler_tailscale_disable_log_upload()
    }()

    /// Log upload as the Go side sees it, after opting out.
    static var logUploadDisabled: Bool { logUploadState == 3 }

    /// `heeler_tailscale_log_upload_state`: bit 0 envknob, bit 1 logtail.
    static var logUploadState: Int32 {
        _ = disableLogUpload
        return heeler_tailscale_log_upload_state()
    }

    func createAndStart(_ configuration: TailscaleConfiguration) -> Result<Int32, OverlayError> {
        _ = Self.disableLogUpload

        let directory = configuration.stateDirectory
        do {
            try Self.prepareStateDirectory(directory)
        } catch {
            return .failure(.startFailed("Could not create the Tailscale state directory."))
        }

        let handle = tailscale_new()
        guard handle >= 0 else {
            return .failure(.startFailed("Could not create a Tailscale node."))
        }
        func fail(_ status: Int32, _ action: String) -> Result<Int32, OverlayError> {
            let message = Self.errorMessage(handle, status: status)
            _ = tailscale_close(handle)
            return .failure(.startFailed("\(action): \(message)"))
        }

        var status = tailscale_set_dir(handle, directory.path)
        guard status == 0 else { return fail(status, "Could not use the state directory") }
        status = tailscale_set_hostname(handle, configuration.hostname.trimmingCharacters(in: .whitespaces))
        guard status == 0 else { return fail(status, "Could not set the machine name") }
        if let authKey = configuration.authKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authKey.isEmpty {
            status = tailscale_set_authkey(handle, authKey)
            guard status == 0 else { return fail(status, "Could not set the auth key") }
        }
        if let controlURL = configuration.controlURL {
            status = tailscale_set_control_url(handle, controlURL.absoluteString)
            guard status == 0 else { return fail(status, "Could not set the coordination server") }
        }
        // -1 discards tsnet's own log lines.
        status = tailscale_set_logfd(handle, -1)
        guard status == 0 else { return fail(status, "Could not configure logging") }
        status = tailscale_start(handle)
        guard status == 0 else { return fail(status, "Tailscale did not start") }
        return .success(handle)
    }

    func close(_ handle: Int32) {
        _ = tailscale_close(handle)
    }

    func status(_ handle: Int32) -> TailscaleStatus? {
        var json: UnsafeMutablePointer<CChar>?
        let status = tailscale_status_json(handle, &json)
        defer { free(json) }
        guard status == 0, let json else { return nil }
        let data = Data(bytes: json, count: strlen(json))
        return try? TailscaleStatus.decode(data)
    }

    func dial(_ handle: Int32, address: String) -> Result<Int32, OverlayError> {
        var connection: Int32 = -1
        let status = tailscale_dial(handle, "tcp", address, &connection)
        guard status == 0, connection >= 0 else {
            if connection >= 0 { Darwin.close(connection) }
            return .failure(.dialFailed(Self.errorMessage(handle, status: status)))
        }
        return .success(connection)
    }

    func logout(_ configuration: TailscaleConfiguration, timeoutMilliseconds: Int32) -> Result<Void, OverlayError> {
        let directory = configuration.stateDirectory
        guard directory.isFileURL else {
            return .failure(.invalidConfiguration("The Tailscale state directory must be a local path."))
        }
        if Self.hasLoginState(directory) {
            // No auth key: logging out must never register a new node.
            var loggingOut = configuration
            loggingOut.authKey = nil
            let handle: Int32
            switch createAndStart(loggingOut) {
            case .success(let created): handle = created
            case .failure(let error): return .failure(error)
            }
            let status = heeler_tailscale_logout(handle, timeoutMilliseconds)
            let message = status == 0 ? "" : Self.errorMessage(handle, status: status)
            _ = tailscale_close(handle)
            guard status == 0 else {
                if message.contains("deadline exceeded") { return .failure(.timedOut) }
                return .failure(.startFailed("Could not sign out of Tailscale: \(message)"))
            }
        }
        do {
            try Self.emptyStateDirectory(directory)
        } catch {
            return .failure(.startFailed("Could not remove the Tailscale state."))
        }
        return .success(())
    }

    /// Whether tsnet ever wrote its state (keys and login) here.
    static func hasLoginState(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("tailscaled.state").path)
    }

    /// Removes everything inside the state directory but keeps the directory,
    /// with its permissions, protection class, and backup exclusion.
    static func emptyStateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        for name in try manager.contentsOfDirectory(atPath: directory.path) {
            try manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Creates the state directory, or tightens an existing one: owner-only
    /// permissions, readable after first unlock (a node may start from a
    /// background reconnect), and excluded from backups, since it holds the
    /// node's private keys.
    static func prepareStateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: attributes)
        try manager.setAttributes(attributes, ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try mutable.setResourceValues(values)
    }

    private static func errorMessage(_ handle: Int32, status: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return tailscale_errmsg(handle, base, pointer.count)
        }
        if result == 0 || result == ERANGE {
            let message = buffer.withUnsafeBufferPointer { pointer -> String in
                guard let base = pointer.baseAddress else { return "" }
                return String(cString: base)
            }
            if !message.isEmpty { return message }
        }
        if status > 0, let description = strerror(status) {
            return String(cString: description)
        }
        return "libtailscale error \(status)"
    }
}
