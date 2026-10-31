import Foundation

@testable import Heeler

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

    private final class NoServices: HostServices {}

    nonisolated let routeID: UUID? = nil
    nonisolated var hostServices: any HostServices { NoServices() }

    private let coreID: String
    /// What each subscribe answers. The last one repeats.
    private var subscribeResults: [JSONValue]
    private var bytes: Bytes?
    private var isSubscribeHeld = false
    private var heldSubscribes: [CheckedContinuation<Void, Never>] = []
    private var subscribeWaiters: [CheckedContinuation<Void, Never>] = []

    /// How many times the core was asked for its Terminals.
    private(set) var subscribeCount = 0
    private(set) var isClosed = false

    init(coreID: String = "c1", subscribeResults: [JSONValue]) {
        self.coreID = coreID
        self.subscribeResults = subscribeResults
    }

    var isConnected: Bool { !isClosed }

    func locate() async throws -> HerdrCoreLocator.Location {
        throw TransportError.hostFeatureUnavailable(feature: "locate")
    }

    func lastLocation() async -> HerdrCoreLocator.Location? { nil }

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

    func call(_ method: String, params: JSONValue, isMutation: Bool) async throws -> JSONValue {
        throw TransportError.hostFeatureUnavailable(feature: method)
    }

    func close() async throws {
        isClosed = true
        await bytes?.close()
    }

    // MARK: Driving it

    /// One line of the live subscription's events channel.
    func deliver(_ line: Data) async {
        await bytes?.push(line + Data([0x0A]))
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
