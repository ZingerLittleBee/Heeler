import Foundation
import Testing

@testable import Heeler

@Suite struct HerdrCoreServerInfoTests {
    private let vectors = HerdrCoreVectorFile.shared

    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    private func hello(features: [String] = ["framed", "attach", "events", "status"], generation: Int = 1, framed: Bool = true) -> JSONValue {
        .object([
            "generation": .number(Double(generation)), "version": .string("0.1.13"),
            "core": .object(["id": .string("c1"), "name": .string("lab")]),
            "framed": .bool(framed), "methods": .array([]),
            "features": .array(features.map(JSONValue.string)), "future": .bool(true),
        ])
    }

    @Test func theEncodedHelloAsksForFramedGenerationOneAndNamesNoCore() throws {
        let line = try HerdrCoreServerInfo.helloRequestLine(id: "hello")
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        let request = try json(line)
        #expect(request["method"] == .string("hello"))
        #expect(request["id"] == .string("hello"))
        #expect(request["jsonrpc"] == .string("2.0"))
        #expect(request["params"]?["generation"] == .number(1))
        #expect(request["params"]?["framed"] == .bool(true))
        // A `core` field would register the connection as a peer core.
        #expect(request["params"]?["core"] == nil)
        #expect(request["params"]?["calls_you"] == nil)
    }

    @Test func theVectorHelloPassesTheGateAndNamesTheCore() throws {
        let reply = try HerdrCoreServerInfo.result(from: Data(vectors.hello.reply.utf8), id: "hello")
        let info = try HerdrCoreServerInfo(hello: reply)
        #expect(info.version == "0.1.13")
        #expect(info.generation == 1)
        #expect(info.coreID == "c0re1d")
        #expect(info.features == ["framed", "attach", "events", "status", "shell"])
    }

    @Test func aReplyMissingAnyRequiredFeatureReadsAsUpdateRequired() throws {
        for missing in ["framed", "attach", "events", "status"] {
            let features = ["framed", "attach", "events", "status"].filter { $0 != missing }
            #expect(throws: HerdrCoreUpdateRequired.self, "\(missing)") {
                try HerdrCoreServerInfo(hello: hello(features: features))
            }
        }
        _ = try HerdrCoreServerInfo(hello: hello())
    }

    @Test func anotherGenerationReadsAsUpdateRequired() {
        for generation in [0, 2] {
            #expect(throws: HerdrCoreUpdateRequired.self) {
                try HerdrCoreServerInfo(hello: hello(generation: generation))
            }
        }
    }

    @Test func aReplyThatStayedPlainReadsAsUpdateRequired() {
        #expect(throws: HerdrCoreUpdateRequired.self) {
            try HerdrCoreServerInfo(hello: hello(framed: false))
        }
    }

    @Test func aHelloWithoutACoreIdentityIsMalformed() {
        let reply: JSONValue = .object([
            "generation": .number(1), "version": .string("0.1.13"), "framed": .bool(true),
            "features": .array(["framed", "attach", "events", "status"].map(JSONValue.string)),
        ])
        #expect(throws: TransportError.self) { try HerdrCoreServerInfo(hello: reply) }
    }

    @Test(arguments: ["unknown-method", "needs-framed", "unsupported-generation"])
    func errorKindsThatMeanAnOlderCoreReadAsUpdateRequired(name: String) throws {
        let error = try vectors.error(name)
        #expect(throws: HerdrCoreUpdateRequired(kind: error.kind)) {
            try HerdrCoreServerInfo.result(from: Data(error.line.utf8), id: "1")
        }
    }

    @Test func kindsAreToldApartByTheDataKindNotTheSharedCode() throws {
        // Every domain error is -32000; `refused` shares its code with
        // `needs_framed` and must stay an ordinary API error.
        let error = try vectors.error("domain-error")
        #expect(throws: HerdrAPIError.self) {
            try HerdrCoreServerInfo.result(from: Data(error.line.utf8), id: "1")
        }
    }

    @Test func serverStatusDecodesFromTheVector() throws {
        let exchange = try vectors.exchange("server-status")
        let replyFrame = HerdrCoreVectorFile.bytes(hex: exchange.replyFrame)
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(replyFrame)
        let frame = try #require(try decoder.next())
        let result = try HerdrCoreServerInfo.result(from: frame.payload, id: "1")
        let status = try HerdrCoreServerStatus(result: result)
        #expect(status.coreID == "c0re1d")
        #expect(status.version == "0.1.13")
        #expect(status.pid == 31337)
        #expect(status.uptimeMilliseconds == 86_400_123)
        #expect(status.live == 2)
        #expect(status.finished == 1)
    }

    @Test func aStatusWithoutItsPidOrUptimeIsMalformed() {
        #expect(throws: TransportError.self) {
            try HerdrCoreServerStatus(result: .object(["version": .string("0.1.13")]))
        }
    }
}
