import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: taking a Rex terminal's size for the view and giving
/// it back (ADR 0053), through the Console's runner and the store a view uses,
/// against a Rex server that already runs on this Mac, over its local Unix
/// socket. It never runs in the HeelerTests target or in CI, and fails rather
/// than skips when selected without its configuration.
///
/// The lab's own control client stands in for another device: it creates one
/// session labeled `heeler-lab-r6-…` with one shell under a scrubbed
/// environment at 100x30, asks for that size, and takes the block. An 80x24
/// view then reports the mismatch and its notice, takes the size, sees the
/// server's grid become its own, and gives the size back. It owns, resizes and
/// opens no other session's blocks, and prints only counts and booleans.
/// `/tmp/heeler-lab-home` must exist.
///
/// ```sh
/// mkdir -p /tmp/heeler-lab-home
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexTerminalSizeLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@MainActor
@Suite("Rex terminal size over a local socket", .serialized, .timeLimit(.minutes(2)))
struct RexTerminalSizeLiveTests {
    struct BlockSize: Equatable {
        let columns: Int
        let rows: Int
        let owner: String?
    }

    @Test func aLabTerminalTakesItsSizeAndGivesItBack() async throws {
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
            blocks: [("shell", ["/bin/sh"])], grid: LocalGrid(columns: 100, rows: 30), name: "r6")
        let address = RexPaneAddress(sessionID: created.id, blockID: created.blocks[0])
        // The other device asks for its size and takes the block, so it is
        // in line for it once this view gives the size back.
        _ = try await lab.control.call(
            RexInventoryWire.terminalMethod("resize"),
            payload: RexTerminalAttach.resizePayload(address, columns: 100, rows: 30))
        _ = try await lab.control.call(
            RexTerminalAttach.takeMethod, payload: RexTerminalAttach.ownershipPayload(address, take: true))
        let other = lab.control.clientID
        let before = try await size(of: address, lab: lab)
        print("Rex lab: before, the other device owns the block \(before.owner == other)")
        #expect(before == BlockSize(columns: 100, rows: 30, owner: other))

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
        let pin = TerminalCorePin()
        let store = AttachTerminalStore(
            target: .terminal(address.paneID),
            settleSizeNotice: { try await Task.sleep(for: .milliseconds(300)) },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first paint", timeout: .seconds(20)) { store.status == .live }
        try await waitUntil("the notice", timeout: .seconds(10)) { store.sizeNotice?.phase == .offered }
        let report = try #require(store.sizeReport)
        let client = try #require(report.client)
        print(
            "Rex lab: the view reports a size set elsewhere \(report.isSetElsewhere),"
                + " the notice shows \(store.sizeNotice != nil)")
        #expect(report.server == TerminalSizeReport.Grid(columns: 100, rows: 30))
        #expect(report.owner == other)

        // The tap.
        store.takeSize()
        try await waitUntil("the take", timeout: .seconds(10)) {
            store.sizeNotice == nil && store.sizeReport?.owner == client
        }
        try await waitUntil("the view's grid", timeout: .seconds(10)) {
            store.sizeReport?.server == TerminalSizeReport.Grid(columns: 80, rows: 24)
        }
        let taken = try await size(of: address, lab: lab)
        print(
            "Rex lab: after the take, this view owns the block \(taken.owner == client),"
                + " the server grid is the view's \(taken.columns == 80 && taken.rows == 24)")
        #expect(taken == BlockSize(columns: 80, rows: 24, owner: client))

        // The view goes off screen: the block goes back to the other device,
        // which is in line for it, at its own size.
        store.setViewed(false)
        try await waitUntil("the give back", timeout: .seconds(10)) {
            (try? await size(of: address, lab: lab))?.owner == other
        }
        let given = try await size(of: address, lab: lab)
        print(
            "Rex lab: after leaving, the other device owns the block \(given.owner == other),"
                + " its size is back \(given.columns == 100 && given.rows == 30)")
        #expect(given == BlockSize(columns: 100, rows: 30, owner: other))

        // Coming back takes nothing.
        store.setViewed(true)
        try await Task.sleep(for: .seconds(1))
        let back = try await size(of: address, lab: lab)
        print("Rex lab: after coming back, the other device still owns the block \(back.owner == other)")
        #expect(back.owner == other)

        await store.stop()
        await session.end()
    }

    private func size(of address: RexPaneAddress, lab: RexLab) async throws -> BlockSize {
        let result = try await lab.control.call(
            RexInventoryWire.terminalMethod("size"),
            payload: JSONValue.object([
                "session_id": .string(address.sessionID), "block_id": .string(address.blockID),
            ])
        ).result(JSONValue.self)
        guard case .number(let columns)? = result["columns"], case .number(let rows)? = result["rows"] else {
            throw RexLab.LabError.unreadable("size")
        }
        return BlockSize(columns: Int(columns), rows: Int(rows), owner: result["owner"]?.stringValue)
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
