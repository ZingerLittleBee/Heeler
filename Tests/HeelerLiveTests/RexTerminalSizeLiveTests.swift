import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: the size a Rex terminal takes for the view that
/// shows it, and gives back (ADR 0053), through the Console's runner and the
/// store a view uses, against a Rex server that already runs on this Mac,
/// over its local Unix socket. It never runs in the HeelerTests target or in
/// CI, and fails rather than skips when selected without its configuration.
///
/// The lab's own control client stands in for another device: it creates one
/// session labeled `heeler-lab-r6-…` with one shell under a scrubbed
/// environment at 100x30, asks for that size, and takes the block. An 80x24
/// view then opens shown: it takes the size before its first paint, with no
/// tap and no notice. The other device takes it back, and the view leaves it
/// with the other device, offering the notice; leaving gives nothing to
/// anyone, coming back takes the size again, and leaving once more passes it
/// back to the other device at its own size. It owns, resizes and opens no
/// other session's blocks, and prints only counts and booleans.
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

    @Test func aShownLabTerminalTakesItsSizeAndGivesItBack() async throws {
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
        let other = lab.control.clientID
        // The other device asks for its size and takes the block, so it is
        // in line for it once this view gives the size back.
        try await otherDeviceTakes(address, lab: lab)
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

        // Opening shown: the first grid the view hears is its own, and no
        // notice shows on the way.
        store.viewDidResize(cols: 80, rows: 24)
        var firstGrid: TerminalSizeReport.Grid?
        var noticeShown = false
        let opening = ContinuousClock.now + .seconds(20)
        while store.status != .live, ContinuousClock.now < opening {
            if firstGrid == nil { firstGrid = store.sizeReport?.server }
            noticeShown = noticeShown || store.sizeNotice != nil
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.status == .live)
        let settled = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < settled {
            if firstGrid == nil { firstGrid = store.sizeReport?.server }
            noticeShown = noticeShown || store.sizeNotice != nil
            try await Task.sleep(for: .milliseconds(20))
        }
        let client = try #require(store.sizeReport?.client)
        let opened = try await size(of: address, lab: lab)
        print(
            "Rex lab: opening, the first grid is the view's \(firstGrid == .init(columns: 80, rows: 24)),"
                + " a notice showed \(noticeShown), this view owns the block \(opened.owner == client)")
        #expect(firstGrid == TerminalSizeReport.Grid(columns: 80, rows: 24))
        #expect(!noticeShown)
        #expect(store.sizeReport?.owner == client)
        #expect(opened == BlockSize(columns: 80, rows: 24, owner: client))

        // The other device takes it back: the view leaves it there and
        // offers the notice.
        try await otherDeviceTakes(address, lab: lab)
        try await waitUntil("the notice", timeout: .seconds(10)) { store.sizeNotice?.phase == .offered }
        try await Task.sleep(for: .seconds(1))
        let takenBack = try await size(of: address, lab: lab)
        print(
            "Rex lab: after the other device takes it back, it still owns the block \(takenBack.owner == other),"
                + " the notice shows \(store.sizeNotice != nil)")
        #expect(takenBack == BlockSize(columns: 100, rows: 30, owner: other))

        // Leaving takes this client out of line; the block stays.
        store.setViewed(false)
        try await Task.sleep(for: .seconds(1))
        let left = try await size(of: address, lab: lab)
        print("Rex lab: after leaving, the other device still owns the block \(left.owner == other)")
        #expect(left == BlockSize(columns: 100, rows: 30, owner: other))

        // Coming back is a new showing: it takes the size again.
        store.setViewed(true)
        try await waitUntil("the take on coming back", timeout: .seconds(10)) {
            (try? await size(of: address, lab: lab)) == BlockSize(columns: 80, rows: 24, owner: client)
        }
        try await waitUntil("the notice to go", timeout: .seconds(10)) { store.sizeNotice == nil }
        print("Rex lab: after coming back, this view owns the block at its grid")

        // Leaving again passes the block back to the other device, which is
        // in line for it, at its own size.
        store.setViewed(false)
        try await waitUntil("the give back", timeout: .seconds(10)) {
            (try? await size(of: address, lab: lab))?.owner == other
        }
        let given = try await size(of: address, lab: lab)
        print(
            "Rex lab: after leaving again, the other device owns the block \(given.owner == other),"
                + " its size is back \(given.columns == 100 && given.rows == 30)")
        #expect(given == BlockSize(columns: 100, rows: 30, owner: other))

        await store.stop()
        await session.end()
    }

    /// The lab's client, standing in for another device, asks for 100x30 and
    /// takes the block.
    private func otherDeviceTakes(_ address: RexPaneAddress, lab: RexLab) async throws {
        _ = try await lab.control.call(
            RexInventoryWire.terminalMethod("resize"),
            payload: RexTerminalAttach.resizePayload(address, columns: 100, rows: 30))
        _ = try await lab.control.call(
            RexTerminalAttach.takeMethod, payload: RexTerminalAttach.ownershipPayload(address, take: true))
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
