import Foundation
import Testing

@testable import Heeler

private let helloResult: JSONValue = .object([
    "generation": .number(1), "version": .string("0.1.13"),
    "core": .object(["id": .string("c1"), "name": .string("lab")]),
    "framed": .bool(true), "methods": .array([]),
    "features": .array(["framed", "attach", "events", "status", "shell"].map(JSONValue.string)),
])

private func plainHelloReply(result: JSONValue = helloResult) throws -> Data {
    try JSONEncoder().encode(JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .string("hello"), "result": result,
    ])) + Data([0x0A])
}

/// A link connected to a fake core on a manual clock.
private struct Harness {
    let socket = FakeCoreSocket()
    let clock = ManualClock()
    let link: HerdrCoreLink

    init(firstBytesAfterHello: Data = Data()) async throws {
        let socket = socket
        let clock = clock
        let connected = Task { try await HerdrCoreLink.connect(over: socket, sleep: clock.parkedSleep(for:)) }
        _ = await socket.nextWrittenLine()
        await socket.deliver(try plainHelloReply() + firstBytesAfterHello)
        link = try await connected.value.link
    }

    /// Opens a stream whose reply names `channel`.
    func openStream(channel: UInt32, method: String = "terminal.attach") async throws -> HerdrCoreLinkStream {
        let opened = Task { try await link.openStream(method, params: .object(["terminal": .string("t1")]), deadline: .seconds(5)) }
        let request = await socket.nextRequest()
        try await socket.reply(to: request.id, result: .object(["channel": .number(Double(channel))]))
        return try await opened.value.stream
    }

    /// Returns once everything delivered so far has been ingested and every
    /// frame the client queued because of it has reached the socket: the
    /// first call's reply follows the delivered bytes on the wire, and the
    /// second call's request follows anything queued before it.
    func settle() async throws {
        for _ in 0..<2 {
            let done = Task { try await link.call("server.status", deadline: .seconds(5)) }
            let request = await socket.nextRequest()
            try await socket.reply(to: request.id)
            _ = try await done.value
        }
    }
}

private func data(_ text: String) -> Data { Data(text.utf8) }

private func dataFrame(_ channel: UInt32, _ text: String) -> HerdrCoreFrame {
    HerdrCoreFrame(channel: channel, kind: .data, payload: data(text))
}

@Suite("HerdrCoreLink", .timeLimit(.minutes(1)))
struct HerdrCoreLinkTests {
    // MARK: Hello

    @Test func helloIsOnePlainLineAskingForFramedWithNoCore() async throws {
        let socket = FakeCoreSocket()
        let clock = ManualClock()
        let connected = Task { try await HerdrCoreLink.connect(over: socket, sleep: clock.parkedSleep(for:)) }
        let line = await socket.nextWrittenLine()
        let request = try JSONDecoder().decode(JSONValue.self, from: line)
        #expect(request["method"] == .string("hello"))
        #expect(request["params"]?["generation"] == .number(1))
        #expect(request["params"]?["framed"] == .bool(true))
        #expect(request["params"]?["core"] == nil)
        await socket.deliver(try plainHelloReply())
        let (link, info) = try await connected.value
        #expect(info.coreID == "c1")
        await link.close()
        #expect(await socket.isClosed)
    }

    @Test func aHelloMissingAFeatureReadsAsUpdateRequiredAndClosesTheChannel() async throws {
        let socket = FakeCoreSocket()
        let clock = ManualClock()
        let connected = Task { try await HerdrCoreLink.connect(over: socket, sleep: clock.parkedSleep(for:)) }
        _ = await socket.nextWrittenLine()
        let result: JSONValue = .object([
            "generation": .number(1), "framed": .bool(true),
            "core": .object(["id": .string("c1")]),
            "features": .array(["framed", "attach", "events"].map(JSONValue.string)),
        ])
        await socket.deliver(try plainHelloReply(result: result))
        await #expect(throws: HerdrCoreUpdateRequired(kind: "features")) { try await connected.value }
        #expect(await socket.isClosed)
    }

    @Test func aHelloRefusedByKindReadsAsUpdateRequired() async throws {
        let socket = FakeCoreSocket()
        let clock = ManualClock()
        let connected = Task { try await HerdrCoreLink.connect(over: socket, sleep: clock.parkedSleep(for:)) }
        _ = await socket.nextWrittenLine()
        let line = HerdrCoreVectorFile.shared.errors.first { $0.kind == "unsupported_generation" }?.line ?? ""
        await socket.deliver(data(line.replacingOccurrences(of: #""id":"1""#, with: #""id":"hello""#) + "\n"))
        await #expect(throws: HerdrCoreUpdateRequired(kind: "unsupported_generation")) { try await connected.value }
        #expect(await socket.isClosed)
    }

    @Test func aHelloThatNeverAnswersTimesOutAndClosesTheChannel() async throws {
        let socket = FakeCoreSocket()
        let clock = ManualClock()
        let connected = Task { try await HerdrCoreLink.connect(
            over: socket, helloDeadline: .seconds(10), sleep: clock.parkedSleep(for:)) }
        _ = await socket.nextWrittenLine()
        await clock.untilParked(1)
        clock.advance(.seconds(10))
        await #expect(throws: TransportError.timedOut) { try await connected.value }
        #expect(await socket.isClosed)
    }

    @Test func aFrameInTheSameReadAsTheHelloReplyIsKept() async throws {
        let early = try dataFrame(1, "early paint").encoded()
        let harness = try await Harness(firstBytesAfterHello: early)
        let stream = try await harness.openStream(channel: 1)
        #expect(try await stream.read() == data("early paint"))
    }

    @Test func aReadPollThatTimesOutIsNotAFailure() async throws {
        let harness = try await Harness()
        await harness.socket.deliverReadTimeout()
        try await harness.settle()
        #expect(await !harness.socket.isClosed)
    }

    // MARK: Channel-0 calls

    @Test func repliesOutOfOrderMatchTheirCalls() async throws {
        let harness = try await Harness()
        let first = Task { try await harness.link.call("first", deadline: .seconds(5)) }
        let firstRequest = await harness.socket.nextRequest()
        let second = Task { try await harness.link.call("second", deadline: .seconds(5)) }
        let secondRequest = await harness.socket.nextRequest()
        #expect(firstRequest.method == "first")
        #expect(secondRequest.method == "second")
        try await harness.socket.reply(to: secondRequest.id, result: .string("answer two"))
        #expect(try await second.value == .string("answer two"))
        try await harness.socket.reply(to: firstRequest.id, result: .string("answer one"))
        #expect(try await first.value == .string("answer one"))
    }

    @Test func aRequestFrameCarriesOneJSONMessageWithNoNewline() async throws {
        let harness = try await Harness()
        let done = Task { try await harness.link.call("server.status", deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        let frame = try #require(await harness.socket.frames(channel: 0, kind: .data).first)
        #expect(frame.payload.last != 0x0A)
        try await harness.socket.reply(to: request.id)
        _ = try await done.value
    }

    @Test func aTimedOutCallLeavesTheLinkUpAndDropsItsLateReply() async throws {
        let harness = try await Harness()
        let slow = Task { try await harness.link.call("slow", deadline: .seconds(3)) }
        let slowRequest = await harness.socket.nextRequest()
        await harness.clock.untilParked(1)
        harness.clock.advance(.seconds(3))
        await #expect(throws: TransportError.timedOut) { try await slow.value }

        try await harness.socket.reply(to: slowRequest.id, result: .string("too late"))
        let next = Task { try await harness.link.call("next", deadline: .seconds(3)) }
        let nextRequest = await harness.socket.nextRequest()
        try await harness.socket.reply(to: nextRequest.id, result: .string("on time"))
        #expect(try await next.value == .string("on time"))
        #expect(await !harness.socket.isClosed)
    }

    @Test func eachCallHasItsOwnDeadline() async throws {
        let harness = try await Harness()
        let short = Task { try await harness.link.call("short", deadline: .seconds(1)) }
        _ = await harness.socket.nextRequest()
        let long = Task { try await harness.link.call("long", deadline: .seconds(40)) }
        let longRequest = await harness.socket.nextRequest()
        await harness.clock.untilParked(2)
        harness.clock.advance(.seconds(2))
        await #expect(throws: TransportError.timedOut) { try await short.value }
        try await harness.socket.reply(to: longRequest.id, result: .string("still waiting"))
        #expect(try await long.value == .string("still waiting"))
    }

    @Test func aCancelledCallIsRemovedAndItsLateReplyDropped() async throws {
        let harness = try await Harness()
        let call = Task { try await harness.link.call("cancelled", deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        try await harness.socket.reply(to: request.id)
        try await harness.settle()
        #expect(await !harness.socket.isClosed)
    }

    @Test func concurrentSendsNeverInterleaveBytes() async throws {
        let harness = try await Harness()
        let socket = harness.socket
        let link = harness.link
        let count = 40
        let answered = Task {
            for _ in 0..<count {
                let request = await socket.nextRequest()
                try await socket.reply(to: request.id, result: request.params)
            }
        }
        // Large enough that each frame spans the fake's mid-write yield.
        let results = try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
            for index in 0..<count {
                group.addTask {
                    let params: JSONValue = .object([
                        "index": .number(Double(index)),
                        "text": .string(String(repeating: "x", count: 4096)),
                    ])
                    return (index, try await link.call("echo", params: params, deadline: .seconds(5)))
                }
            }
            var results: [Int: JSONValue] = [:]
            for try await (index, value) in group { results[index] = value }
            return results
        }
        try await answered.value
        #expect(results.count == count)
        for (index, value) in results { #expect(value["index"] == .number(Double(index))) }
        // The socket decoded every byte: one interleaved header would have
        // desynchronized it into a refusal or a frame that is not JSON.
        #expect(await socket.writeFailure == nil)
        #expect(await socket.requestCount() == count)
    }

    @Test func aCallAfterTeardownThrowsWithoutWriting() async throws {
        let harness = try await Harness()
        await harness.socket.deliverEndOfFile()
        await harness.socket.waitUntilClosed()
        await #expect(throws: TransportError.self) {
            try await harness.link.call("late", deadline: .seconds(5))
        }
        #expect(await harness.socket.requestCount() == 0)
    }

    @Test func serverStatusAnswersOnChannelZeroBeforeAnySubscribe() async throws {
        let harness = try await Harness()
        let exchange = try HerdrCoreVectorFile.shared.exchange("server-status")
        let status = Task { try await harness.link.serverStatus(deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        #expect(request.method == "server.status")
        try await harness.socket.reply(to: request.id, result: exchange.result)
        #expect(try await status.value.pid == 31337)
    }

    @Test func anOlderCoresUnknownMethodReadsAsUpdateRequired() async throws {
        let harness = try await Harness()
        let call = Task { try await harness.link.call("future.method", deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        try await harness.socket.replyError(to: request.id, kind: "unknown_method")
        await #expect(throws: HerdrCoreUpdateRequired(kind: "unknown_method")) { try await call.value }
        #expect(await !harness.socket.isClosed)
    }

    // MARK: Early frames and credit

    @Test func earlyStreamFramesAreKeptUpToTheirCredit() async throws {
        let harness = try await Harness()
        let opened = Task { try await harness.link.openStream(
            "terminal.attach", params: .object(["terminal": .string("t1")]), deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        // The paint is on the wire before its reply, and fills the whole window.
        let chunk = String(repeating: "a", count: 16 * 1024)
        for _ in 0..<(HerdrCoreFrame.initialCredit / chunk.utf8.count) {
            try await harness.socket.deliver(dataFrame(1, chunk))
        }
        try await harness.socket.reply(to: request.id, result: .object(["channel": .number(1)]))
        let stream = try await opened.value.stream
        var received = 0
        while received < HerdrCoreFrame.initialCredit {
            received += try #require(try await stream.read()).count
        }
        #expect(received == HerdrCoreFrame.initialCredit)
    }

    @Test func framesPastTheCreditTearTheLinkDown() async throws {
        let harness = try await Harness()
        let chunk = String(repeating: "a", count: HerdrCoreFrame.initialCredit)
        try await harness.socket.deliver(dataFrame(1, chunk))
        try await harness.socket.deliver(dataFrame(1, "b"))
        await harness.socket.waitUntilClosed()
    }

    @Test func tooManyChannelsNobodyAskedForTearTheLinkDown() async throws {
        let harness = try await Harness()
        for channel in 1...UInt32(HerdrCoreLink.maximumUnclaimedChannels + 1) {
            try await harness.socket.deliver(dataFrame(channel, "x"))
        }
        await harness.socket.waitUntilClosed()
    }

    @Test func creditLeavesOnlyAfterTheConsumerReadsBytes() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        try await harness.socket.deliver(dataFrame(1, "hello"))
        try await harness.socket.deliver(dataFrame(1, "world!"))
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 1, kind: .credit).isEmpty)

        #expect(try await stream.read() == data("hello"))
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 1, kind: .credit).map(\.payload) == [Data([5, 0, 0, 0])])

        #expect(try await stream.read() == data("world!"))
        await harness.socket.waitForCredit(channel: 1, total: 11)
    }

    @Test func aParkedReaderReturnsCreditForWhatItIsHanded() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        let read = Task { try await stream.read() }
        try await harness.socket.deliver(dataFrame(1, "abc"))
        #expect(try await read.value == data("abc"))
        await harness.socket.waitForCredit(channel: 1, total: 3)
    }

    @Test func aStalledStreamNeverHoldsUpCallsOrOtherStreams() async throws {
        let harness = try await Harness()
        let stalled = try await harness.openStream(channel: 1)
        let moving = try await harness.openStream(channel: 2)
        try await harness.socket.deliver(dataFrame(1, String(repeating: "s", count: HerdrCoreFrame.initialCredit)))
        try await harness.socket.deliver(dataFrame(2, "still moving"))
        #expect(try await moving.read() == data("still moving"))
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 1, kind: .credit).isEmpty)
        _ = stalled
    }

    // MARK: Closing channels

    @Test func aServerCloseEndsThatChannelOnly() async throws {
        let harness = try await Harness()
        let ended = try await harness.openStream(channel: 1)
        let other = try await harness.openStream(channel: 2)
        try await harness.socket.deliver(dataFrame(1, "last screen"))
        try await harness.socket.deliver(
            HerdrCoreFrame(channel: 1, kind: .close, payload: data(#"{"reason":"exited"}"#)))
        try await harness.socket.deliver(dataFrame(2, "other output"))

        #expect(try await ended.read() == data("last screen"))
        #expect(try await ended.read() == nil)
        #expect(try await ended.read() == nil)
        #expect(try await other.read() == data("other output"))
        try await harness.settle()
        #expect(await !harness.socket.isClosed)
        // The core already forgot the channel: closing it back would only earn a stray CLOSE.
        await ended.close()
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 1, kind: .close).isEmpty)
    }

    @Test func aServerCloseWakesAParkedReader() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        let read = Task { try await stream.read() }
        try await harness.settle()
        try await harness.socket.deliver(HerdrCoreFrame(channel: 1, kind: .close))
        #expect(try await read.value == nil)
    }

    @Test func aChannelClosedBeforeItsReplyStillDeliversItsBytesThenEnds() async throws {
        let harness = try await Harness()
        let opened = Task { try await harness.link.openStream(
            "terminal.attach", params: .object(["terminal": .string("t1")]), deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        try await harness.socket.deliver(dataFrame(1, "paint"))
        try await harness.socket.deliver(HerdrCoreFrame(channel: 1, kind: .close))
        try await harness.socket.reply(to: request.id, result: .object(["channel": .number(1)]))
        let stream = try await opened.value.stream
        #expect(try await stream.read() == data("paint"))
        #expect(try await stream.read() == nil)
    }

    @Test func aCancelledStreamSendsClose() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        let reader = Task { try await stream.read() }
        try await harness.settle()
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
        let close = await harness.socket.waitForFrame(channel: 1, kind: .close)
        #expect(close.payload.isEmpty)
    }

    @Test func aClosedStreamDropsLateBytesAndTheCoresCloseAnswerWithoutCredit() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        await stream.close()
        await stream.close()
        _ = await harness.socket.waitForFrame(channel: 1, kind: .close)
        // In flight when the CLOSE crossed: DATA, then the core's own CLOSE.
        try await harness.socket.deliver(dataFrame(1, "late"))
        try await harness.socket.deliver(HerdrCoreFrame(channel: 1, kind: .close))
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 1, kind: .close).count == 1)
        #expect(await harness.socket.frames(channel: 1, kind: .credit).isEmpty)
        #expect(try await stream.read() == nil)
        await #expect(throws: TransportError.self) { try await stream.write(data("too late")) }
    }

    @Test func aStreamOpenThatTimedOutClosesTheChannelItsLateReplyNames() async throws {
        let harness = try await Harness()
        let opened = Task { try await harness.link.openStream(
            "terminal.attach", params: .object(["terminal": .string("t1")]), deadline: .seconds(3)) }
        let request = await harness.socket.nextRequest()
        try await harness.socket.deliver(dataFrame(4, "early paint"))
        await harness.clock.untilParked(1)
        harness.clock.advance(.seconds(3))
        await #expect(throws: TransportError.timedOut) { try await opened.value }
        try await harness.socket.reply(to: request.id, result: .object(["channel": .number(4)]))
        _ = await harness.socket.waitForFrame(channel: 4, kind: .close)
        #expect(await harness.socket.frames(channel: 4, kind: .credit).isEmpty)
    }

    // MARK: Stream input

    @Test func streamInputGoesOutAsDataAndResizeAsItsFrame() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        try await stream.write(Data([0x1C]))
        try await stream.resize(columns: 80, rows: 24)
        #expect(await harness.socket.frames(channel: 1, kind: .data).map(\.payload) == [Data([0x1C])])
        #expect(await harness.socket.frames(channel: 1, kind: .resize).map(\.payload) == [Data([80, 0, 24, 0])])
        await #expect(throws: HerdrCoreFrameError.invalidGeometry(columns: 0, rows: 24)) {
            try await stream.resize(columns: 0, rows: 24)
        }
    }

    // MARK: Teardown

    @Test func anOversizedFrameTearsTheLinkDown() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        let pending = Task { try await harness.link.call("pending", deadline: .seconds(5)) }
        _ = await harness.socket.nextRequest()
        await harness.socket.deliver(Data([1, 0, 0, 0, 0, 0x01, 0x00, 0x00, 0x01]))
        await #expect(throws: TransportError.self) { try await pending.value }
        await harness.socket.waitUntilClosed()
        await #expect(throws: TransportError.self) { try await stream.read() }
    }

    @Test func endOfFileFailsPendingCallsAndFinishesStreams() async throws {
        let harness = try await Harness()
        let parked = try await harness.openStream(channel: 1)
        let buffered = try await harness.openStream(channel: 2)
        try await harness.socket.deliver(dataFrame(2, "kept"))
        try await harness.settle()
        let read = Task { try await parked.read() }
        let pending = Task { try await harness.link.call("terminal.get", deadline: .seconds(5)) }
        _ = await harness.socket.nextRequest()

        await harness.socket.deliverEndOfFile()
        await #expect(throws: TransportError.self) { try await pending.value }
        await #expect(throws: TransportError.self) { try await read.value }
        // What arrived before the end is still delivered, then the failure.
        #expect(try await buffered.read() == data("kept"))
        await #expect(throws: TransportError.self) { try await buffered.read() }
        await harness.socket.waitUntilClosed()
    }

    @Test func endOfFileReportsADispatchedMutationAsOutcomeUnknownWithoutARetry() async throws {
        let harness = try await Harness()
        let mutation = Task { try await harness.link.call(
            "terminal.send", params: .object(["text": .string("once")]), deadline: .seconds(5), isMutation: true) }
        let request = await harness.socket.nextRequest()
        #expect(request.method == "terminal.send")
        await harness.socket.deliverEndOfFile()
        await #expect(throws: TransportError.coreMutationOutcomeUnknown) { try await mutation.value }
        await harness.socket.waitUntilClosed()
        #expect(await harness.socket.requestCount() == 1)
    }

    @Test func aMutationStillQueuedAtTeardownNeverLeftAndIsAnOrdinaryFailure() async throws {
        let harness = try await Harness()
        await harness.socket.holdWrites()
        // The first is handed to the writer, which the socket holds; the second queues.
        let first = Task { try await harness.link.call("terminal.send", deadline: .seconds(5), isMutation: true) }
        await harness.socket.waitForHeldWrite()
        let second = Task { try await harness.link.call("terminal.keys", deadline: .seconds(5), isMutation: true) }
        await harness.clock.untilParked(2)

        await harness.socket.deliverEndOfFile()
        await #expect(throws: TransportError.coreMutationOutcomeUnknown) { try await first.value }
        await #expect(throws: TransportError.channelFailed(detail: "The herdr-core link closed.")) {
            try await second.value
        }
        await harness.socket.releaseWrites()
        await harness.socket.waitUntilClosed()
        #expect(await harness.socket.requestCount() == 0)
    }

    @Test func aDispatchedMutationPastItsDeadlineIsOutcomeUnknownAndTheLinkStaysUp() async throws {
        let harness = try await Harness()
        let mutation = Task { try await harness.link.call("terminal.send", deadline: .seconds(3), isMutation: true) }
        let request = await harness.socket.nextRequest()
        await harness.clock.untilParked(1)
        harness.clock.advance(.seconds(3))
        await #expect(throws: TransportError.coreMutationOutcomeUnknown) { try await mutation.value }
        try await harness.socket.reply(to: request.id)
        try await harness.settle()
        #expect(await !harness.socket.isClosed)
    }

    @Test func aMutationThatNeverLeftTheQueueIsRemovedAtItsDeadline() async throws {
        let harness = try await Harness()
        await harness.socket.holdWrites()
        let held = Task { try await harness.link.call("held", deadline: .seconds(9)) }
        await harness.socket.waitForHeldWrite()
        let queued = Task { try await harness.link.call("terminal.send", deadline: .seconds(3), isMutation: true) }
        await harness.clock.untilParked(2)
        harness.clock.advance(.seconds(3))
        await #expect(throws: TransportError.timedOut) { try await queued.value }
        await harness.socket.releaseWrites()
        let request = await harness.socket.nextRequest()
        #expect(request.method == "held")
        try await harness.socket.reply(to: request.id)
        _ = try await held.value
        try await harness.settle()
        let methods = await harness.socket.frames(channel: 0, kind: .data).compactMap {
            (try? JSONDecoder().decode(JSONValue.self, from: $0.payload))?["method"]?.stringValue
        }
        #expect(!methods.contains("terminal.send"))
    }

    @Test func aWriteFailureTearsTheLinkDownAndStreamInputInFlightIsOutcomeUnknown() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        await harness.socket.holdWrites()
        let input = Task { try await stream.write(data("typed")) }
        await harness.socket.waitForHeldWrite()
        await harness.socket.deliverEndOfFile()
        await #expect(throws: TransportError.coreMutationOutcomeUnknown) { try await input.value }
        await harness.socket.releaseWrites()
        await harness.socket.waitUntilClosed()
    }

    @Test func closeFinishesStreamsWithoutAFailure() async throws {
        let harness = try await Harness()
        let stream = try await harness.openStream(channel: 1)
        await harness.link.close()
        await harness.link.close()
        #expect(try await stream.read() == nil)
        #expect(await harness.socket.isClosed)
    }

    // MARK: Events over the link

    private func subscribe(_ harness: Harness, sequence: Int = 10, channel: UInt32 = 1) async throws -> HerdrCoreEventStream {
        let stream = Task { try await harness.link.subscribeEvents(deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        #expect(request.method == "events.subscribe")
        try await harness.socket.reply(
            to: request.id,
            result: .object([
                "seq": .number(Double(sequence)), "terminals": .array([]),
                "channel": .number(Double(channel)),
            ]))
        return try await stream.value
    }

    private func removedLine(sequence: Int) -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"seq":\#(sequence),"type":"removed","terminal":"t1","data":{}}}"# + "\n"
    }

    @Test func aSubscriptionCarriesItsSnapshotFirstAndEventsAfterIt() async throws {
        let harness = try await Harness()
        let exchange = try HerdrCoreVectorFile.shared.exchange("events-subscribe")
        let subscribed = Task { try await harness.link.subscribeEvents(deadline: .seconds(5)) }
        let request = await harness.socket.nextRequest()
        try await harness.socket.reply(to: request.id, result: exchange.result)
        let stream = try await subscribed.value
        #expect(stream.snapshot.sequence == 10)
        #expect(stream.snapshot.terminals.map(\.address) == ["t7", "t8"])

        var events = stream.events.makeAsyncIterator()
        try await harness.socket.deliver(dataFrame(1, removedLine(sequence: 10)))
        try await harness.socket.deliver(dataFrame(1, removedLine(sequence: 11)))
        #expect(try await events.next() == .removed(terminal: "t1"))
        await stream.end()
    }

    @Test func eventLinesSplitAcrossFramesStillDecodeAndCreditIsReturned() async throws {
        let harness = try await Harness()
        let stream = try await subscribe(harness)
        var events = stream.events.makeAsyncIterator()
        let bytes = data(removedLine(sequence: 11) + removedLine(sequence: 12))
        let cut = 20
        try await harness.socket.deliver(
            HerdrCoreFrame(channel: 1, kind: .data, payload: bytes.subdata(in: 0..<cut)))
        try await harness.socket.deliver(
            HerdrCoreFrame(channel: 1, kind: .data, payload: bytes.subdata(in: cut..<bytes.count)))
        #expect(try await events.next() == .removed(terminal: "t1"))
        #expect(try await events.next() == .removed(terminal: "t1"))
        await harness.socket.waitForCredit(channel: 1, total: bytes.count)
        await stream.end()
    }

    @Test func eachConnectionGetsAFreshCursor() async throws {
        let first = try await Harness()
        let before = try await subscribe(first, sequence: 500)
        await before.end()
        await first.link.close()

        // A restarted core's `seq` starts over, and this link must accept it.
        let second = try await Harness()
        let after = try await subscribe(second, sequence: 1)
        var events = after.events.makeAsyncIterator()
        try await second.socket.deliver(dataFrame(1, removedLine(sequence: 2)))
        #expect(try await events.next() == .removed(terminal: "t1"))
        await after.end()
    }

    @Test func theBoundedStreamMarksDropsAndKeepsReturningCredit() async throws {
        let harness = try await Harness()
        let stream = try await subscribe(harness)
        let total = HerdrCoreEventStream.bufferLimit + 50
        var delivered = 0
        for offset in 1...total {
            let line = removedLine(sequence: 10 + offset)
            delivered += line.utf8.count
            try await harness.socket.deliver(dataFrame(1, line))
        }
        // The pump drains whether or not anybody reads `events`.
        await harness.socket.waitForCredit(channel: 1, total: delivered)
        await stream.end()

        var sawMarker = false
        var count = 0
        for try await event in stream.events {
            count += 1
            if event == .dropped { sawMarker = true }
        }
        #expect(sawMarker)
        #expect(count <= HerdrCoreEventStream.bufferLimit)
    }

    @Test func endingASubscriptionSendsCloseAndFinishesWithoutError() async throws {
        let harness = try await Harness()
        let stream = try await subscribe(harness)
        await stream.end()
        await stream.end()
        _ = await harness.socket.waitForFrame(channel: 1, kind: .close)
        var count = 0
        for try await _ in stream.events { count += 1 }
        #expect(count == 0)
    }

    @Test func aDeadLinkFinishesTheEventsThrowing() async throws {
        let harness = try await Harness()
        let stream = try await subscribe(harness)
        await harness.socket.deliverEndOfFile()
        await #expect(throws: TransportError.self) {
            for try await _ in stream.events {}
        }
    }

    @Test func aMalformedEventLineFinishesTheEventsThrowingAndClosesTheChannel() async throws {
        let harness = try await Harness()
        let stream = try await subscribe(harness)
        try await harness.socket.deliver(dataFrame(1, "not JSON\n"))
        await #expect(throws: TransportError.self) {
            for try await _ in stream.events {}
        }
        _ = await harness.socket.waitForFrame(channel: 1, kind: .close)
    }
}
