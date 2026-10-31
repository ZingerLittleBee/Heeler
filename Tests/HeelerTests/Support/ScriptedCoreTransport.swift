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

/// The Host's exec side for store tests: checkout roots, the home directory and
/// directory listings, recording every ask. Everything else keeps the seam's
/// refusal.
actor ScriptedCoreServices: HostServices {
    private var roots: [String: String]
    private let home: String?
    private var failure: (any Error)?
    private var gate: ScriptedTransportCallGate?

    private let listings: [String: RemoteDirectoryListing]

    /// The directories of each `checkoutRoots` call.
    private(set) var checkoutCalls: [[String]] = []
    /// The path of each directory listing.
    private(set) var listedPaths: [String] = []

    init(
        roots: [String: String] = [:], home: String? = nil,
        listings: [String: RemoteDirectoryListing] = [:]
    ) {
        self.roots = roots
        self.home = home
        self.listings = listings
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

    func checkoutRoots(for directories: [String]) async throws -> [String: String] {
        #expect(directories.count <= GitProbe.checkoutRootsPerCall)
        checkoutCalls.append(directories)
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        return roots.filter { directories.contains($0.key) }
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
    nonisolated var hostHelperHost: any HostHelperHost { ScriptedHelperHost() }

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
    /// The script of every agent discovery, oldest first.
    private(set) var discoveryScripts: [String] = []
    private var shell: String?
    private var discoveredPrograms: [String] = []
    private var openCodeVersionOutput: String?
    private var runFailure: (any Error)?

    init(
        coreID: String = "c1", subscribeResults: [JSONValue],
        services: any HostServices = ScriptedCoreServices()
    ) {
        self.coreID = coreID
        self.subscribeResults = subscribeResults
        self.services = services
    }

    var isConnected: Bool { !isClosed }

    func locate() async throws -> HerdrCoreLocator.Location {
        throw TransportError.hostFeatureUnavailable(feature: "locate")
    }

    func lastLocation() async -> HerdrCoreLocator.Location? { nil }

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

    func leakedEnvironmentNames() async -> Set<String>? { [] }

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
        return HerdrCoreEventStream(snapshot: try HerdrCoreSnapshot(result: result), source: source)
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        throw TransportError.hostFeatureUnavailable(feature: "terminal.attach")
    }

    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue {
        switch method {
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
        default:
            throw TransportError.hostFeatureUnavailable(feature: method)
        }
    }

    func launchShell() async throws -> String {
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
        return Self.runReply(address: "t\(100 + runs.count)", params: params)
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

    func close() async throws {
        isClosed = true
        await bytes?.close()
    }

    // MARK: Driving it

    /// The shell a launch goes through. Nil: the Host says none.
    func setShell(_ shell: String?) {
        self.shell = shell
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
