import Foundation
import HeelerSSH

@testable import Heeler

/// A Rex Host's SSH connection, scripted for `RexSSHTransport`: what the Rex
/// probe and the socket check print, whether SSH opens each channel to the
/// socket, with the fake server behind it when it does, and the files and
/// processes Chat reads.
final actor ScriptedRexHost: RexHostConnection {
    typealias ProcessRead = @Sendable (HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts]

    enum Channel: Sendable {
        /// SSH opens it to this server. With a welcome, the server answers the
        /// upgrade and the hello by itself; without one, the test drives it.
        case server(FakeRexServer, welcome: FakeRexServer.Welcome? = FakeRexServer.Welcome())
        /// SSH opens it to this data endpoint, which serves it as Rex would.
        case endpoint(FakeRexDataEndpoint)
        /// SSH refuses it, as libssh2 reports any refused socket.
        case refused
        case fails(TransportError)
        /// It opens and ends at once, as Rex's stdio bridge on Windows does
        /// when no server listens.
        case endsAtOnce
    }

    nonisolated let routeID: UUID? = nil
    private let platform: HostPlatform
    /// What the Rex probe prints between its markers; nil makes it exit 1.
    private let probe: [String]?
    /// The socket check's one line, such as `listening`; nil prints none.
    private let socketCheck: String?
    private var controlChannels: [Channel]
    private var dataChannels: [Channel]
    /// Where data channels take their attach slots, as `HeelerSSHTransport`'s do.
    nonisolated let admission: SSHChannelAdmission?
    private(set) var isConnected = true
    /// What was asked of the connection, in order.
    private(set) var log: [String] = []
    /// Every server a channel opened to, in order.
    private(set) var servers: [FakeRexServer] = []
    /// Closing closes every channel opened on the connection, as SSH does,
    /// so nothing written on one afterwards reaches its server.
    private let closingClosesChannels: Bool
    private var opened: [any HeelerSSHAPIChannel] = []
    /// The Host's files, and its process table, for Chat's reads; without
    /// them a read fails.
    private let files: VirtualHostFiles?
    private let processes: ProcessRead?

    init(
        probe: [String]? = nil, socketCheck: String? = nil, control: [Channel] = [], data: [Channel] = [],
        admission: SSHChannelAdmission? = nil, platform: HostPlatform = .posix, closingClosesChannels: Bool = false,
        files: VirtualHostFiles? = nil, processes: ProcessRead? = nil
    ) {
        self.probe = probe
        self.socketCheck = socketCheck
        controlChannels = control
        dataChannels = data
        self.admission = admission
        self.platform = platform
        self.closingClosesChannels = closingClosesChannels
        self.files = files
        self.processes = processes
    }

    /// Serves `endpoint` for every data channel from now on.
    func serveData(from endpoint: FakeRexDataEndpoint, count: Int = 64) {
        dataChannels += Array(repeating: .endpoint(endpoint), count: count)
    }

    /// What a Rex probe prints for one socket this account owns and may use.
    static func probeFinding(_ path: String, kernel: String = "Darwin") -> [String] {
        ["kernel \(kernel)", "socket 1 1 \(path)", "installed"]
    }

    func corePlatform() async throws -> HostPlatform {
        platform
    }

    func runServerKindDetection(_ script: Data) async throws -> GitExecResult {
        log.append("probe")
        let body = String(decoding: script, as: UTF8.self)
        guard let probe, let nonce = Self.nonce(in: body, before: " rex begin'") else {
            return GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 1)
        }
        let printed = (["", "\(nonce) rex begin"] + probe + ["", "\(nonce) rex end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(printed.utf8), stderr: Data(), exitStatus: 0)
    }

    /// Only the Rex probe's PowerShell, which prints `probe` as a Windows Host would.
    func runWindowsCommand(_ command: String, for purpose: WindowsHostExec) async throws -> GitExecResult {
        log.append("windows")
        guard let probe, let body = try? HerdrCoreWindowsLocatorTests.decoded(command),
            let nonce = Self.nonce(in: body, before: " rex begin'")
        else { throw TransportError.hostFeatureUnavailable(feature: "Windows commands") }
        let printed = (["", "\(nonce) rex begin"] + probe + ["", "\(nonce) rex end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(printed.utf8), stderr: Data(), exitStatus: 0)
    }

    func openRexControlExec(command: String) async throws -> any HeelerSSHAPIChannel {
        log.append("control exec \(command)")
        return try await serve(try next(from: &controlChannels), at: command)
    }

    func openRexDataExec(command: String) async throws -> any HeelerSSHAPIChannel {
        log.append("data exec \(command)")
        guard isConnected else { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
        return try await serve(try next(from: &dataChannels), at: command)
    }

    func openRexControlChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("control \(socketPath)")
        return try await serve(try next(from: &controlChannels), at: socketPath)
    }

    func openRexDataChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("data \(socketPath)")
        // As `HeelerSSHTransport` refuses once its connection is closed.
        guard isConnected else { throw TransportError.sshUnreachable(detail: "The SSH connection is closed.") }
        let channel = try next(from: &dataChannels)
        guard let admission else { return try await serve(channel, at: socketPath) }
        return try await admission.admitAttachLink { try await self.serve(channel, at: socketPath) }
    }

    func runRexSocketCheck(_ script: Data) async throws -> GitExecResult {
        log.append("check")
        let body = String(decoding: script, as: UTF8.self)
        guard let nonce = Self.nonce(in: body, before: " rex-socket begin'") else {
            return GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 1)
        }
        let lines = ["", "\(nonce) rex-socket begin"] + (socketCheck.map { [$0] } ?? []) + ["", "\(nonce) rex-socket end"]
        return GitExecResult(stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: Data(), exitStatus: 0)
    }

    // MARK: Chat's reads, each logged by what it names

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        log.append("session read \(range.path)")
        return try await scriptedFiles().readRange(range)
    }

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        log.append("read \(range.path)")
        return try await scriptedFiles().readRange(range)
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        log.append("status \(path)")
        return try await scriptedFiles().fileStatus(atPath: path)
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        log.append("list \(request.directory)")
        return try await scriptedFiles().listFiles(request)
    }

    func hostHomeDirectory() async throws -> String {
        log.append("home")
        return try await scriptedFiles().home()
    }

    /// New Terminal's home directory, which the Host's files name.
    func remoteHomeDirectory() async throws -> String {
        log.append("browse home")
        return try await scriptedFiles().home()
    }

    /// Browse Directory's listing: the Host's directories under `path`.
    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        log.append("browse \(path)")
        let listing = try await scriptedFiles().listFiles(
            RemoteFileListingRequest(directory: path, kinds: [.directory]))
        let directories = (listing?.entries ?? []).map(\.name)
        return RemoteDirectoryListing(directories: directories, truncated: false)
    }

    func readProcesses(_ request: HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts] {
        log.append("processes \(request.pids.joined(separator: ","))")
        guard let processes else { throw TransportError.hostFeatureUnavailable(feature: "unscripted processes") }
        // One exec, under an ordinary session slot as `HeelerSSHTransport`'s are.
        guard let admission else { return try await processes(request) }
        return try await admission.withChannel(.ordinarySession) { try await processes(request) }
    }

    private func scriptedFiles() throws -> VirtualHostFiles {
        guard let files else { throw TransportError.hostFeatureUnavailable(feature: "unscripted files") }
        return files
    }

    // MARK: Staging, each logged by the name it lands as

    /// Every file staged, oldest first, where it landed and what it holds.
    private(set) var stagedFiles: [(path: String, contents: Data)] = []
    /// Every copy of Heeler's extension placed, oldest first: its folder and what it holds.
    private(set) var placedExtensions: [(folder: String, contents: Data)] = []
    private var stagingFailures: [AttachmentStagingError] = []
    private var holdsStages = false
    /// Stagings inside their slot, held or not.
    private(set) var stagesEntered = 0

    /// The next stagings fail with these, in order, before any byte lands.
    func failStages(with failures: [AttachmentStagingError]) {
        stagingFailures = failures
    }

    /// Holds each staging inside its slot, before any byte lands, until let go.
    /// A held one that is cancelled ends as cancelled, as `HeelerSSHTransport`'s does.
    func holdStages(_ holds: Bool) {
        holdsStages = holds
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        try StagedImage(
            path: try await stage(image.fileURL, named: "image.\(image.format.fileExtension)", progress: progress))
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        try StagedFile(path: try await stage(file.fileURL, named: file.remoteFilename, progress: progress))
    }

    func placeHeelersExtension(_ contents: Data, inFolder folder: String) async throws {
        log.append("place extension \(folder)")
        guard isConnected else { throw TransportError.sshUnreachable(detail: "closed") }
        placedExtensions.append((folder, contents))
    }

    /// One staging, under an ordinary session slot as `HeelerSSHTransport`'s is.
    private func stage(
        _ source: URL, named name: String, progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> String {
        log.append("stage \(name)")
        guard let admission else { return try await write(source, named: name, progress: progress) }
        return try await admission.withChannel(.ordinarySession) {
            try await self.write(source, named: name, progress: progress)
        }
    }

    private func write(
        _ source: URL, named name: String, progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> String {
        stagesEntered += 1
        do {
            while holdsStages { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            throw AttachmentStagingError.cancelled
        }
        if !stagingFailures.isEmpty { throw stagingFailures.removeFirst() }
        let contents = try Data(contentsOf: source)
        await progress(AttachmentStageProgress(transferredBytes: 0, totalBytes: Int64(contents.count)))
        let path = "/tmp/heeler.lab\(stagedFiles.count)/stage-\(stagedFiles.count)/\(name)"
        stagedFiles.append((path, contents))
        await progress(AttachmentStageProgress(transferredBytes: Int64(contents.count), totalBytes: Int64(contents.count)))
        return path
    }

    func close() async throws {
        log.append("close")
        isConnected = false
        guard closingClosesChannels else { return }
        for channel in opened { try? await channel.close(timeout: .zero) }
    }

    private func next(from queue: inout [Channel]) throws -> Channel {
        guard !queue.isEmpty else { throw TransportError.channelFailed(detail: "No channel scripted") }
        return queue.removeFirst()
    }

    private func serve(_ channel: Channel, at socketPath: String) async throws -> any HeelerSSHAPIChannel {
        switch channel {
        case .server(let server, let welcome):
            servers.append(server)
            if let welcome { Task { await server.handshake(welcome) } }
            opened.append(server.channel)
            return server.channel
        case .endpoint(let endpoint):
            let channel = await endpoint.connect()
            opened.append(channel)
            return channel
        case .refused:
            throw TransportError.streamLocalOpenFailed(path: socketPath)
        case .endsAtOnce:
            return EndedChannel()
        case .fails(let error):
            throw error
        }
    }

    /// The nonce a script's begin marker carries.
    private static func nonce(in script: String, before marker: String) -> String? {
        guard let marker = script.range(of: marker) else { return nil }
        let head = script[..<marker.lowerBound]
        guard let quote = head.lastIndex(of: "'") else { return nil }
        return String(head[head.index(after: quote)...])
    }
}

/// A channel that ends before anything arrives.
private struct EndedChannel: HeelerSSHAPIChannel {
    func write(_ data: Data, timeout: Duration) async throws {}
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? { nil }
    func close(timeout: Duration) async throws {}
}
