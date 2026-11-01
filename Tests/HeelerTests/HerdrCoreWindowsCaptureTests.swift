import Foundation
import Testing

@testable import Heeler

/// Replays the scrubbed capture from a native Windows core, taken from a Mac over an
/// SSH exec of `herdr-core connect`. The description and each source say which hex
/// strings are wire bytes; the rest are rebuilt from scrubbed JSON. It proves the codec
/// reads what crossed that one exec, not that every Windows server behaves the same
/// (see the compatibility notes).
@Suite struct HerdrCoreWindowsCaptureTests {
    private let vectors = HerdrCoreVectorFile.windows

    private func oneFrame(hex: String) throws -> (frame: HerdrCoreFrame, bytes: Data) {
        let bytes = HerdrCoreVectorFile.bytes(hex: hex)
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(bytes)
        let frame = try #require(try decoder.next())
        #expect(try decoder.next() == nil)
        return (frame, bytes)
    }

    @Test func everyCaseNamesItsCapture() {
        #expect(!vectors.provisional)
        #expect(vectors.coreVersion == "0.1.16")
        // Pinned against the file: a section that stops decoding cannot pass quietly.
        #expect(vectors.allCases.count == 1 + 10 + 2 + 2 + 12 + 2)
        #expect(Set(vectors.allCases.map(\.name)).count == vectors.allCases.count)
        for testCase in vectors.allCases {
            #expect(testCase.source.hasPrefix("captured from herdr-core 0.1.16 on native Windows, from a Mac over one ssh -T exec "), "\(testCase.name)")
        }
    }

    @Test func everyCapturedFrameDecodesAndEncodesToTheSameBytes() throws {
        let hexes = vectors.frames.map(\.bytes)
            + vectors.exchanges.flatMap { [$0.requestFrame, $0.replyFrame] }
            + vectors.eventFrames.map(\.bytes)
        for hex in hexes {
            let (frame, bytes) = try oneFrame(hex: hex)
            #expect(try frame.encoded() == bytes)
        }
    }

    @Test func theClientFrameCarriesEveryByteValueThenLineEndsAndCtrlZ() throws {
        let vector = try #require(vectors.frames.first { $0.name == "client-data-every-byte" })
        let payload = try oneFrame(hex: vector.bytes).frame.payload
        #expect(Set(payload).count == 256)
        #expect(payload.prefix(256) == Data((0...255).map(UInt8.init)))
        #expect(payload.dropFirst(256) == Data([0x0D, 0x0A, 0x0D, 0x0A, 0x1A]) + Data("ZZEND".utf8))
    }

    @Test func aProgramsLineEndsAndCtrlZStayInTheCapturedStream() throws {
        let vector = try #require(vectors.frames.first { $0.name == "data-attach-cr-lf-crlf-ctrl-z" })
        let payload = try oneFrame(hex: vector.bytes).frame.payload
        #expect(payload == Data("crlf\r\nlf\r\ncr\rtab\tsub\u{1A}sub\r\n".utf8))
    }

    /// A text-mode stream would change these three bytes wherever they fall, a frame's
    /// length included, and the decoder would then lose the stream.
    @Test func aLengthThatIsALineEndOrCtrlZArrivedAsALength() throws {
        for (name, length) in [("data-attach-length-lf", 0x0A), ("data-attach-length-cr", 0x0D), ("data-attach-length-ctrl-z", 0x1A)] {
            let vector = try #require(vectors.frames.first { $0.name == name })
            let (frame, bytes) = try oneFrame(hex: vector.bytes)
            #expect(bytes[bytes.startIndex + 5] == UInt8(length), "\(name)")
            #expect(frame.payload.count == length, "\(name)")
            #expect(frame.payload.suffix(2) == Data([0x0D, 0x0A]), "\(name)")
        }
    }

    @Test func theLinkReadsTheCoresHelloStatusAndAttachFrames() async throws {
        let socket = FakeCoreSocket()
        let clock = ManualClock()
        let connected = Task { try await HerdrCoreLink.connect(over: socket, sleep: clock.parkedSleep(for:)) }
        _ = await socket.nextWrittenLine()
        await socket.deliver(Data(vectors.hello.reply.utf8) + Data([0x0A]))
        let link = try await connected.value.link

        let exchange = try vectors.exchange("server-status")
        let status = Task { try await link.serverStatus(deadline: .seconds(5)) }
        let statusRequest = await socket.nextRequest()
        try await socket.reply(to: statusRequest.id, result: exchange.result)
        #expect(try await status.value.pid == HerdrCoreWire.integer(exchange.result["pid"]))

        let attachFrames = try ["data-attach-first-paint", "data-attach-cr-lf-crlf-ctrl-z", "data-attach-utf8"].map { name in
            try oneFrame(hex: try #require(vectors.frames.first { $0.name == name }).bytes)
        }
        let channel = try #require(attachFrames.first).frame.channel
        let opened = Task {
            try await link.openStream("terminal.attach", params: .object(["terminal": .string("t1")]), deadline: .seconds(5))
        }
        let attach = await socket.nextRequest()
        try await socket.reply(to: attach.id, result: .object(["channel": .number(Double(channel))]))
        let stream = try await opened.value.stream
        for captured in attachFrames {
            await socket.deliver(captured.bytes)
            #expect(try await stream.read() == captured.frame.payload)
        }
    }

    @Test func eventLinesDecodeWithPowerShellAsTheForeground() throws {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        for name in ["foreground-heeler-form", "foreground-desktop-form"] {
            let line = try #require(vectors.events.first { $0.name == name }).line
            let event = try #require(try cursor.decode(line: Data(line.utf8)), "\(name)")
            guard case .foreground(_, let foreground?) = event else {
                Issue.record("\(name) did not decode as a foreground event: \(event)")
                continue
            }
            #expect(foreground.name == "powershell.exe")
        }
    }

    @Test func aFinishCarriesTheProgramsExitCodeOnlyUnderHeelersForm() throws {
        var cursor = HerdrCoreTypedEventCursor(sequence: 0)
        let heeler = try #require(vectors.events.first { $0.name == "finished-heeler-form" }).line
        guard case .finished(_, let end) = try #require(try cursor.decode(line: Data(heeler.utf8))) else {
            Issue.record("the Heeler form's finish did not decode")
            return
        }
        // choice.exe answered 2.
        #expect(end.exitCode == 2)
        // Under -NoExit the finish carries the shell's own `exit 5`, not the program's code.
        let desktop = try #require(vectors.events.first { $0.name == "finished-desktop-form" }).line
        guard case .finished(_, let desktopEnd) = try #require(try cursor.decode(line: Data(desktop.utf8))) else {
            Issue.record("the desktop form's finish did not decode")
            return
        }
        #expect(desktopEnd.exitCode == 5)
    }
}
