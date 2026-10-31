import Foundation

@testable import Heeler

/// An SSH connection to a herdr-core Host, without SSH: the locator's exec
/// prints scripted lines, and the forwarded channel is either refused or a
/// `FakeCoreSocket` that answers `hello` with a scripted line. What is under
/// test above it is the real `HerdrCoreSSHTransport` and `HerdrCoreLink`.
actor ScriptedCoreHost: HerdrCoreHostConnection, ServerKindDetectionConnection {
    enum Channel: Sendable {
        case refused
        /// Answers the plain `hello` line with these bytes.
        case answersHello(Data)
        /// A core that answers `hello`, `events.subscribe`, `server.status` and
        /// `doc.get`, as `ScriptedCoreHost.Core` scripts them.
        case core(Core)
    }

    /// A running core's answers, for the Host session above the real link.
    struct Core: Sendable {
        var id = "c1"
        var sequence = 0
        var terminals: [JSONValue] = []
        var pid = 4242
        /// False: `doc.get` goes unanswered while everything else still works.
        var answersDocumentReads = true
        static let eventsChannel: UInt32 = 1

        var helloReply: Data {
            ScriptedCoreHost.helloReply(result: .object([
                "generation": .number(1), "version": .string("0.1.13"),
                "core": .object(["id": .string(id), "name": .string("lab")]),
                "framed": .bool(true), "methods": .array([]),
                "features": .array(["framed", "attach", "events", "status", "shell"].map(JSONValue.string)),
            ]))
        }

        /// A real core gives every stream a channel of its own.
        func subscribeResult(channel: UInt32) -> JSONValue {
            .object([
                "seq": .number(Double(sequence)), "terminals": .array(terminals),
                "channel": .number(Double(channel)),
            ])
        }

        var statusResult: JSONValue {
            .object([
                "core": .object(["id": .string(id)]), "pid": .number(Double(pid)), "uptime_ms": .number(1000),
                "version": .string("0.1.13"),
            ])
        }
    }

    /// What the exec of a `HostProcessReader` script does. A whole answer is
    /// framed by the nonce and names the pid the script asked about.
    enum ProcessRead: Sendable {
        case names([String])
        /// The reader could not read that process's environment.
        case unreadable
        case exits(status: Int32, stdout: String)
        case throwsError(TransportError)
    }

    /// What `herdr session list --json` does in the detection exec.
    enum HerdrRead: Sendable, CustomStringConvertible {
        /// The shell cannot find it: status 127, nothing on stdout.
        case notInstalled
        case answers(String)
        case fails(status: Int32, output: String)

        var description: String {
            switch self {
            case .notInstalled: "not installed"
            case .answers(let output): "answers \(output)"
            case .fails(let status, let output): "fails \(status) \(output)"
            }
        }
    }

    /// What the confirmed Start's exec does.
    enum StartResponse: Sendable {
        case exits(status: Int32, stdout: String, stderr: String)
        case throwsError(TransportError)

        /// A core this Start brought up, under an rc file's banner and the
        /// shell's job-control warning. A real exec takes longer than the
        /// scripted one, so its uptime is zero here.
        static let fresh = exits(
            status: 0, stdout: "Welcome to box\n{\"pid\":7,\"uptime_ms\":0}\n",
            stderr: "bash: no job control in this shell\n")
        /// A core up for an hour.
        static let alreadyRunning = exits(
            status: 0, stdout: "{\"pid\":7,\"uptime_ms\":3600000}\n",
            stderr: "bash: no job control in this shell\n")
    }

    static let nonce = "scripted-core-host-nonce"
    static let installedPath = "/home/me/.local/bin/herdr-core"
    static let socketPath = "/run/user/1000/herdr-core/work.sock"

    static let helloResult: JSONValue = .object([
        "generation": .number(1), "version": .string("0.1.13"),
        "core": .object(["id": .string("c1"), "name": .string("lab")]),
        "framed": .bool(true), "methods": .array([]),
        "features": .array(["framed", "attach", "events", "status", "shell"].map(JSONValue.string)),
    ])

    static func helloReply(result: JSONValue = helloResult) -> Data {
        let reply = try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("hello"), "result": result,
        ]))
        return (reply ?? Data()) + Data([0x0A])
    }

    static func helloReply(errorKind: String) -> Data {
        let reply = try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("hello"),
            "error": .object([
                "code": .number(-32601), "message": .string(errorKind),
                "data": .object(["kind": .string(errorKind)]),
            ]),
        ]))
        return (reply ?? Data()) + Data([0x0A])
    }

    static func helloReply(features: [String]) -> Data {
        helloReply(result: .object([
            "generation": .number(1), "version": .string("0.0.9"),
            "core": .object(["id": .string("c1"), "name": .string("lab")]),
            "framed": .bool(true), "methods": .array([]),
            "features": .array(features.map(JSONValue.string)),
        ]))
    }

    /// What the locator prints for a typical Linux Host.
    static func locatorLines(
        executable: String? = installedPath, version: String = "0.1.13", lock: String? = nil,
        defaultPath: String = socketPath, socketFile: Bool = false, kernel: String = "Linux",
        shell: String? = "/bin/bash"
    ) -> [String] {
        var lines = ["kernel \(kernel)"]
        if let executable { lines += ["executable \(executable)", "version \(version)"] }
        lines.append("default \(defaultPath)")
        if let lock { lines.append("lock \(lock)") }
        lines.append("socket-file \(socketFile ? 1 : 0)")
        if let shell { lines.append("shell \(shell)") }
        return lines
    }

    nonisolated let routeID: UUID? = nil
    /// The Host Helper's side of this Host. Its steps stay out of `log`.
    nonisolated let helper: ScriptedHelperHost
    private let locator: [String]
    private let locatorStatus: Int32
    private let shellBanner: Data
    private var channel: Channel
    private var connected = true
    private let start: StartResponse
    private let channelAfterStart: Channel?
    private let herdrRead: HerdrRead
    private let detectionFailure: TransportError?
    private var processRead: ProcessRead
    private var isProcessReadHeld = false
    private var heldProcessReads: [CheckedContinuation<Void, Never>] = []
    private var processReadWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []
    private(set) var socket: FakeCoreSocket?
    /// Every channel a core answered, oldest first.
    private(set) var sockets: [FakeCoreSocket] = []
    /// Every channel-0 method the core received, oldest first.
    private(set) var methods: [String] = []
    /// Every attach the core received, oldest first, with the channel it named.
    private(set) var attaches: [(channel: UInt32, params: JSONValue, socket: FakeCoreSocket)] = []
    private var methodWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Every Changes read that reached the Host's services, oldest first.
    private(set) var changesReads: [ChangesReadRequest] = []
    /// Every skills probe that reached the Host's services, oldest first.
    private(set) var skillQueries: [SkillListQuery] = []
    private var changes: CheckoutChangesRead?
    private var skills: [AgentSkill] = []
    private var attachRefusals: [String] = []
    private var isHoldingAttachReplies = false
    private var heldAttachReplies: [(socket: FakeCoreSocket, id: String, result: JSONValue)] = []

    /// `shellBanner` is what the user's shell prints before it runs the script.
    init(
        locator: [String] = locatorLines(), locatorStatus: Int32 = 0, shellBanner: Data = Data(),
        herdrRead: HerdrRead = .notInstalled, detectionFailure: TransportError? = nil,
        helper: ScriptedHelperHost = ScriptedHelperHost(),
        start: StartResponse = .fresh, channelAfterStart: Channel? = nil,
        processRead: ProcessRead = .names([]),
        channel: Channel
    ) {
        self.processRead = processRead
        self.helper = helper
        self.start = start
        self.channelAfterStart = channelAfterStart
        self.herdrRead = herdrRead
        self.detectionFailure = detectionFailure
        self.locator = locator
        self.locatorStatus = locatorStatus
        self.shellBanner = shellBanner
        self.channel = channel
    }

    func runCoreLocator(_ script: Data) async throws -> GitExecResult {
        log.append("locator")
        scripts.append(String(decoding: script, as: UTF8.self))
        let output = (["\(Self.nonce) begin"] + locator + ["\(Self.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: shellBanner + Data(output.utf8), stderr: Data(), exitStatus: locatorStatus)
    }

    func runCoreStart(_ script: Data) async throws -> GitExecResult {
        log.append("start")
        scripts.append(String(decoding: script, as: UTF8.self))
        if let channelAfterStart { channel = channelAfterStart }
        switch start {
        case .exits(let status, let stdout, let stderr):
            return GitExecResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitStatus: status)
        case .throwsError(let error):
            throw error
        }
    }

    func runHostProcessRead(_ script: Data) async throws -> GitExecResult {
        log.append("process-read")
        let body = String(decoding: script, as: UTF8.self)
        scripts.append(body)
        // What this read answers is what the Host held when it started.
        let read = processRead
        let waiters = processReadWaiters.filter { $0.count <= processReadCount }
        processReadWaiters.removeAll { $0.count <= processReadCount }
        for waiter in waiters { waiter.continuation.resume() }
        while isProcessReadHeld {
            await withCheckedContinuation { heldProcessReads.append($0) }
        }
        let pid = body.split(separator: "\n").last { $0.hasPrefix("e ") }?.dropFirst(2) ?? ""
        let answer: [String]
        switch read {
        case .names(let names):
            answer = names.map { "N \(pid) \($0)" } + ["E \(pid) ok"]
        case .unreadable:
            answer = ["E \(pid) -"]
        case .exits(let status, let stdout):
            return GitExecResult(stdout: Data(stdout.utf8), stderr: Data(), exitStatus: status)
        case .throwsError(let error):
            throw error
        }
        let lines = ["__HEELER_PROC_BEGIN_\(Self.nonce)"] + answer + ["", "__HEELER_PROC_END_\(Self.nonce)"]
        return GitExecResult(
            stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: Data(), exitStatus: 0)
    }

    private var processReadCount: Int { log.filter { $0 == "process-read" }.count }

    /// Prints what the script asked for, framed by the nonce the script carries.
    func runServerKindDetection(_ script: Data) async throws -> GitExecResult {
        log.append("detection")
        let body = String(decoding: script, as: UTF8.self)
        scripts.append(body)
        if let detectionFailure { throw detectionFailure }
        let nonce = Self.nonce(in: body)
        let (status, output): (Int32, String) =
            switch herdrRead {
            case .notInstalled: (127, "")
            case .answers(let output): (0, output)
            case .fails(let status, let output): (status, output)
            }
        var printed = "\n\(nonce) herdr-tui begin\n\(output)\n\(nonce) herdr-tui status \(status)\n"
        if body.contains("__session=") {
            printed += (["\(nonce) begin"] + locator + ["\(nonce) end"]).joined(separator: "\n") + "\n"
        }
        return GitExecResult(stdout: shellBanner + Data(printed.utf8), stderr: Data(), exitStatus: locatorStatus)
    }

    private static func nonce(in script: String) -> String {
        let marker = "herdr-tui begin\\n' '"
        guard let start = script.range(of: marker)?.upperBound,
            let end = script[start...].firstIndex(of: "'")
        else { return "" }
        return String(script[start..<end])
    }

    func openCoreLinkChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel {
        log.append("open \(socketPath)")
        switch channel {
        case .refused:
            throw TransportError.streamLocalOpenFailed(path: socketPath)
        case .answersHello(let reply):
            let socket = FakeCoreSocket()
            self.socket = socket
            Task {
                _ = await socket.nextWrittenLine()
                await socket.deliver(reply)
            }
            return socket
        case .core(let core):
            let socket = FakeCoreSocket()
            self.socket = socket
            sockets.append(socket)
            Task {
                _ = await socket.nextWrittenLine()
                await socket.deliver(core.helloReply)
                await self.answer(on: socket, core: core)
            }
            return socket
        }
    }

    private func answer(on socket: FakeCoreSocket, core: Core) async {
        var eventsChannel = Core.eventsChannel
        while !Task.isCancelled {
            let request = await socket.nextRequest()
            methods.append(request.method)
            resumeMethodWaiters()
            switch request.method {
            case "events.subscribe":
                try? await socket.reply(to: request.id, result: core.subscribeResult(channel: eventsChannel))
                eventsChannel += 1
            case "terminal.attach":
                if !attachRefusals.isEmpty {
                    try? await socket.replyError(to: request.id, kind: attachRefusals.removeFirst())
                    continue
                }
                attaches.append((eventsChannel, request.params, socket))
                let result: JSONValue = .object([
                    "channel": .number(Double(eventsChannel)),
                    "terminal": .object(["address": request.params["terminal"] ?? .null]),
                ])
                eventsChannel += 1
                if isHoldingAttachReplies {
                    heldAttachReplies.append((socket, request.id, result))
                } else {
                    try? await socket.reply(to: request.id, result: result)
                }
            case "server.status": try? await socket.reply(to: request.id, result: core.statusResult)
            // A real core's answer for a name nobody wrote.
            case "doc.get" where core.answersDocumentReads:
                try? await socket.reply(to: request.id, result: .object(["version": .number(0), "value": .null]))
            case "terminal.read":
                try? await socket.reply(
                    to: request.id,
                    result: .object([
                        "text": .string("screen"), "complete": .bool(true), "how": .string("screen"),
                    ]))
            default: break
            }
        }
    }

    private func resumeMethodWaiters() {
        let met = methodWaiters.filter { waiter in
            methods.filter { $0 == waiter.method }.count >= waiter.count
        }
        methodWaiters.removeAll { waiter in
            methods.filter { $0 == waiter.method }.count >= waiter.count
        }
        for waiter in met { waiter.continuation.resume() }
    }

    // MARK: Changing the Host under a session

    /// What the next channel opened to the socket finds.
    func setChannel(_ channel: Channel) {
        self.channel = channel
    }

    /// Whether the SSH connection is up.
    func setConnected(_ connected: Bool) {
        self.connected = connected
    }

    /// What the next process read answers.
    func setProcessRead(_ read: ProcessRead) {
        processRead = read
    }

    /// The core receives each attach and answers nothing until released, while
    /// the rest of channel 0 keeps answering.
    /// The next `terminal.attach` answers with this error kind.
    func refuseNextAttach(kind: String) {
        attachRefusals.append(kind)
    }

    func holdAttachReplies() {
        isHoldingAttachReplies = true
    }

    func releaseAttachReplies() async {
        isHoldingAttachReplies = false
        let held = heldAttachReplies
        heldAttachReplies = []
        for reply in held {
            try? await reply.socket.reply(to: reply.id, result: reply.result)
        }
    }

    /// What the Host's git answers a Changes read with. Nil keeps the seam's
    /// refusal.
    func setChanges(_ read: CheckoutChangesRead?) {
        changes = read
    }

    func readChanges(_ request: ChangesReadRequest) async throws -> CheckoutChangesRead {
        changesReads.append(request)
        guard let changes else { throw ChangesReadError.unavailable }
        return changes
    }

    /// The skills the Host's probe finds.
    func setSkills(_ skills: [AgentSkill]) {
        self.skills = skills
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        skillQueries.append(query)
        return skills
    }

    /// Process reads start and then wait, as one on a slow link does.
    func holdProcessReads() {
        isProcessReadHeld = true
    }

    func releaseProcessReads() {
        isProcessReadHeld = false
        let held = heldProcessReads
        heldProcessReads = []
        for read in held { read.resume() }
    }

    /// Returns once this many process reads have started in all.
    func waitForProcessRead(count: Int = 1) async {
        if processReadCount >= count { return }
        await withCheckedContinuation { continuation in
            processReadWaiters.append((count, continuation))
        }
    }

    /// Returns once the core has received `method` this many times in all.
    func waitForMethod(_ method: String, count: Int = 1) async {
        if methods.filter({ $0 == method }).count >= count { return }
        await withCheckedContinuation { continuation in
            methodWaiters.append((method, count, continuation))
        }
    }

    /// One line of the events channel, from the core.
    func deliverEvent(_ line: Data, on socket: FakeCoreSocket? = nil) async throws {
        guard let target = socket ?? self.socket else { return }
        try await target.deliver(
            HerdrCoreFrame(channel: Core.eventsChannel, kind: .data, payload: line + Data([0x0A])))
    }

    var isConnected: Bool { connected }

    func close() async throws {
        log.append("close")
        connected = false
    }

    func hostPlatform() async throws -> HostPlatform {
        try await helper.hostPlatform()
    }

    func runHostHelperScript(_ script: HostHelperScript) async throws -> GitExecResult {
        try await helper.runHostHelperScript(script)
    }

    func readHostHelperFile(at path: String, privateDirectory: String) async throws -> Data? {
        try await helper.readHostHelperFile(at: path, privateDirectory: privateDirectory)
    }

    func replaceHostHelperFile(_ contents: Data, at path: String, privateDirectory: String?) async throws {
        try await helper.replaceHostHelperFile(contents, at: path, privateDirectory: privateDirectory)
    }

    func hostHomeDirectory() async throws -> String { ScriptedHelperHost.home }

    /// The transport the app gets for this Host, with a nonce the script knows.
    nonisolated func transport(
        session: String = "work",
        sleep: @escaping HerdrCoreLink.Sleep = { try await Task.sleep(for: $0) }
    ) -> HerdrCoreSSHTransport {
        HerdrCoreSSHTransport(connection: self, session: session, nonce: { Self.nonce }, sleep: sleep)
    }
}
