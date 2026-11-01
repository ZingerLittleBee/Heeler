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
        /// The environment holds these variables.
        case values([String: String])
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

    static let windowsExecutable = #"C:\Users\me\AppData\Local\Programs\herdr-core\herdr-core.exe"#
    static let windowsPipe = #"\\.\pipe\herdr-core-me-work.sock"#

    /// What the probe prints for a native Windows Host.
    static func windowsLocatorLines(
        executable: String? = windowsExecutable, version: String = "0.1.16", lock: String? = nil,
        pipe: Bool = true
    ) -> [String] {
        var lines = ["kernel Windows", #"home C:\Users\me"#]
        if let executable { lines += ["executable \(executable)", "version \(version)"] }
        lines.append("default \(windowsPipe)")
        if let lock { lines.append("lock \(lock)") }
        lines.append("socket-file \(pipe ? 1 : 0)")
        return lines
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
    private var nextLocatorAnswers: [GitExecResult] = []
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
    private var agentDiscovery = GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 0)
    private var herdrAppAnswer: Result<GitExecResult, TransportError> = .success(
        GitExecResult(stdout: Data(), stderr: Data(), exitStatus: 0))

    /// Everything that happened, in order.
    private(set) var log: [String] = []
    private(set) var scripts: [String] = []
    private(set) var socket: FakeCoreSocket?
    /// Every channel a core answered, oldest first.
    private(set) var sockets: [FakeCoreSocket] = []
    /// Every channel-0 method the core received, oldest first.
    private(set) var methods: [String] = []
    /// The params of every `terminal.run` the core received, oldest first.
    private(set) var runs: [JSONValue] = []
    /// Every attach the core received, oldest first, with the channel it named.
    private(set) var attaches: [(channel: UInt32, params: JSONValue, socket: FakeCoreSocket)] = []
    private var methodWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Every Changes read that reached the Host's services, oldest first.
    private(set) var changesReads: [ChangesReadRequest] = []
    /// Every skills probe that reached the Host's services, oldest first.
    private(set) var skillQueries: [SkillListQuery] = []
    /// Every file staged over the Host's SFTP, oldest first, where it landed.
    private(set) var stagedFiles: [(path: String, contents: Data)] = []
    private var stagingFailures: [AttachmentStagingError] = []
    /// How many times anything asked the Host's platform.
    private(set) var platformAsks = 0
    private var platformFailure: TransportError?
    private var changes: CheckoutChangesRead?
    private var skills: [AgentSkill] = []
    private var attachRefusals: [String] = []
    /// Every `terminal.put` the core received, oldest first, with its decoded bytes.
    private(set) var puts: [(terminal: String, name: String, contents: Data)] = []
    private var putRefusals: [String] = []
    private var isHoldingNextPutReply = false
    private var nextPutByteCount: Int?
    private var attachPaint: Data?
    private var paintsViewers = true
    private var runReply: JSONValue?
    private var unansweredRuns: [(socket: FakeCoreSocket, id: String)] = []
    private var templateList: JSONValue?
    private var isHoldingAttachReplies = false
    private var heldAttachReplies:
        [(socket: FakeCoreSocket, id: String, result: JSONValue, channel: UInt32, isObserving: Bool)] = []
    private var holdsOnlyViewerAttaches = false
    private var heldTerminalReads: [(socket: FakeCoreSocket, id: String)] = []
    private var isHoldingHellos = false
    private var heldHellos: [CheckedContinuation<Void, Never>] = []
    private var heldInterrupts: [(socket: FakeCoreSocket, id: String)] = []
    /// The params of every `terminal.interrupt`, oldest first.
    private(set) var interrupts: [JSONValue] = []

    /// What each native Windows probe prints; nil is a Unix Host.
    private var windowsLocator: [String]?
    /// What a `connect` exec's account shell prints before the marker.
    private var connectBanner = Data()
    /// Every `connect` exec's whole command line, oldest first.
    private(set) var connectCommands: [String] = []
    private var corePlatformFailure: TransportError?
    /// What git prints as each directory's top level on a native Windows Host.
    private var windowsGitRoots: [String: String] = [:]
    private var windowsCheckoutAnswer: GitExecResult?
    /// Every ask for the POSIX checkout script, which never reaches a Host here.
    private(set) var posixCheckoutAsks = 0
    /// Every native Windows discovery's whole command line, oldest first.
    private(set) var windowsDiscoveryCommands: [String] = []
    private var windowsDiscovery: (programs: [String], version: String, banner: String) = ([], "", "")
    private var windowsDiscoveryAnswer: GitExecResult?

    /// `shellBanner` is what the user's shell prints before it runs the script.
    init(
        windowsLocator: [String]? = nil,
        locator: [String] = locatorLines(), locatorStatus: Int32 = 0, shellBanner: Data = Data(),
        herdrRead: HerdrRead = .notInstalled, detectionFailure: TransportError? = nil,
        helper: ScriptedHelperHost = ScriptedHelperHost(),
        start: StartResponse = .fresh, channelAfterStart: Channel? = nil,
        processRead: ProcessRead = .names([]),
        channel: Channel
    ) {
        self.windowsLocator = windowsLocator
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

    /// What the next locator exec answers instead of its script's output.
    func answerNextLocator(_ answer: GitExecResult) {
        nextLocatorAnswers.append(answer)
    }

    func runCoreLocator(_ script: Data) async throws -> GitExecResult {
        log.append("locator")
        scripts.append(String(decoding: script, as: UTF8.self))
        if !nextLocatorAnswers.isEmpty { return nextLocatorAnswers.removeFirst() }
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

    /// `runBoundedScript` refuses native Windows before anything runs.
    private func refuseOnWindows(_ feature: String) throws {
        guard windowsLocator == nil else {
            throw TransportError.hostFeatureUnavailable(feature: "\(feature) is not yet supported on native Windows")
        }
    }

    func runHostProcessRead(_ script: Data) async throws -> GitExecResult {
        try refuseOnWindows("herdr-core Hosts")
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
        case .values(let values):
            answer = values.map { name, value in
                "V \(pid) \(name) " + value.utf8.map { String(format: "%02x", $0) }.joined()
            } + ["E \(pid) ok"]
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

    func runAgentDiscovery(_ script: Data) async throws -> GitExecResult {
        try refuseOnWindows("herdr-core Hosts")
        log.append("agent-discovery")
        scripts.append(String(decoding: script, as: UTF8.self))
        return agentDiscovery
    }

    func runHerdrAppControl(_ script: Data) async throws -> GitExecResult {
        try refuseOnWindows("herdr-core Hosts")
        log.append("herdr-app")
        scripts.append(String(decoding: script, as: UTF8.self))
        return try herdrAppAnswer.get()
    }

    /// What every `herdr-app` exec answers from now on.
    func setHerdrAppAnswer(_ answer: Result<GitExecResult, TransportError>) {
        herdrAppAnswer = answer
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
        return try linkChannel(onPath: socketPath)
    }

    func openCoreLinkExec(command: String) async throws -> any WindowsTerminalExecChannel {
        log.append("connect")
        connectCommands.append(command)
        let channel = try linkChannel(onPath: command)
        // What a real exec's `echo` prints before the core has said anything.
        await channel.deliver(connectBanner + Data("\(PowerShellCommand.streamMarker)\r\n".utf8))
        return channel
    }

    func corePlatform() async throws -> HostPlatform {
        if let corePlatformFailure { throw corePlatformFailure }
        return windowsLocator == nil ? .posix : .nativeWindows
    }

    func runWindowsCoreProbe(_ command: String) async throws -> GitExecResult {
        log.append("windows-probe")
        scripts.append(try HerdrCoreWindowsLocatorTests.decoded(command))
        let lines = windowsLocator ?? []
        let output = (["\(Self.nonce) begin"] + lines + ["\(Self.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: shellBanner + Data(output.utf8), stderr: Data(), exitStatus: locatorStatus)
    }

    /// Prints what its script would: one line for each directory git answers for.
    func runWindowsCheckoutRead(_ command: String) async throws -> GitExecResult {
        log.append("windows-checkouts")
        let body = try HerdrCoreWindowsLocatorTests.decoded(command)
        scripts.append(body)
        if let windowsCheckoutAnswer { return windowsCheckoutAnswer }
        let lines = Self.windowsCheckoutDirectories(in: body).enumerated().compactMap { index, directory in
            windowsGitRoots[directory].map { "root \(index) \($0)" }
        }
        let output = (["", "\(Self.nonce) begin"] + lines + ["\(Self.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: shellBanner + Data(output.utf8), stderr: Data(), exitStatus: 0)
    }

    /// The literals of the script's directory list, as PowerShell reads them.
    static func windowsCheckoutDirectories(in script: String) -> [String] {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(of: "$dirs = @("),
            let end = lines[start...].firstIndex(of: ")")
        else { return [] }
        return lines[(start + 1)..<end].map {
            String($0.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
    }

    /// Prints what its script would: the asked-for programs this machine has, with
    /// `version` the program's own words, or empty for one the exec could not run.
    func runWindowsAgentDiscovery(_ command: String) async throws -> GitExecResult {
        log.append("windows-agent-discovery")
        windowsDiscoveryCommands.append(command)
        if let windowsDiscoveryAnswer { return windowsDiscoveryAnswer }
        let script = try Self.decodedDiscovery(command)
        let marker = "__HEELER_AGENTS_BEGIN_"
        let nonce = script.range(of: marker).map { script[$0.upperBound...].prefix { $0 != "'" } } ?? ""
        let agents = windowsDiscovery.programs.filter { script.contains("'\($0)'") }.map { "agent \($0)" }
        let lines =
            ["", "\(marker)\(nonce)"] + agents
            + ["version \(windowsDiscovery.version)", "", "__HEELER_AGENTS_END_\(nonce)"]
        let output = windowsDiscovery.banner + lines.joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(output.utf8), stderr: Data(), exitStatus: 0)
    }

    func setWindowsAgentDiscovery(programs: [String], version: String, banner: String = "") {
        windowsDiscovery = (programs, version, banner)
    }

    func setWindowsDiscoveryAnswer(_ answer: GitExecResult?) {
        windowsDiscoveryAnswer = answer
    }

    /// A discovery's script, which keeps the profile the locator's skips.
    static func decodedDiscovery(_ command: String) throws -> String {
        let prefix = "powershell.exe -NoLogo -NonInteractive -EncodedCommand "
        guard command.hasPrefix(prefix),
            let bytes = Data(base64Encoded: String(command.dropFirst(prefix.count))),
            let script = String(data: bytes, encoding: .utf16LittleEndian)
        else { throw TransportError.malformedResponse("Not a discovery command: \(command)") }
        return script
    }

    func setWindowsGitRoots(_ roots: [String: String]) {
        windowsGitRoots = roots
    }

    /// What every later checkout read gets instead of its script's output.
    func setWindowsCheckoutAnswer(_ answer: GitExecResult?) {
        windowsCheckoutAnswer = answer
    }

    /// `runGitScript` refuses native Windows before anything runs.
    func checkouts(for directories: [String]) async throws -> [String: HostCheckout] {
        posixCheckoutAsks += 1
        try refuseOnWindows("Changes")
        throw ChangesReadError.unavailable
    }

    func runWindowsServerKindDetection(_ command: String) async throws -> GitExecResult {
        log.append("windows-detection")
        let body = try HerdrCoreWindowsLocatorTests.decoded(command)
        scripts.append(body)
        if let detectionFailure { throw detectionFailure }
        let (status, output): (Int32, String) =
            switch herdrRead {
            case .notInstalled: (127, "")
            case .answers(let output): (0, output)
            case .fails(let status, let output): (status, output)
            }
        let nonce = Self.windowsNonce(in: body)
        var printed = "\n\(nonce) herdr-tui begin\n\(output)\n\(nonce) herdr-tui status \(status)\n"
        if body.contains("$s = ") {
            let lines = windowsLocator ?? []
            printed += (["\(nonce) begin"] + lines + ["\(nonce) end"]).joined(separator: "\n") + "\n"
        }
        return GitExecResult(stdout: shellBanner + Data(printed.utf8), stderr: Data(), exitStatus: locatorStatus)
    }

    private static func windowsNonce(in script: String) -> String {
        let marker = " herdr-tui begin'"
        guard let end = script.range(of: marker)?.lowerBound,
            let start = script[..<end].lastIndex(of: "'")
        else { return "" }
        return String(script[script.index(after: start)..<end])
    }

    /// What every later probe prints.
    func setWindowsLocator(_ lines: [String]) {
        windowsLocator = lines
    }

    func setConnectBanner(_ banner: Data) {
        connectBanner = banner
    }

    /// Every ask for the path fails with this until it is nil.
    func setCorePlatformFailure(_ failure: TransportError?) {
        corePlatformFailure = failure
    }

    private func linkChannel(onPath path: String) throws -> FakeCoreSocket {
        switch channel {
        case .refused:
            throw TransportError.streamLocalOpenFailed(path: path)
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
                await self.waitOutHelloHold()
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
                let channel = eventsChannel
                eventsChannel += 1
                let isObserving = request.params["observe"] == .bool(true)
                if isHoldingAttachReplies, !(holdsOnlyViewerAttaches && isObserving) {
                    heldAttachReplies.append((socket, request.id, result, channel, isObserving))
                } else {
                    try? await socket.reply(to: request.id, result: result)
                    await paint(channel: channel, on: socket, isObserving: isObserving)
                }
            case "terminal.run":
                runs.append(request.params)
                if let runReply {
                    try? await socket.reply(to: request.id, result: runReply)
                } else {
                    unansweredRuns.append((socket, request.id))
                }
            case "terminal.put":
                answerPut(request, on: socket)
            case "templates.list":
                if let templateList { try? await socket.reply(to: request.id, result: templateList) }
            case "server.status": try? await socket.reply(to: request.id, result: core.statusResult)
            // A real core's answer for a name nobody wrote.
            case "doc.get" where core.answersDocumentReads:
                try? await socket.reply(to: request.id, result: .object(["version": .number(0), "value": .null]))
            // Nobody answers until the test says what the core knows.
            case "terminal.get":
                heldTerminalReads.append((socket, request.id))
            // The core presses the key and watches until the test says.
            case "terminal.interrupt":
                interrupts.append(request.params)
                heldInterrupts.append((socket, request.id))
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

    /// What each `terminal.run` answers. Nil leaves it unanswered.
    func setRunReply(_ reply: JSONValue?) {
        runReply = reply
    }

    /// Answers each `terminal.run` still waiting, as a core does once the
    /// program first reports.
    func answerWaitingRuns(with reply: JSONValue) async {
        let waiting = unansweredRuns
        unansweredRuns = []
        for run in waiting { try? await run.socket.reply(to: run.id, result: reply) }
    }

    /// What each `templates.list` answers. Nil leaves it unanswered.
    func setTemplateList(_ reply: JSONValue?) {
        templateList = reply
    }

    /// What the next agent discovery's exec prints.
    func setAgentDiscovery(stdout: String, status: Int32 = 0) {
        agentDiscovery = GitExecResult(stdout: Data(stdout.utf8), stderr: Data(), exitStatus: status)
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

    /// The next `terminal.put` answers with this error kind.
    func refuseNextPut(kind: String) {
        putRefusals.append(kind)
    }

    /// The next `terminal.put` is received and never answered.
    func holdNextPutReply() {
        isHoldingNextPutReply = true
    }

    func setNextPutByteCount(_ count: Int) {
        nextPutByteCount = count
    }

    /// As herdr-core 0.1.16: past 8 MiB it refuses, a taken name gets `-2`, and the
    /// file lands in the Terminal's own folder.
    private func answerPut(
        _ request: (id: String, method: String, params: JSONValue), on socket: FakeCoreSocket
    ) {
        let contents = Data(base64Encoded: request.params["data"]?.stringValue ?? "") ?? Data()
        let terminal = request.params["terminal"]?.stringValue ?? ""
        let name = request.params["name"]?.stringValue ?? ""
        let earlier = puts.filter { $0.terminal == terminal && $0.name == name }.count
        puts.append((terminal, name, contents))
        if isHoldingNextPutReply {
            isHoldingNextPutReply = false
            return
        }
        let refusal = putRefusals.isEmpty ? nil : putRefusals.removeFirst()
        let byteCount = nextPutByteCount ?? contents.count
        nextPutByteCount = nil
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        let landed = earlier == 0 ? name : "\(stem)-\(earlier + 1).\(fileExtension)"
        let path = #"C:\Users\me\AppData\Local\herdr-core\work\files\"# + terminal + #"\"# + landed
        Task {
            if let refusal {
                try? await socket.replyError(to: request.id, kind: refusal)
            } else if contents.count > 8 * 1024 * 1024 {
                try? await socket.replyError(to: request.id, kind: "invalid_params")
            } else {
                try? await socket.reply(
                    to: request.id,
                    result: .object(["path": .string(path), "bytes": .number(Double(byteCount))]))
            }
        }
    }

    /// What an attach gets right after its answer from here on, as a real core
    /// sends its first paint. `viewers: false` leaves a viewer's for the test to
    /// deliver, while an observing attach still gets it.
    func setAttachPaint(_ paint: Data?, viewers: Bool = true) {
        attachPaint = paint
        paintsViewers = viewers
    }

    /// `onlyViewers` lets an attach that only observes through, as Chat's screen
    /// reads are.
    func holdAttachReplies(onlyViewers: Bool = false) {
        isHoldingAttachReplies = true
        holdsOnlyViewerAttaches = onlyViewers
    }

    /// Each answer goes out now, with the paint the core would send by now.
    func releaseAttachReplies() async {
        isHoldingAttachReplies = false
        let held = heldAttachReplies
        heldAttachReplies = []
        for reply in held {
            try? await reply.socket.reply(to: reply.id, result: reply.result)
            await paint(channel: reply.channel, on: reply.socket, isObserving: reply.isObserving)
        }
    }

    private func paint(channel: UInt32, on socket: FakeCoreSocket, isObserving: Bool) async {
        guard let attachPaint, isObserving || paintsViewers else { return }
        try? await socket.deliver(HerdrCoreFrame(channel: channel, kind: .data, payload: attachPaint))
    }

    /// Answers every `terminal.get` waiting so far with this record.
    func answerTerminalReads(with record: JSONValue) async {
        let held = heldTerminalReads
        heldTerminalReads = []
        for read in held { try? await read.socket.reply(to: read.id, result: record) }
    }

    /// Answers every `terminal.get` waiting so far with this error kind.
    func refuseTerminalReads(kind: String) async {
        let held = heldTerminalReads
        heldTerminalReads = []
        for read in held { try? await read.socket.replyError(to: read.id, kind: kind) }
    }

    /// A new link's `hello` waits for its answer until `releaseHellos`, as one
    /// that is slow to establish does.
    func holdHellos() {
        isHoldingHellos = true
    }

    func releaseHellos() {
        isHoldingHellos = false
        let held = heldHellos
        heldHellos = []
        for waiter in held { waiter.resume() }
    }

    private func waitOutHelloHold() async {
        while isHoldingHellos {
            await withCheckedContinuation { heldHellos.append($0) }
        }
    }

    /// Answers every `terminal.interrupt` waiting so far, as a core does once its
    /// watch ends.
    func answerInterrupts(outcome: String = "stopped") async {
        let held = heldInterrupts
        heldInterrupts = []
        for interrupt in held {
            try? await interrupt.socket.reply(
                to: interrupt.id,
                result: .object(["outcome": .string(outcome), "key": .string("esc")]))
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

    /// The next stages fail with these, in order, and later ones succeed.
    func failStages(with failures: [AttachmentStagingError]) {
        stagingFailures = failures
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        try StagedImage(
            path: try stage(image.fileURL, named: "image.\(image.format.fileExtension)"))
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        try StagedFile(path: try stage(file.fileURL, named: file.remoteFilename))
    }

    private func stage(_ source: URL, named name: String) throws -> String {
        if !stagingFailures.isEmpty { throw stagingFailures.removeFirst() }
        let path = "/tmp/heeler-stage/stage-\(stagedFiles.count)/\(name)"
        stagedFiles.append((path, try Data(contentsOf: source)))
        return path
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
        platformAsks += 1
        if let platformFailure { throw platformFailure }
        return try await helper.hostPlatform()
    }

    /// Every platform ask fails with this until it is nil.
    func setPlatformFailure(_ failure: TransportError?) {
        platformFailure = failure
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

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        await helper.readHostFile(range)
    }

    func replaceHostTextFile(path: String, expected: Data?, contents: Data?) async throws {
        try await helper.replaceHostText(path: path, expected: expected, contents: contents)
    }

    func createHostFolder(path: String) async throws {
        await helper.createFolder(path)
    }

    func removeEmptyHostFolder(path: String) async throws {
        await helper.removeFolderIfEmpty(path)
    }

    /// Refuses native Windows, as the real read does.
    func hostHomeDirectory() async throws -> String {
        guard windowsLocator == nil else {
            throw TransportError.hostFeatureUnavailable(feature: "Chat is not yet supported on native Windows")
        }
        return ScriptedHelperHost.home
    }

    /// The transport the app gets for this Host, with a nonce the script knows.
    nonisolated func transport(
        session: String = "work",
        sleep: @escaping HerdrCoreLink.Sleep = { try await Task.sleep(for: $0) }
    ) -> HerdrCoreSSHTransport {
        HerdrCoreSSHTransport(connection: self, session: session, nonce: { Self.nonce }, sleep: sleep)
    }
}
