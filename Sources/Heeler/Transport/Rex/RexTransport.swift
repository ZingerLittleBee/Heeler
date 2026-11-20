import Foundation
import HeelerSSH

/// A connected Rex Host (ADR 0049): one SSH connection, and on it a control
/// link to the Rex server's socket. Everything Heeler asks of the server goes
/// over the control link, except terminal data, which takes a data link on a
/// channel of its own to the same socket.
protocol RexTransport: Sendable {
    /// The route that won the dial; nil when there was only ever one way in.
    nonisolated var routeID: UUID? { get }

    /// The socket this transport reached.
    nonisolated var socket: RexSocket { get }

    /// The socket connecting looked up because the Host stored none, for the
    /// Host to keep. Nil when the stored one was used.
    nonisolated var foundSocket: RexSocket? { get }

    /// The kernel the lookup for `foundSocket` printed, as `uname -s` names
    /// it, for the Host to keep. Nil when the stored socket was used.
    nonisolated var foundKernel: String? { get }

    /// Whether the SSH connection is up, whatever became of the server.
    var isConnected: Bool { get async }

    /// The control link: the one opened by connecting, or by the last
    /// `reconnectControl`.
    var control: RexControlLink { get async }

    /// Replaces the control link with a new one on a fresh channel. Resuming,
    /// it drops the old link without a close frame, so the server keeps its
    /// client for a while, and the new hello carries the old link's reconnect
    /// token; the new link's `resumed` says whether the server took the client
    /// back. Otherwise it closes the old link and says a plain hello. Either
    /// way, events sent in between are lost, so inventory needs a fresh read.
    /// Throws `TransportError`.
    func reconnectControl(resuming: Bool) async throws -> RexControlLink

    /// Opens one more channel to the same socket, for a data link, under one
    /// of the connection's attach slots until it closes. Throws `TransportError`.
    func openDataChannel() async throws -> any HeelerSSHAPIChannel

    /// What Chat reads of the Host on this same SSH connection, and nothing
    /// else of it.
    nonisolated var reads: any RexHostReads { get }

    /// The staging of a file or image the user attaches, on this same SSH
    /// connection, and nothing else of it.
    nonisolated var staging: any RexHostStaging { get }

    /// The placing of Heeler's extension for Pi and Oh My Pi, when the user
    /// asks for it from Chat, on this same SSH connection, and nothing else
    /// of it.
    nonisolated var extensionPlacing: any RexHostExtensionPlacing { get }

    /// Closes the control link with a close frame, so the server forgets this
    /// client at once, then the SSH connection and every channel on it.
    func close() async
}

extension RexTransport {
    /// Replaces the control link, resuming its client.
    func reconnectControl() async throws -> RexControlLink {
        try await reconnectControl(resuming: true)
    }
}

/// What Chat may read of a Rex Host over its SSH connection, as it reads a
/// tmux Host's (ADR 0034): a file's status, a directory's listing, a range of
/// a file, the home directory, and the facts of a terminal's processes. None
/// of it writes, and no write, other exec or channel is reachable from it.
///
/// Every read takes one of the connection's ordinary session slots, as on any
/// Host: a held SFTP channel for files, one exec for the home directory per
/// connection, and one bounded exec for each process read (12 s, with an
/// 8 s watchdog on the Host). The control link holds the events slot and
/// each data link an attach slot, which reads never take, so a slow read
/// waits on other reads and on stagings (`RexHostStaging`) only. Rex's links
/// are direct-streamlocal channels, which sshd's `MaxSessions` does not
/// count (rex-compatibility.md).
protocol RexHostReads: Sendable {
    /// A range of a session file, on the SFTP channel Chat keeps open.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice
    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice
    func fileStatus(atPath path: String) async throws -> RemoteFileStatus?
    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing?
    func hostHomeDirectory() async throws -> String
    /// One bounded exec of `HostProcessReader`'s script.
    func readProcesses(_ request: HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts]
}

/// One of the two writes Heeler makes on a Rex Host (ADR 0056): a file or
/// image the user attaches to a message, staged as on every other Server Kind
/// (ADRs 0005 and 0006). One exec makes a private directory under the
/// account's temporary directory, and one SFTP channel writes the file into
/// it as a part file it renames, with progress, cancellation and the removal
/// of a part file left by a failed transfer. Nothing else is reachable from
/// it: no read of the Host's files, no other exec, and no path but the ones
/// it makes.
///
/// The exec and then the SFTP channel each take one of the connection's
/// ordinary session slots, one at a time, at normal priority, so Chat's file
/// and process reads, which ask at interactive priority, take the next free
/// slot ahead of a waiting staging, and a slow upload holds one slot of four
/// while its bytes go. The control link's events slot and the data links' attach
/// slots are never asked for, so no staging holds up inventory, events,
/// typing or an open terminal.
protocol RexHostStaging: Sendable {
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile
}

/// The other write Heeler makes on a Rex Host, and only when the user asks for
/// it from a Pi or Oh My Pi Agent's Chat (ADR 0056): Heeler's own extension,
/// the one file a Host Helper brings on other Server Kinds (ADR 0033), into
/// the folder that Agent loads its extensions from. Over SFTP it makes that
/// one folder when the Agent's directory has none, then writes the file as a
/// 0600 temporary file it renames into place. Nothing else is reachable from
/// it: no other file name, no exec, and no read of the Host's files.
protocol RexHostExtensionPlacing: Sendable {
    /// `folder` is an `extensions` folder by its absolute path; any other is
    /// refused before anything is written.
    func placeHeelersExtension(_ contents: Data, inFolder folder: String) async throws
}

/// What a Rex Host uses of its SSH connection. `HeelerSSHTransport` is the
/// production one; tests script one.
protocol RexHostConnection: ServerKindDetectionConnection, RexHostReads, RexHostStaging, RexHostExtensionPlacing {
    nonisolated var routeID: UUID? { get }

    var isConnected: Bool { get async }

    /// A channel to the socket under the connection's one events slot, for
    /// the control link. SSH refusing it throws `.streamLocalOpenFailed`.
    func openRexControlChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel

    /// A channel to the socket under an attach slot, for a data link. SSH
    /// refusing it throws `.streamLocalOpenFailed`.
    func openRexDataChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel

    /// Runs a `RexSocketCheck` script in one bounded exec.
    func runRexSocketCheck(_ script: Data) async throws -> GitExecResult
}

/// A Rex Host over SSH: direct-streamlocal channels to the server's socket.
/// It never runs `rex`, and connecting starts no server.
actor RexSSHTransport: RexTransport {
    nonisolated let routeID: UUID?
    nonisolated let socket: RexSocket
    nonisolated let foundSocket: RexSocket?
    nonisolated let foundKernel: String?
    private nonisolated let connection: any RexHostConnection
    private let options: RexControlLink.Options
    private let sleep: RexControlLink.Sleep
    private let nonce: @Sendable () -> String
    private(set) var control: RexControlLink
    private var reconnecting: Task<RexControlLink, any Error>?

    private init(
        connection: any RexHostConnection, socket: RexSocket, found: (socket: RexSocket, kernel: String?)?,
        control: RexControlLink, options: RexControlLink.Options, sleep: @escaping RexControlLink.Sleep,
        nonce: @escaping @Sendable () -> String
    ) {
        routeID = connection.routeID
        self.connection = connection
        self.socket = socket
        foundSocket = found?.socket
        foundKernel = found?.kernel
        self.control = control
        self.options = options
        self.sleep = sleep
        self.nonce = nonce
    }

    /// Reaches `socket`, or the socket a lookup finds when it is nil, and says
    /// hello, with `previous`'s reconnect token when there is one, so a client
    /// whose SSH connection went down can be taken back over a new one. Owns
    /// `connection` from here: when connecting fails, it is closed. Throws
    /// `TransportError`.
    static func connect(
        over connection: any RexHostConnection,
        socket stored: RexSocket?,
        resuming previous: RexControlLink? = nil,
        options: RexControlLink.Options = RexControlLink.Options(),
        sleep: @escaping RexControlLink.Sleep = { try await Task.sleep(for: $0) },
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) async throws -> RexSSHTransport {
        do {
            let socket: RexSocket
            var found: (socket: RexSocket, kernel: String?)?
            if let stored {
                socket = stored
            } else {
                let looked = try await lookUp(over: connection, nonce: nonce())
                socket = looked.socket
                found = looked
            }
            let control = try await openControl(
                over: connection, socket: socket, resuming: previous, options: options, sleep: sleep, nonce: nonce)
            return RexSSHTransport(
                connection: connection, socket: socket, found: found, control: control,
                options: options, sleep: sleep, nonce: nonce)
        } catch {
            try? await connection.close()
            throw Self.transportError(error)
        }
    }

    var isConnected: Bool {
        get async { await connection.isConnected }
    }

    func reconnectControl(resuming: Bool) async throws -> RexControlLink {
        if let reconnecting { return try await reconnecting.value }
        let previous = control
        let task = Task { [connection, socket, options, sleep, nonce] in
            // The old link's channel holds the events slot until it closes.
            if resuming {
                await previous.disconnect()
            } else {
                await previous.close()
            }
            return try await Self.openControl(
                over: connection, socket: socket, resuming: resuming ? previous : nil, options: options, sleep: sleep,
                nonce: nonce)
        }
        reconnecting = task
        defer { reconnecting = nil }
        do {
            let link = try await task.value
            control = link
            return link
        } catch {
            throw Self.transportError(error)
        }
    }

    func openDataChannel() async throws -> any HeelerSSHAPIChannel {
        do {
            return try await connection.openRexDataChannel(socketPath: socket.path)
        } catch TransportError.streamLocalOpenFailed {
            throw await Self.refusal(of: socket, over: connection, nonce: nonce())
        }
    }

    /// The connection's reads behind a type of their own, so nothing handed
    /// them can be cast back to the connection and write.
    nonisolated var reads: any RexHostReads { RexReadsOnly(connection: connection) }

    /// The connection's staging behind a type of its own, for the same reason.
    nonisolated var staging: any RexHostStaging { RexStagingOnly(connection: connection) }

    /// And its placing of Heeler's extension, for the same reason.
    nonisolated var extensionPlacing: any RexHostExtensionPlacing {
        RexExtensionPlacingOnly(connection: connection)
    }

    func close() async {
        await control.close()
        try? await connection.close()
    }

    // MARK: Connecting

    /// A fresh look for the socket, as detection makes, for a Host that
    /// stores none, and the kernel the same exec printed.
    private static func lookUp(
        over connection: any RexHostConnection, nonce: String
    ) async throws -> (socket: RexSocket, kernel: String?) {
        let finding: ServerKindDetection.RexFinding
        let kernel: String?
        do {
            (finding, kernel) = try await RexProbe.look(over: connection, nonce: nonce)
        } catch TransportError.malformedResponse {
            // The probe's exec failed: as unreadable as output it cannot parse.
            throw TransportError.rexLookupFailed(
                reason: String(localized: "Heeler could not read whether Rex is on this Host."))
        }
        switch finding {
        case .socketFound(let path):
            guard let socket = RexSocket(path: path) else {
                throw TransportError.rexLookupFailed(
                    reason: String(localized: "The Rex socket found has a path Heeler cannot use."))
            }
            return (socket, kernel)
        case .notInstalled:
            throw TransportError.rexNotInstalled
        case .notRunning:
            throw TransportError.rexServerNotRunning(socketPath: nil)
        case .notUsable(let path):
            throw TransportError.rexAccountRefused(socketPath: path)
        case .unsupported:
            throw TransportError.rexLookupFailed(reason: String(localized: "Heeler finds Rex on macOS and Linux Hosts only."))
        case .unreadable:
            throw TransportError.rexLookupFailed(
                reason: String(localized: "Heeler could not read whether Rex is on this Host."))
        }
    }

    private static func openControl(
        over connection: any RexHostConnection, socket: RexSocket, resuming previous: RexControlLink?,
        options: RexControlLink.Options, sleep: @escaping RexControlLink.Sleep, nonce: @Sendable () -> String
    ) async throws -> RexControlLink {
        let channel: any HeelerSSHAPIChannel
        do {
            channel = try await connection.openRexControlChannel(socketPath: socket.path)
        } catch TransportError.streamLocalOpenFailed {
            throw await refusal(of: socket, over: connection, nonce: nonce())
        }
        return try await RexControlLink.open(over: channel, resuming: previous, options: options, sleep: sleep)
    }

    /// Why SSH refused the socket, as far as the Host can say.
    private static func refusal(
        of socket: RexSocket, over connection: any RexHostConnection, nonce: String
    ) async -> TransportError {
        var answer = RexSocketCheck.Answer.unknown
        if let script = RexSocketCheck.script(socketPath: socket.path, nonce: nonce),
            let result = try? await connection.runRexSocketCheck(Data(script.utf8)), result.exitStatus == 0
        {
            answer = RexSocketCheck.parse(stdout: result.stdout, nonce: nonce)
        }
        switch answer {
        case .missing, .notListening: return .rexServerNotRunning(socketPath: socket.path)
        case .listening: return .rexForwardingRefused(socketPath: socket.path)
        case .unknown: return .rexSocketUnreachable(socketPath: socket.path)
        }
    }

    private static func transportError(_ error: any Error) -> any Error {
        switch error {
        case let error as RexControlError: TransportError(rexControl: error)
        case is CancellationError: TransportError.cancelled
        default: error
        }
    }
}

/// A Rex Host connection's reads, and nothing else of it.
private struct RexReadsOnly: RexHostReads {
    let connection: any RexHostReads

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await connection.readFileSlice(range)
    }

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await connection.readHostFileRange(range)
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        try await connection.fileStatus(atPath: path)
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        try await connection.listFiles(request)
    }

    func hostHomeDirectory() async throws -> String {
        try await connection.hostHomeDirectory()
    }

    func readProcesses(_ request: HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts] {
        try await connection.readProcesses(request)
    }
}

/// A Rex Host connection's staging, and nothing else of it.
private struct RexStagingOnly: RexHostStaging {
    let connection: any RexHostStaging

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        try await connection.stageImage(image, progress: progress)
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        try await connection.stageFile(file, progress: progress)
    }
}

/// A Rex Host connection's placing of Heeler's extension, and nothing else of it.
private struct RexExtensionPlacingOnly: RexHostExtensionPlacing {
    let connection: any RexHostExtensionPlacing

    func placeHeelersExtension(_ contents: Data, inFolder folder: String) async throws {
        try await connection.placeHeelersExtension(contents, inFolder: folder)
    }
}

extension TransportError {
    /// A control link's failure as the user reads it. Rex's own words in an
    /// error response pass through as they came.
    init(rexControl error: RexControlError) {
        switch error {
        case .upgradeRefused(let status) where status == 403:
            self = .rexAccountRefused(socketPath: nil)
        case .upgradeRefused(let status):
            self = .channelFailed(detail: String(localized: "Rex refused the connection with HTTP status \(status)."))
        case .upgradeFailed:
            self = .channelFailed(detail: String(localized: "Rex did not finish opening the connection."))
        case .welcomeTimedOut, .deadlineExceeded:
            self = .timedOut
        case .unsupportedVersion(let offer):
            self = .rexUnsupportedRevision(offered: offer.newestRevision)
        case .server(let error):
            self = .rexRejected(code: error.code, message: error.message)
        case .requestTooLarge:
            self = .channelFailed(detail: String(localized: "The request was larger than Rex accepts, so it was not sent."))
        case .requestUnencodable:
            self = .channelFailed(detail: String(localized: "Heeler could not write the request to Rex."))
        case .unreadableResult:
            self = .rexAnswerUnreadable(String(localized: "Rex's answer could not be read."))
        case .linkEnded(let reason):
            self = .channelFailed(detail: Self.rexLinkEndedDetail(reason))
        }
    }

    /// Why a control link ended, where the user can tell one ending from
    /// another. Each is retried: the next link reads the Host again.
    private static func rexLinkEndedDetail(_ reason: RexControlEnding) -> String {
        switch reason {
        case .droppedByServer:
            String(localized: "Rex dropped the connection because too many events were waiting for Heeler.")
        case .messageTooBig:
            String(localized:
                "A message was too large for the connection to Rex. If this keeps happening, check the Rex version on the Host.")
        case .protocolFailure:
            String(localized:
                "Rex and Heeler did not agree on the connection's protocol. If this keeps happening, check the Rex version on the Host.")
        case .closedHere, .serverWentAway, .linkLost:
            String(localized: "The connection to Rex ended.")
        }
    }
}
