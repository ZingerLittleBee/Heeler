import Foundation
import Testing

@testable import Heeler

@Suite struct HerdrCoreWireTests {
    @Test func requestsAreJSONRPCAndKeepPromptTextInJSON() throws {
        let prompt = "quote: '\"; $(touch never)\nsecond line"
        let line = try HerdrCoreWire.requestLine(
            id: "request", method: "terminal.send",
            params: .object(["terminal": .string("t3"), "text": .string(prompt)]))
        #expect(line.last == "\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
        let decoded = try json(line)
        #expect(decoded["jsonrpc"] == .string("2.0"))
        #expect(decoded["id"] == .string("request"))
        #expect(decoded["params"]?["text"] == .string(prompt))
    }

    @Test func responsesRequireTheRightProtocolAndRequestIdentity() throws {
        let good = #"{"jsonrpc":"2.0","id":"request","result":{"future":true}}"#
        #expect(try HerdrCoreWire.result(from: Data(good.utf8), id: "request") == .object(["future": .bool(true)]))
        for bad in [
            #"{"id":"request","result":{}}"#,
            #"{"jsonrpc":"2.0","id":"other","result":{}}"#,
            #"{"jsonrpc":"2.0","id":"request"}"#,
            "not JSON",
        ] {
            #expect(throws: TransportError.self) {
                try HerdrCoreWire.result(from: Data(bad.utf8), id: "request")
            }
        }
    }

    @Test func coreErrorKindsAndRecoveryHintsSurvive() throws {
        let line = #"{"jsonrpc":"2.0","id":"request","error":{"code":-32000,"message":"program blocked","data":{"kind":"blocked","hint":"Inspect its prompt."}}}"#
        #expect(throws: HerdrAPIError(code: "blocked", message: "program blocked Inspect its prompt.")) {
            try HerdrCoreWire.result(from: Data(line.utf8), id: "request")
        }
    }

    @Test func replyIDsComeOnlyFromReplies() {
        #expect(HerdrCoreWire.responseID(from: Data(#"{"jsonrpc":"2.0","id":"7","result":{}}"#.utf8)) == "7")
        #expect(HerdrCoreWire.responseID(from: Data(#"{"jsonrpc":"2.0","id":"8","error":{"code":-32000,"message":"no"}}"#.utf8)) == "8")
        for notReply in [
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":1}}"#,
            #"{"jsonrpc":"2.0","id":"9","method":"$/orphaned","params":{}}"#,
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}}"#,
            #"{"jsonrpc":"2.0","id":3,"result":{}}"#,
            "not JSON",
        ] {
            #expect(HerdrCoreWire.responseID(from: Data(notReply.utf8)) == nil, "\(notReply)")
        }
    }

    /// Addresses are opaque inside JSON. Only the two that name no local
    /// Terminal are refused; the old command builder's other rules guarded a
    /// CLI argv that no frame needs.
    @Test func theAddressCheckRefusesOnlyTheEmptyAddressAndAFederatedOne() throws {
        for address in ["", "other/t1"] {
            #expect(throws: TransportError.self, "\(address)") { try HerdrCoreWire.address(address) }
        }
        for address in ["t1", "-x", "t1 t2", "東京"] {
            #expect(try HerdrCoreWire.address(address) == address)
        }
    }

    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }
}

@Suite struct CoreMutationDispatchTests {
    @Test func aDeadlineSealsDispatchBeforeALateChannelCanWrite() async throws {
        let dispatch = CoreMutationDispatch()
        #expect(await dispatch.seal() == false)
        await #expect(throws: TransportError.cancelled) { try await dispatch.begin() }
        #expect(await dispatch.seal() == false)
        let written = CoreMutationDispatch()
        try await written.begin()
        #expect(await written.seal())
        await #expect(throws: TransportError.cancelled) { try await written.begin() }
    }

    @Test func aCancelledContinuationCannotBeginAMutation() async {
        let dispatch = CoreMutationDispatch()
        let operation = Task {
            // Simulate an underlying channel open that ignores cancellation.
            try? await Task.sleep(for: .seconds(1))
            try await dispatch.begin()
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await dispatch.seal() == false)
    }
}
