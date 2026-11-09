import Foundation

/// The core cannot serve this app until it is updated. Never retried: the same
/// core gives the same answer until someone updates it on that machine.
struct HerdrCoreUpdateRequired: Error, Equatable, Sendable {
    /// What gave it away: an `error.data.kind`, or the failed `hello` check.
    let kind: String
}

/// What a framed `hello` reply says about the core. The version is advisory;
/// the generation and the features decide.
struct HerdrCoreServerInfo: Equatable, Sendable {
    static let requiredFeatures: Set<String> = ["framed", "attach", "events", "status"]
    /// Kinds that only an older core gives this app's requests. Every domain
    /// error shares one code, so these are told apart by `error.data.kind`.
    static let updateRequiredKinds: Set<String> = [
        "needs_framed", "unknown_method", "unsupported_generation",
    ]

    let version: String
    let generation: Int
    let features: Set<String>
    let coreID: String

    /// The plain line that switches a connection to frames. It never carries
    /// a `core` field, which would register the connection as a peer core.
    static func helloRequestLine(id: String) throws -> String {
        try HerdrCoreWire.requestLine(
            id: id, method: "hello",
            params: .object([
                "generation": .number(Double(HerdrCoreWire.generation)),
                "framed": .bool(true),
            ]))
    }

    /// A reply's result, with the kinds that mean an older core mapped to
    /// `HerdrCoreUpdateRequired`.
    static func result(from data: Data, id: String) throws -> JSONValue {
        do {
            return try HerdrCoreWire.result(from: data, id: id)
        } catch let error as HerdrAPIError where updateRequiredKinds.contains(error.code) {
            throw HerdrCoreUpdateRequired(kind: error.code)
        }
    }

    init(hello: JSONValue) throws {
        guard let generation = HerdrCoreWire.integer(hello["generation"]),
            generation == HerdrCoreWire.generation
        else { throw HerdrCoreUpdateRequired(kind: "generation") }
        guard case .array(let listed) = hello["features"] else {
            throw HerdrCoreUpdateRequired(kind: "features")
        }
        let features = Set(listed.compactMap(\.stringValue))
        guard Self.requiredFeatures.isSubset(of: features) else {
            throw HerdrCoreUpdateRequired(kind: "features")
        }
        guard hello["framed"] == .bool(true) else {
            throw HerdrCoreUpdateRequired(kind: "framed")
        }
        guard let coreID = hello["core"]?["id"]?.stringValue, !coreID.isEmpty else {
            throw TransportError.malformedResponse("herdr-core: The hello response has no core id.")
        }
        self.generation = generation
        self.features = features
        self.coreID = coreID
        version = hello["version"]?.stringValue ?? ""
    }
}

/// `server.status`, which answers on a framed channel 0 before any subscribe.
struct HerdrCoreServerStatus: Equatable, Sendable {
    let coreID: String
    let version: String
    let pid: Int
    let uptimeMilliseconds: Int
    let live: Int
    let finished: Int
    /// The `herdr-core hold` processes the core's Terminals run under, which
    /// start them with the hold's environment, not the core's: `holders[].pid`
    /// and `holder.pid`, each once, in that order. Empty until a first Terminal.
    let holderPIDs: [Int]

    init(result: JSONValue) throws {
        guard let coreID = result["core"]?["id"]?.stringValue,
            let pid = HerdrCoreWire.integer(result["pid"]),
            let uptime = HerdrCoreWire.integer(result["uptime_ms"])
        else {
            throw TransportError.malformedResponse("herdr-core: The server status has no core, pid or uptime.")
        }
        self.coreID = coreID
        self.pid = pid
        uptimeMilliseconds = uptime
        version = result["version"]?.stringValue ?? ""
        live = HerdrCoreWire.integer(result["live"]) ?? 0
        finished = HerdrCoreWire.integer(result["finished"]) ?? 0
        var holders: [JSONValue] = []
        if case .array(let listed) = result["holders"] { holders = listed }
        if let current = result["holder"] { holders.append(current) }
        var holderPIDs: [Int] = []
        for holder in holders {
            guard let pid = HerdrCoreWire.integer(holder["pid"]), pid > 0, !holderPIDs.contains(pid) else { continue }
            holderPIDs.append(pid)
        }
        self.holderPIDs = holderPIDs
    }
}
