import Foundation
import Synchronization
import Testing

@testable import Heeler

/// Explicit opt-in only: a Rex terminal opened for viewing (ADR 0051) through
/// the Console's runner and the store a view uses, against a Rex server that
/// already runs on this Mac, over its local Unix socket. It never runs in the
/// HeelerTests target or in CI, and fails rather than skips when selected
/// without its configuration.
///
/// It creates one session labeled `heeler-lab-r4b-…` with one shell under a
/// scrubbed environment, writes to that shell only, opens its terminal, asks
/// for a size, then destroys the session and checks the terminal ends. It
/// opens no other session's terminal and prints only counts and states, never
/// labels or terminal text. `/tmp/heeler-lab-home` must exist.
///
/// ```sh
/// mkdir -p /tmp/heeler-lab-home
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexTerminalAttachLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@MainActor
@Suite("Rex terminal attach over a local socket", .serialized, .timeLimit(.minutes(2)))
struct RexTerminalAttachLiveTests {
    final class Chunks: Sendable {
        private let chunks = Mutex<[Data]>([])
        func append(_ chunk: Data) { chunks.withLock { $0.append(chunk) } }
        var all: [Data] { chunks.withLock { $0 } }
        var text: String { String(decoding: all.reduce(Data(), +), as: UTF8.self) }
    }

    @Test func aLabTerminalOpensForViewing() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        let lab = try await RexLab.open(path: socketPath)
        var failure: (any Error)?
        do {
            try await run(lab, socketPath: socketPath)
        } catch {
            failure = error
        }
        let remaining = await lab.destroyEverything()
        print("Rex lab: \(remaining.lab) lab sessions remain, \(remaining.total) sessions in all")
        #expect(remaining.lab == 0)
        await lab.control.close()
        if let failure { throw failure }
    }

    private func run(_ lab: RexLab, socketPath: String) async throws {
        let created = try await lab.createSession(
            blocks: [("shell", ["/bin/sh"])], grid: LocalGrid(columns: 80, rows: 24), name: "r4b")
        let address = RexPaneAddress(sessionID: created.id, blockID: created.blocks[0])
        try await lab.type("printf 'heeler %s\\n' painted\r", session: address.sessionID, block: address.blockID)
        try await Task.sleep(for: .milliseconds(500))

        let session = RexHostSession(storedSocket: RexSocket(path: socketPath)) { _, previous in
            try await LocalRexTransport.connect(path: socketPath, resuming: previous)
        }
        await session.resume()
        let host = Host(
            name: "Rex", address: "localhost", username: "lab", serverKind: .rex,
            rexSocket: RexSocket(path: socketPath))
        let runner = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), onChange: {}
        ).terminalRunner()
        let chunks = Chunks()
        let input = TerminalInputController()
        let pin = TerminalCorePin()
        // Off screen, as the retention pool keeps a terminal, so it never
        // takes the block's size (ADR 0053): only asks for one.
        let store = AttachTerminalStore(
            target: .terminal(address.paneID), isViewed: false, input: input,
            observeOutput: { chunks.append($0) },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })

        // The first paint: a full reset, then the server's redraw.
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first paint", timeout: .seconds(20)) { store.status == .live }
        let first = try #require(chunks.all.first)
        #expect(first.starts(with: RexTerminalPaint.reset))
        #expect(String(decoding: first, as: UTF8.self).contains("heeler painted"))

        // Output follows, and input opened with the first paint
        // (`RexTerminalInputLiveTests` types into a lab terminal).
        try await lab.type("printf 'heeler %s\\n' followed\r", session: address.sessionID, block: address.blockID)
        try await waitUntil("the output", timeout: .seconds(10)) { chunks.text.contains("heeler followed") }
        #expect(input.liveGeneration != nil)

        // A size asked for, never owned.
        store.viewDidResize(cols: 100, rows: 30)
        try await waitUntil("the size asked for", timeout: .seconds(10)) {
            store.sizeReport?.local == TerminalSizeReport.Grid(columns: 100, rows: 30)
        }
        try await Task.sleep(for: .seconds(1))
        let report = try #require(store.sizeReport)
        let owner =
            switch report.owner {
            case nil: "no owner"
            case report.client: "this client"
            default: "another client"
            }
        let server = report.server.map { "\($0.columns)x\($0.rows)" } ?? "unknown"
        print("Rex lab: after asking for 100x30 the block has \(owner) and the server grid is \(server)")
        if report.owner == nil { #expect(report.server == report.local) }
        #expect(report.owner == nil || report.owner != report.client)

        // The block goes with its session: the terminal finishes, and stays so.
        let left = await lab.destroyEverything()
        #expect(left.lab == 0)
        try await waitUntil("the terminal's end", timeout: .seconds(10)) { store.status == .finished }
        try await Task.sleep(for: .seconds(1))
        #expect(store.status == .finished)
        #expect(await session.openTerminalCount == 0)
        print("Rex lab: \(chunks.all.count) chunks reached the view; it ended \(store.status)")

        await store.stop()
        await session.end()
    }

    private func waitUntil(
        _ what: String, timeout: Duration, sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }
}
