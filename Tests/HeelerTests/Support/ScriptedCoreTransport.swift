import Foundation
import Testing
import os

@testable import Heeler

/// What the desktop app keeps in its document, in its own JSON.
enum CoreDesktopJSON {
    static func block(_ terminal: String) -> JSONValue {
        .object([
            "id": .string("p-\(terminal)"), "type": .string("block"),
            "content": .object(["terminal": .string(terminal)]),
        ])
    }

    static func tab(_ id: String, name: String = "", terminals: [String] = []) -> JSONValue {
        .object([
            "id": .string(id), "name": .string(name),
            "root": .object([
                "id": .string(id), "type": .string("row"),
                "children": .array(terminals.map(block)),
            ]),
        ])
    }

    static func space(
        _ id: String, name: String = "", folder: String = "", tabs: [JSONValue]
    ) -> JSONValue {
        .object([
            "id": .string(id), "name": .string(name), "folder": .string(folder),
            "tabs": .array(tabs),
        ])
    }

    static func document(_ spaces: [JSONValue]) -> JSONValue {
        .object(["spaces": .array(spaces)])
    }
}

/// The Host's exec side for store tests: Checkouts, git commands, the home
/// directory and directory listings, recording every ask. Everything else keeps
/// the seam's refusal.
actor ScriptedCoreServices: HostServices {
    private var roots: [String: String]
    private var checkouts: [String: HostCheckout]
    private let home: String?
    private let platform: HostPlatform
    private var failure: (any Error)?
    private var gate: ScriptedTransportCallGate?

    private let listings: [String: RemoteDirectoryListing]

    /// The directories of each `checkouts` call.
    private(set) var checkoutCalls: [[String]] = []
    /// The path of each directory listing.
    private(set) var listedPaths: [String] = []
    /// Every git command, oldest first.
    private(set) var gitCommands: [GitCommand] = []
    private var gitAnswers: [[String]: Result<GitCommandResult, any Error>] = [:]
    private var gitObserver: (@Sendable (GitCommand) async -> Void)?

    /// `roots` name a directory's top level and nothing more. `checkouts` say
    /// which repository too.
    init(
        roots: [String: String] = [:], checkouts: [String: HostCheckout] = [:],
        home: String? = nil, platform: HostPlatform = .posix,
        listings: [String: RemoteDirectoryListing] = [:]
    ) {
        self.roots = roots
        self.checkouts = checkouts
        self.home = home
        self.platform = platform
        self.listings = listings
    }

    func hostPlatform() async throws -> HostPlatform { platform }

    /// What a command with exactly these arguments answers from now on. Others
    /// succeed with no output, as `show-ref` does not: it answers "no such branch".
    func setGitAnswer(_ answer: Result<GitCommandResult, any Error>, for arguments: [String]) {
        gitAnswers[arguments] = answer
    }

    /// Hears each git command as it runs, to see what had happened by then.
    func observeGit(_ observer: @escaping @Sendable (GitCommand) async -> Void) {
        gitObserver = observer
    }

    func runGitCommand(_ command: GitCommand) async throws -> GitCommandResult {
        gitCommands.append(command)
        await gitObserver?(command)
        if let answer = gitAnswers[command.arguments] { return try answer.get() }
        let status: Int32 = command.arguments.first == "show-ref" ? 1 : 0
        return GitCommandResult(status: status, output: "", message: nil)
    }

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        listedPaths.append(path)
        guard let listing = listings[path] else {
            throw TransportError.invalidDirectoryPath(path: path)
        }
        return listing
    }

    /// Every ask fails until this is called with nil.
    func setFailure(_ failure: (any Error)?) {
        self.failure = failure
    }

    func setRoots(_ roots: [String: String]) {
        self.roots = roots
    }

    /// Holds each ask, after it is recorded, until `gate` opens.
    func hold(using gate: ScriptedTransportCallGate?) {
        self.gate = gate
    }

    func checkouts(for directories: [String]) async throws -> [String: HostCheckout] {
        #expect(directories.count <= GitProbe.checkoutRootsPerCall)
        checkoutCalls.append(directories)
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        let named = roots.filter { directories.contains($0.key) }.mapValues { HostCheckout(root: $0) }
        return named.merging(checkouts.filter { directories.contains($0.key) }) { _, full in full }
    }

    func setCheckouts(_ checkouts: [String: HostCheckout]) {
        self.checkouts = checkouts
    }

    func hostHomeDirectory() async throws -> String {
        guard let home else { throw TransportError.hostFeatureUnavailable(feature: "Chat") }
        return home
    }
}

/// A herdr-core Host for store tests, as `ScriptedTransport` is for a Herdr TUI
/// one. It hands out real event streams fed from scrubbed log lines, so the line
/// buffer, the cursor and the address check above it are the real ones.
actor ScriptedCoreTransport: HerdrCoreTransport {
    /// The bytes of one subscription's events channel.
    private actor Bytes: HerdrCoreEventBytes {
        private var pending: [Data?] = []
        private var reader: CheckedContinuation<Data?, Never>?
        private var isClosed = false

        func push(_ bytes: Data?) {
            if let reader {
                self.reader = nil
                reader.resume(returning: bytes)
            } else {
                pending.append(bytes)
            }
        }

        func read() async throws -> Data? {
            if !pending.isEmpty { return pending.removeFirst() }
            if isClosed { return nil }
            return await withCheckedContinuation { reader = $0 }
        }

        func close() async {
            isClosed = true
            push(nil)
        }
    }

    nonisolated let routeID: UUID? = nil
    private nonisolated let services: any HostServices
    /// Each borrow of the Host's exec and SFTP services, from anything above.
    private let borrows = OSAllocatedUnfairLock(initialState: 0)
    nonisolated var hostServicesBorrows: Int { borrows.withLock { $0 } }
    nonisolated var hostServices: any HostServices {
        borrows.withLock { $0 += 1 }
        return services
    }
    private nonisolated let helper: ScriptedHelperHost
    nonisolated var hostHelperHost: any HostHelperHost { helper }

    private var coreID: String
    /// What each subscribe answers. The last one repeats.
    private var subscribeResults: [JSONValue]
    private var bytes: Bytes?
    private var isSubscribeHeld = false
    private var heldSubscribes: [CheckedContinuation<Void, Never>] = []
    private var subscribeWaiters: [CheckedContinuation<Void, Never>] = []
    private var documentValue: JSONValue = .null
    private var documentVersion = 0
    private var documentGate: ScriptedTransportCallGate?

    /// How many times the core was asked for its Terminals.
    private(set) var subscribeCount = 0
    private(set) var isClosed = false
    /// The name of each document read.
    private(set) var documentReads: [String] = []
    /// No code path writes a document. A write also fails the test that made it.
    private(set) var documentWrites: [JSONValue] = []
    /// The exact params of every `terminal.run`, oldest first.
    private(set) var runs: [JSONValue] = []
    /// How many of `runs` asked for a Template's long deadline.
    private(set) var templateRuns = 0
    /// The method of every call sent as a mutation, oldest first.
    private(set) var mutations: [String] = []
    /// The exact params of every `terminal.label`, oldest first.
    private(set) var labelWrites: [JSONValue] = []
    /// The Terminal of every `terminal.kill`, oldest first.
    private(set) var kills: [String] = []
    private var killAnswers: [String: Result<JSONValue, any Error>] = [:]
    private var killObserver: (@Sendable (String) async -> Void)?
    /// Each `terminal.interrupt` and `terminal.get`, with its params, oldest first.
    private(set) var stopCalls: [(method: String, params: JSONValue)] = []
    private var interruptAnswer: Result<JSONValue, any Error> = .success(
        .object(["outcome": .string("stopped"), "key": .string("esc")]))
    private var interruptHold: InterruptHold?
    private var heldInterrupts: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var terminalRecords: [Result<JSONValue, any Error>] = []
    private var isHoldingTerminalReads = false
    private var heldTerminalReads: [CheckedContinuation<Void, Never>] = []
    /// The script of every agent discovery, oldest first.
    private(set) var discoveryScripts: [String] = []
    private var shellFailure: (any Error)?
    private var runsTemplatesAsPrograms = false
    private var shell: String?
    private var discoveredPrograms: [String] = []
    private var openCodeVersionOutput: String?
    private var runFailure: (any Error)?
    private var heldNames: Set<String> = []
    private var templateList: JSONValue = .object(["templates": .array([])])
    private var templateListFailure: (any Error)?
    private var templateCommand = "pi --thinking high"
    private var isDesktopAppRunning = false
    private var desktopAppRenameFailure: (any Error)?

    struct DesktopAppRename: Equatable {
        let space: String
        let name: String
    }

    /// How many times `herdr-app status` ran.
    private(set) var desktopAppChecks = 0
    /// Every `herdr-app do space.rename`, oldest first, failed ones too.
    private(set) var desktopAppRenames: [DesktopAppRename] = []

    init(
        coreID: String = "c1", subscribeResults: [JSONValue],
        services: any HostServices = ScriptedCoreServices(),
        helper: ScriptedHelperHost = ScriptedHelperHost()
    ) {
        self.coreID = coreID
        self.subscribeResults = subscribeResults
        self.services = services
        self.helper = helper
    }

    var isConnected: Bool { !isClosed }

    func locate() async throws -> HerdrCoreLocator.Location {
        throw TransportError.hostFeatureUnavailable(feature: "locate")
    }

    func lastLocation() async -> HerdrCoreLocator.Location? {
        location
    }

    private var location: HerdrCoreLocator.Location?

    func setKernel(_ kernel: String) {
        location = HerdrCoreLocator.Location(
            kernel: kernel, executablePath: "/usr/bin/herdr-core", version: "0.1.13",
            socketPath: "/run/core.sock", socketSource: .lock, socketFilePresent: true,
            socketPathLimit: 107, loginShell: nil)
    }

    /// The Host's processes for `readProcesses`, which reads them as one exec.
    let processTable = ScriptedProcessTable()

    func readProcesses(
        _ request: HostProcessReader.Request
    ) async throws -> [String: HostProcessReader.Facts] {
        try await processTable.read(request)
    }

    /// What each process's environment answers, and every read asked for.
    private var processVariables: [String: HostProcessReader.Variable] = [:]
    private(set) var processVariableReads: [String] = []

    func setProcessVariable(_ name: String, to value: String) {
        processVariables[name] = .value(value)
    }

    /// The environment could not be read, which says nothing about the name.
    func makeProcessVariableUnavailable(_ name: String) {
        processVariables[name] = .unavailable
    }

    func processVariable(_ name: String, pid: Int) async -> HostProcessReader.Variable {
        processVariableReads.append("\(name) of \(pid)")
        return processVariables[name] ?? .unset
    }

    func startCore() async throws -> HerdrCoreStart.Outcome {
        throw TransportError.hostFeatureUnavailable(feature: "startCore")
    }

    func hello() async throws -> HerdrCoreServerInfo {
        try await helloAtLastLocation()
    }

    func helloAtLastLocation() async throws -> HerdrCoreServerInfo {
        try HerdrCoreServerInfo(
            hello: .object([
                "generation": .number(1), "version": .string("0.1.13"),
                "core": .object(["id": .string(coreID)]), "framed": .bool(true),
                "features": .array(["framed", "attach", "events", "status", "shell"].map(JSONValue.string)),
            ]))
    }

    func serverStatus() async throws -> HerdrCoreServerStatus {
        try HerdrCoreServerStatus(
            result: .object([
                "core": .object(["id": .string(coreID)]), "pid": .number(1), "uptime_ms": .number(1),
            ]))
    }

    func leakedEnvironmentNames() async -> Set<String>? {
        while isHoldingLeakAnswers {
            await withCheckedContinuation { heldLeakAnswers.append($0) }
        }
        return leakedEnvironment
    }

    private var leakedEnvironment: Set<String> = []
    private var isHoldingLeakAnswers = false
    private var heldLeakAnswers: [CheckedContinuation<Void, Never>] = []

    func setLeakedEnvironment(_ names: Set<String>) {
        leakedEnvironment = names
    }

    /// The leak check takes as long as the test says, so a check of the Agent's
    /// process can come first.
    func holdLeakAnswers() {
        isHoldingLeakAnswers = true
    }

    func releaseLeakAnswers() {
        isHoldingLeakAnswers = false
        let held = heldLeakAnswers
        heldLeakAnswers = []
        for answer in held { answer.resume() }
    }

    func subscribeEvents() async throws -> HerdrCoreEventStream {
        subscribeCount += 1
        let waiters = subscribeWaiters
        subscribeWaiters = []
        for waiter in waiters { waiter.resume() }
        while isSubscribeHeld {
            await withCheckedContinuation { heldSubscribes.append($0) }
        }
        let result = subscribeResults.count > 1 ? subscribeResults.removeFirst() : subscribeResults[0]
        let source = Bytes()
        bytes = source
        return HerdrCoreEventStream(
            snapshot: try HerdrCoreSnapshot(result: result), coreID: coreID, source: source)
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        throw TransportError.hostFeatureUnavailable(feature: "terminal.attach")
    }

    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue {
        if isMutation { mutations.append(method) }
        switch method {
        case "terminal.interrupt":
            stopCalls.append((method, params))
            if let hold = interruptHold { try await waitOutInterruptHold(hold) }
            return try interruptAnswer.get()
        case "terminal.get":
            stopCalls.append((method, params))
            while isHoldingTerminalReads {
                await withCheckedContinuation { heldTerminalReads.append($0) }
            }
            guard !terminalRecords.isEmpty else {
                throw TransportError.hostFeatureUnavailable(feature: method)
            }
            return try (terminalRecords.count > 1 ? terminalRecords.removeFirst() : terminalRecords[0]).get()
        case "terminal.kill":
            let terminal = params["terminal"]?.stringValue ?? ""
            kills.append(terminal)
            await killObserver?(terminal)
            return try (killAnswers[terminal] ?? .success(Self.killReply(address: terminal))).get()
        case "doc.get":
            documentReads.append(params["name"]?.stringValue ?? "")
            let answer: JSONValue = .object([
                "value": documentValue, "version": .number(Double(documentVersion)),
            ])
            if let documentGate { await documentGate.waitUntilOpen() }
            return answer
        case "doc.set":
            documentWrites.append(params)
            Issue.record("A code path wrote a document: \(params)")
            throw TransportError.hostFeatureUnavailable(feature: method)
        case "templates.list":
            if let templateListFailure { throw templateListFailure }
            return templateList
        case "terminal.label":
            labelWrites.append(params)
            return .null
        default:
            throw TransportError.hostFeatureUnavailable(feature: method)
        }
    }

    func launchShell() async throws -> String {
        if let shellFailure { throw shellFailure }
        guard let shell else {
            throw TransportError.hostFeatureUnavailable(feature: "Starting an Agent")
        }
        return shell
    }

    /// Prints as the real script does, with its nonce and whatever a startup
    /// file might print ahead of it.
    func runAgentDiscovery(_ script: Data) async throws -> GitExecResult {
        let body = String(decoding: script, as: UTF8.self)
        discoveryScripts.append(body)
        let marker = "__HEELER_AGENTS_BEGIN_"
        let nonce =
            body.range(of: marker).map { body[$0.upperBound...].prefix { $0.isHexDigit } } ?? ""
        let lines =
            ["welcome from the rc", "", "\(marker)\(nonce)"]
            + discoveredPrograms.map { "agent \($0)" }
            + ["version \(openCodeVersionOutput ?? "")", "", "__HEELER_AGENTS_END_\(nonce)"]
        return GitExecResult(
            stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: Data(), exitStatus: 0)
    }

    func runTerminal(params: JSONValue) async throws -> JSONValue {
        runs.append(params)
        if let runFailure { throw runFailure }
        try holdName(in: params)
        return Self.runReply(address: "t\(100 + runs.count)", params: params)
    }

    /// The core's rule for a name a live Terminal holds. Every Terminal started
    /// here stays live as far as this knows.
    private func holdName(in params: JSONValue) throws {
        guard let name = params["name"]?.stringValue else { return }
        guard heldNames.insert(name).inserted else {
            throw HerdrAPIError(
                code: "name_taken", message: "a live terminal is already named \"\(name)\"")
        }
    }

    /// What a core answers for a Template: its command under `sh -c`, with its
    /// name and keys on the record.
    func runTemplate(params: JSONValue) async throws -> JSONValue {
        templateRuns += 1
        runs.append(params)
        if let runFailure { throw runFailure }
        try holdName(in: params)
        var reply = Self.runReply(address: "t\(100 + runs.count)", params: params)
        if case .object(var fields) = reply {
            fields["argv"] = .array(["sh", "-c", templateCommand].map(JSONValue.string))
            if !runsTemplatesAsPrograms, case .array(let argv)? = params["argv"] {
                fields["template"] = argv.first
            }
            fields["submit"] = .string("ctrl+j")
            fields["stop"] = .string("ctrl+c")
            reply = .object(fields)
        }
        return reply
    }

    /// What a core answers: the Terminal it started from these params.
    private static func runReply(address: String, params: JSONValue) -> JSONValue {
        .object([
            "address": .string(address), "cwd": params["cwd"] ?? .string("/"), "state": .string("live"),
            "argv": params["argv"] ?? .array([.string("/bin/zsh")]),
            "keep": params["keep"] ?? .bool(false), "title": .string(""),
            "name": params["name"] ?? .null, "labels": params["labels"] ?? .object([:]),
            "cols": .number(80), "rows": .number(24), "pid": .number(4000),
        ])
    }

    func desktopAppIsRunning() async -> Bool {
        desktopAppChecks += 1
        return isDesktopAppRunning
    }

    func renameDesktopSpace(_ space: String, name: String) async throws {
        desktopAppRenames.append(DesktopAppRename(space: space, name: name))
        if let desktopAppRenameFailure { throw desktopAppRenameFailure }
    }

    /// What a core answers a kill: the record, already ended.
    private static func killReply(address: String) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/"), "state": .string("finished"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(true), "title": .string(""),
            "labels": .object([:]), "cols": .number(80), "rows": .number(24),
            "reason": .string("killed"), "signal": .number(1),
        ])
    }

    func close() async throws {
        isClosed = true
        await bytes?.close()
    }

    // MARK: Driving it

    /// The shell a launch goes through. Nil: the Host says none.
    func setShell(_ shell: String?) {
        self.shell = shell
    }

    /// Asking for the login shell fails with this until it is called with nil.
    func setShellFailure(_ failure: (any Error)?) {
        shellFailure = failure
    }

    /// What discovery finds through the interactive shell: the programs it can
    /// run, and what OpenCode's `--version` prints.
    func setDiscovery(programs: [String], openCodeVersion: String? = nil) {
        discoveredPrograms = programs
        openCodeVersionOutput = openCodeVersion
    }

    /// Every run fails with this until it is called with nil.
    func setRunFailure(_ failure: (any Error)?) {
        runFailure = failure
    }

    /// What `templates.list` answers, as the core shapes it.
    func setTemplates(_ templates: [JSONValue]) {
        templateList = .object(["templates": .array(templates)])
    }

    /// The command line a Template's Terminal runs.
    func setTemplateCommand(_ command: String) {
        templateCommand = command
    }

    /// The Template's file went after the list was read: `argv` runs as a program
    /// of that name and the record names no Template.
    func runTemplatesAsPrograms() {
        runsTemplatesAsPrograms = true
    }

    /// `templates.list` fails with this until it is called with nil.
    func setTemplateListFailure(_ failure: (any Error)?) {
        templateListFailure = failure
    }

    /// What `herdr-app status` says from now on.
    func setDesktopApp(running: Bool) {
        isDesktopAppRunning = running
    }

    /// Every rename fails with this until it is called with nil.
    func setDesktopAppRenameFailure(_ failure: (any Error)?) {
        desktopAppRenameFailure = failure
    }

    /// What a kill of this Terminal gets back instead of its ended record.
    func setKillAnswer(_ answer: Result<JSONValue, any Error>, for terminal: String) {
        killAnswers[terminal] = answer
    }

    /// Hears each kill before it is answered, while the caller still waits on it.
    func observeKill(_ observer: @escaping @Sendable (String) async -> Void) {
        killObserver = observer
    }

    /// What `terminal.interrupt` gets back.
    func setInterruptAnswer(_ answer: Result<JSONValue, any Error>) {
        interruptAnswer = answer
    }

    /// Where a held `terminal.interrupt` is, which decides what cancelling it does,
    /// as `HerdrCoreLink` and `HerdrCoreTransport.onLink` do.
    enum InterruptHold {
        /// With the writer or past it: cancelling says the outcome is unknown.
        case handedToTheWriter
        /// Queued behind other writes: cancelling drops it, and it never goes.
        case inTheOutbox
        /// Waiting for a link to open, which cancelling does not end. Once it
        /// ends, the cancelled call writes nothing.
        case awaitingALink
    }

    /// Each `terminal.interrupt` waits, answerless, until `releaseInterrupts`.
    func holdInterrupts(_ hold: InterruptHold = .handedToTheWriter) {
        interruptHold = hold
    }

    func releaseInterrupts() {
        interruptHold = nil
        let held = heldInterrupts
        heldInterrupts = [:]
        for waiter in held.values { waiter.resume() }
    }

    private func waitOutInterruptHold(_ hold: InterruptHold) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hold != .awaitingALink, Task.isCancelled {
                    continuation.resume()
                } else {
                    heldInterrupts[id] = continuation
                }
            }
        } onCancel: {
            if hold != .awaitingALink { Task { await self.releaseInterrupt(id) } }
        }
        guard Task.isCancelled else { return }
        if hold == .handedToTheWriter { throw TransportError.coreMutationOutcomeUnknown }
        throw CancellationError()
    }

    private func releaseInterrupt(_ id: UUID) {
        heldInterrupts.removeValue(forKey: id)?.resume()
    }

    /// What each `terminal.get` answers. The last one repeats.
    func setTerminalRecords(_ answers: [Result<JSONValue, any Error>]) {
        terminalRecords = answers
    }

    /// Each `terminal.get` waits, answerless, until `releaseTerminalReads`.
    func holdTerminalReads() {
        isHoldingTerminalReads = true
    }

    func releaseTerminalReads() {
        isHoldingTerminalReads = false
        let held = heldTerminalReads
        heldTerminalReads = []
        for waiter in held { waiter.resume() }
    }

    /// What the next document read answers, as `doc.get` shapes it.
    func setDocument(_ value: JSONValue, version: Int) {
        documentValue = value
        documentVersion = version
    }

    /// Holds each document read, with what it read already decided, until
    /// `gate` opens. Nil lets them through.
    func holdDocumentReads(using gate: ScriptedTransportCallGate?) {
        documentGate = gate
    }

    /// One line of the live subscription's events channel.
    func deliver(_ line: Data) async {
        await bytes?.push(line + Data([0x0A]))
    }

    /// What the next `hello` reports, as a core whose state was wiped does.
    func setCoreID(_ coreID: String) {
        self.coreID = coreID
    }

    /// The subscription's channel ends with the connection still up, as a core
    /// going away does: the session says `hello` and subscribes again.
    func endLink() async {
        await bytes?.push(nil)
    }

    /// Subscribes wait, for the window between Connected and the first snapshot.
    func holdSubscribes() {
        isSubscribeHeld = true
    }

    func releaseSubscribes() {
        isSubscribeHeld = false
        let held = heldSubscribes
        heldSubscribes = []
        for waiter in held { waiter.resume() }
    }

    func waitForSubscribe(count: Int) async {
        while subscribeCount < count {
            await withCheckedContinuation { subscribeWaiters.append($0) }
        }
    }
}
