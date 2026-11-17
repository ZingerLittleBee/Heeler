import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// Taking a Rex terminal's size for the view and giving it back (ADR 0053),
/// from the store the view uses to a fake server's block: shown means
/// fitted, so a showing takes the size on its own, before the first paint
/// for an attach that opens shown, once, through the same gate as input; a
/// take of another client's in the showing, or one of its own that did not
/// go through, leaves the notice's tap to take it; what was taken goes back
/// when the view stops showing the terminal and when the attach ends, and
/// what the server handed over by itself stays. Ids, nonces and tokens are
/// invented.
@MainActor
@Suite("Rex terminal size ownership", .timeLimit(.minutes(1)))
struct RexTerminalSizeOwnershipTests {
    typealias Rig = RexTerminalAttachTests.Rig
    nonisolated static let otherDevice = RexTerminalAttachTests.ownerClient
    nonisolated static let thisClient = "client:00000000-0000-7000-8000-000000000001"
    nonisolated static let freshClient = "client:00000000-0000-7000-8000-000000000002"
    static let resize = RexInventoryWire.terminalMethod("resize")
    static let take = "session.own_block"
    static let giveBack = "session.disown_block"

    private func hostSession(
        _ hosts: [ScriptedRexHost], inputDeadline: Duration = .seconds(10)
    ) -> RexHostSession {
        var options = RexTerminalAttach.Options()
        options.stream.link = .testing
        options.stream.startOverDelay = .milliseconds(20)
        options.stream.resumeDelay = .milliseconds(20)
        options.sizeSettle = .milliseconds(40)
        options.closeGrace = .milliseconds(150)
        options.inputDeadline.silence = inputDeadline
        options.giveBackDeadline.silence = .milliseconds(300)
        let dialer = RexHostSessionTests.Dialer(hosts)
        return RexHostSession(
            storedSocket: RexSocket(path: RexTerminalAttachTests.socket), connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            terminalOptions: options)
    }

    private func store(
        _ session: RexHostSession, input: TerminalInputController = TerminalInputController(), viewed: Bool = true
    ) -> AttachTerminalStore {
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: RexTerminalAttachTests.socket))
        let runner = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), onChange: {}
        ).terminalRunner()
        let pin = TerminalCorePin()
        return AttachTerminalStore(
            target: .terminal(RexTerminalAttachTests.address.paneID), isViewed: viewed, input: input,
            settleSizeNotice: { try await Task.sleep(for: .milliseconds(30)) },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })
    }

    /// A shell terminal's owner over the same runner, which replaces its
    /// store as a screen's foreground recovery does.
    private func shell(_ session: RexHostSession) -> ShellTerminalStore {
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: RexTerminalAttachTests.socket))
        let runner = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), onChange: {}
        ).terminalRunner()
        let pin = TerminalCorePin()
        let paneID = RexTerminalAttachTests.address.paneID
        return ShellTerminalStore(
            identity: ShellTerminalIdentity(paneID: paneID, tabID: paneID, terminalID: paneID),
            transportGeneration: nil, isOnStage: { true },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })
    }

    /// A live 80x24 view that took the block's size as it opened: the
    /// stream starts at the view's grid, owned by this client.
    private func openShown(
        _ rig: Rig, session: RexHostSession, on server: FakeRexServer, stream: Int = 0,
        input: TerminalInputController = TerminalInputController()
    ) async throws -> AttachTerminalStore {
        let store = store(session, input: input)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the opening take") { await ownership(server) == [Self.take] }
        await rig.begin(stream: stream, columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the first paint") { store.status == .live }
        return store
    }

    /// Another device takes the block and sizes it 100x30, as a take from
    /// another device's view does; the notice offers it back.
    private func takeAway(_ store: AttachTerminalStore, rig: Rig, on server: FakeRexServer, stream: Int = 0) async throws {
        await pushOwner(server, Self.otherDevice, previous: Self.thisClient, reason: "take")
        let nonce = await rig.endpoint.nonce(of: stream)
        await rig.endpoint.send(FakeRexStream.resize(columns: 100, rows: 30, nonce: nonce, owner: Self.otherDevice))
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
    }

    /// Takes the size from the notice, and waits for the view's grid to be
    /// asked for as the block's owner.
    private func takeFromTheNotice(_ store: AttachTerminalStore, on server: FakeRexServer) async throws {
        let takesBefore = await requests(server, Self.take).count
        let before = await requests(server, Self.resize).count
        store.takeSize()
        try await waitUntil("the take and the size after it") {
            let takes = await requests(server, Self.take).count
            let resizes = await requests(server, Self.resize).count
            return takes == takesBefore + 1 && resizes > before
        }
        try await waitUntil("the notice to go") { store.sizeNotice == nil }
    }

    private func requests(_ server: FakeRexServer, _ method: String) async -> [FakeRexServer.Request] {
        await server.requests.filter { $0.method == method }
    }

    private func ownership(_ server: FakeRexServer) async -> [String] {
        await server.requests.map(\.method).filter { $0 == Self.take || $0 == Self.giveBack }
    }

    private func pushOwner(_ server: FakeRexServer, _ owner: String?, previous: String?, reason: String) async {
        await server.push(
            "block_owner_changed",
            [
                "block_id": "block:left", "owner": owner.map(JSONValue.string) ?? .null,
                "previous": previous.map(JSONValue.string) ?? .null, "reason": .string(reason),
            ],
            session: "session:studio")
    }

    private func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    // MARK: Taking on its own

    /// A terminal that opens shown takes the block's size before its stream
    /// starts, then asks for the view's grid as its owner, so the first paint
    /// comes at that grid and no notice shows. Ending gives the size back.
    @Test func openingShownTakesTheSizeBeforeTheFirstPaint() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)

        let take = try #require(await requests(control, Self.take).first)
        #expect(
            take.payload == ["session_id": "session:studio", "block_ids": ["block:left"], "mode": "take"])
        let methods = await control.requests.map(\.method)
        let attached = try #require(methods.firstIndex(of: "session.attach"))
        let taken = try #require(methods.firstIndex(of: Self.take))
        let sized = try #require(methods.firstIndex(of: Self.resize))
        let streamed = try #require(methods.firstIndex(of: "data.connect"))
        #expect(attached < taken && taken < sized && sized < streamed)
        #expect(await requests(control, Self.resize).map { $0.payload?["args"] } == [["columns": 80, "rows": 24]])
        #expect(rig.world.owner(of: "block:left") == Self.thisClient)
        #expect(store.sizeReport?.owner == Self.thisClient)
        #expect(store.sizeReport?.server == .init(columns: 80, rows: 24))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.sizeNotice == nil)

        await store.stop()
        let giveBack = try #require(await requests(control, Self.giveBack).first)
        #expect(giveBack.payload == ["session_id": "session:studio", "block_ids": ["block:left"]])
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// An attach kept off screen, as the pool keeps one, takes nothing, nor
    /// does one in a scene in the background; coming on screen in the
    /// foreground takes the size for the open attach.
    @Test func onlyAShownTerminalTakesTheSize() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = store(session, viewed: false)
        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin(columns: 100, rows: 30)
        try await waitUntil("the first paint") { store.status == .live }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control).isEmpty)

        store.sceneDidEnterBackground()
        store.setViewed(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control).isEmpty)
        store.sceneDidBecomeActive()
        try await waitUntil("the take on screen") { await ownership(control) == [Self.take] }
        try await waitUntil("the view's grid as owner") {
            await requests(control, Self.resize).last?.payload?["args"] == ["columns": 80, "rows": 24]
        }
        #expect(store.sizeReport?.owner == Self.thisClient)
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// Leaving the view or the scene going to the background gives the size
    /// back; coming back takes it again, once. The app coming back alone
    /// takes nothing.
    @Test func leavingGivesItBackAndComingBackTakesItAgain() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        #expect(rig.world.owner(of: "block:left") == nil)
        store.setViewed(true)
        try await waitUntil("the take again") {
            await ownership(control) == [Self.take, Self.giveBack, Self.take]
        }
        store.didBecomeActive()
        store.sceneDidEnterBackground()
        try await waitUntil("the give back in the background") {
            await ownership(control) == [Self.take, Self.giveBack, Self.take, Self.giveBack]
        }
        store.sceneDidBecomeActive()
        try await waitUntil("the take in the foreground") { await ownership(control).count == 5 }
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(
            await ownership(control) == [Self.take, Self.giveBack, Self.take, Self.giveBack, Self.take, Self.giveBack])
    }

    /// A take of its own that the store's own stop cuts short did not fail:
    /// here the scene comes back while the give back from going to the
    /// background is still out, and a possible suspension replaces the
    /// pipeline before the take behind it goes out. The new attach takes the
    /// size as it opens, before its stream starts.
    @Test func aPipelineReplacedWhileShownTakesTheSizeAsItOpens() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let shell = shell(session)
        shell.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the opening take") { await ownership(control) == [Self.take] }
        await rig.begin(columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the first paint") { shell.terminal.status == .live }

        await control.stopAnswering(Self.giveBack)
        shell.sceneDidEnterBackground()
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        let first = shell.terminal
        shell.sceneDidBecomeActive()
        // The take of its own queues behind the give back before the
        // replacement comes.
        try await Task.sleep(for: .milliseconds(100))
        shell.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("the replacement") { shell.terminal !== first }
        #expect(await requests(control, Self.take).count == 1)
        #expect(shell.terminal.sizeShowing.fitsOnItsOwn)

        shell.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the new attach's take") { await requests(control, Self.take).count == 2 }
        await rig.begin(stream: 1, columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the new paint") { shell.terminal.status == .live }
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.lastIndex(of: Self.take))
        let streamed = try #require(methods.lastIndex(of: "data.connect"))
        #expect(taken < streamed)
        #expect(shell.terminal.sizeReport?.owner == Self.thisClient)
        await shell.leave().value
    }

    /// Another client's take while the view shows the terminal stands: the
    /// notice offers the size back, nothing takes it on its own, and an
    /// attach on a fresh client in the same showing takes nothing either.
    /// The next showing takes it again.
    @Test func anotherClientsTakeStandsForTheRestOfTheShowing() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = FakeRexServer()
        await rig.world.install(on: second, client: Self.freshClient)
        await rig.endpoint.tickets.install(on: second, client: Self.freshClient)
        await rig.reads.install(on: second)
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = Self.freshClient
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: fresh)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: first)

        try await takeAway(store, rig: rig, on: first)
        #expect(store.sizeReport?.takenAway == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(first) == [Self.take])

        await first.drop()
        await rig.begin(stream: 1, columns: 100, rows: 30)
        try await waitUntil("the fresh paint") { store.status == .live && store.sizeReport?.client == Self.freshClient }
        try await waitUntil("the notice again") { store.sizeNotice?.phase == .offered }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(second).isEmpty)

        store.setViewed(false)
        store.setViewed(true)
        try await waitUntil("the next showing's take") { await ownership(second) == [Self.take] }
        try await waitUntil("the notice to go") { store.sizeNotice == nil }
        await store.stop()
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second) == [Self.take, Self.giveBack])
    }

    /// An owner change to this client that Rex sends for this client's own
    /// take is not another client's: only one to another client, heard after
    /// the take went out and not followed by one to this client, is. Its
    /// answer naming this client does not outrank the newer change.
    @Test func anOwnerChangeDuringTheTakeOutranksItsAnswer() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = store(session)
        store.viewDidResize(cols: 80, rows: 24)
        let take = await control.nextRequest()
        #expect(take.method == Self.take)

        await pushOwner(control, Self.thisClient, previous: Self.otherDevice, reason: "take")
        try await waitUntil("this client's take") { store.sizeReport?.owner == Self.thisClient }
        #expect(store.sizeReport?.takenAway == 0)
        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "take")
        try await waitUntil("the other device's take") { store.sizeReport?.owner == Self.otherDevice }
        await control.respond(
            to: take, with: ["blocks": [["block_id": "block:left", "owner": .string(Self.thisClient)]]])
        await rig.begin(columns: 100, rows: 30)
        try await waitUntil("the first paint") { store.status == .live }
        #expect(store.sizeReport?.owner == Self.otherDevice)
        #expect(store.sizeReport?.takenAway == 1)
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control) == [Self.take])
        await store.stop()
    }

    /// The server echoing this client's own take, before or after its
    /// answer, counts for nothing: the showing goes on taking the size on
    /// its own, here for the attach after a resumed link.
    @Test func thisClientsOwnTakeIsNoOtherClients() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openShown(rig, session: session, on: first, input: input)
        await pushOwner(first, Self.thisClient, previous: nil, reason: "take")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.sizeReport?.takenAway == 0)
        #expect(store.sizeNotice == nil)

        await first.drop()
        await second.acceptUpgrade()
        #expect(input.send(Data("one\r".utf8)))
        try await waitUntil("the reconnect") { store.status == .reconnecting }
        _ = await second.nextHello()
        await second.sendWelcome(resumed)
        try await waitUntil("the reattach's take") { await ownership(second) == [Self.take] }
        await rig.begin(stream: 1, columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the new paint") { store.status == .live }
        await store.stop()
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second) == [Self.take, Self.giveBack])
    }

    /// A take of its own that the server refused is never sent again on its
    /// own in the showing: the stream starts with the view's grid asked for
    /// plainly, the notice offers the size, and a tap still takes it. The
    /// next showing takes it on its own again.
    @Test func aRefusedTakeOfItsOwnIsNotSentAgain() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        await control.answer(Self.take, with: .error(code: "conflict", message: "attach first", status: 409))
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = store(session)
        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin(columns: 100, rows: 30)
        try await waitUntil("the first paint") { store.status == .live }
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
        #expect(await ownership(control) == [Self.take])
        #expect(await requests(control, Self.resize).map { $0.payload?["args"] } == [["columns": 80, "rows": 24]])
        store.viewDidResize(cols: 90, rows: 30)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await ownership(control) == [Self.take])

        store.takeSize()
        let refused = try #require(AttachTerminalStore.sizeTakeFailure(.refused))
        try await waitUntil("the tap's refusal") { store.sizeNotice?.phase == .failed(refused) }
        #expect(await ownership(control) == [Self.take, Self.take])

        store.setViewed(false)
        store.setViewed(true)
        try await waitUntil("the next showing's take") { await ownership(control).count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.take, Self.take])
    }

    /// A take of its own with no answer by its deadline is never sent again,
    /// and holds the first paint no longer than that; it may have arrived, so
    /// leaving gives it back.
    @Test func anUnansweredTakeOfItsOwnIsNeverSentAgainButIsGivenBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        let session = hostSession([await rig.host([.server(control)])], inputDeadline: .milliseconds(150))
        defer { Task { await session.end() } }
        await session.resume()
        let store = store(session)
        store.viewDidResize(cols: 80, rows: 24)
        _ = await control.nextRequest()
        await rig.begin(columns: 100, rows: 30)
        try await waitUntil("the first paint") { store.status == .live }
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control) == [Self.take])

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    // MARK: Taking at a tap

    /// The notice's action takes the block back for this client, then asks
    /// for the view's grid as its owner; the notice goes, and ending the
    /// attach gives the size back.
    @Test func aTapTakesTheSizeAndAsksForTheViewsGrid() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)
        try await takeAway(store, rig: rig, on: control)
        #expect(store.sizeNotice?.server == .init(columns: 100, rows: 30))

        try await takeFromTheNotice(store, on: control)
        let take = try #require(await requests(control, Self.take).last)
        #expect(
            take.payload == ["session_id": "session:studio", "block_ids": ["block:left"], "mode": "take"])
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.lastIndex(of: Self.take))
        #expect(methods[(taken + 1)...].contains(Self.resize))
        #expect(await requests(control, Self.resize).last?.payload?["args"] == ["columns": 80, "rows": 24])
        #expect(store.sizeReport?.owner == Self.thisClient)
        #expect(rig.world.owner(of: "block:left") == Self.thisClient)

        // The stream says the block took the view's grid: nothing to say.
        let nonce = await rig.endpoint.nonce(of: 0)
        await rig.endpoint.send(FakeRexStream.resize(columns: 80, rows: 24, nonce: nonce, owner: Self.thisClient))
        try await waitUntil("the new grid") { store.sizeReport?.server == .init(columns: 80, rows: 24) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.sizeNotice == nil)

        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.take, Self.giveBack])
    }

    /// A refused tap says so and asks for no size.
    @Test func aRefusedTapSaysSoAndAsksForNoSize() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)
        try await takeAway(store, rig: rig, on: control)
        await control.stopAnswering(Self.take)
        await control.answer(Self.take, with: .error(code: "conflict", message: "attach first", status: 409))
        let resizes = await requests(control, Self.resize).count

        store.takeSize()
        let refused = try #require(AttachTerminalStore.sizeTakeFailure(.refused))
        try await waitUntil("the refusal") { store.sizeNotice?.phase == .failed(refused) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control) == [Self.take, Self.take])
        #expect(await requests(control, Self.resize).count == resizes)
        await store.stop()
    }

    /// A tap's take with no answer by its deadline is never sent again, and
    /// says so; leaving gives the size back.
    @Test func anUnansweredTapIsNeverSentAgainButIsGivenBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])], inputDeadline: .milliseconds(150))
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)
        try await takeAway(store, rig: rig, on: control)
        await control.stopAnswering(Self.take)

        store.takeSize()
        #expect(store.sizeNotice?.phase == .taking)
        _ = await control.nextRequest()
        let unknown = try #require(AttachTerminalStore.sizeTakeFailure(.unknown))
        try await waitUntil("no answer") { store.sizeNotice?.phase == .failed(unknown) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control) == [Self.take, Self.take])
        #expect(store.status == .live)

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.take, Self.giveBack] }
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.take, Self.giveBack])
    }

    /// A tap while no link is the terminal's is not sent, and not sent once
    /// a link takes the client back.
    @Test func aTapWithNoLinkIsNotSent() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: first)
        try await takeAway(store, rig: rig, on: first)

        await first.drop()
        await second.acceptUpgrade()
        store.takeSize()
        let notSent = try #require(AttachTerminalStore.sizeTakeFailure(.notSent))
        try await waitUntil("nothing sent") { store.sizeNotice?.phase == .failed(notSent) }
        _ = await second.nextHello()
        await second.sendWelcome(resumed)
        try await waitUntil("the resumed link") { await second.requests.contains { $0.method == "server.status" } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.status == .live)
        #expect(await ownership(second).isEmpty)
        await store.stop()
        #expect(await ownership(first) == [Self.take])
    }

    // MARK: Fresh clients and connections

    /// A take is never sent again by the attach that sent it: a fresh client
    /// that replaces its client takes the size afresh, for the reattach in
    /// the same showing, and gives back only that; the old attach's give
    /// back finds no link of its client's.
    @Test func aFreshClientTakesAfreshAndNothingGoesBackForTheOld() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = FakeRexServer()
        await rig.world.install(on: second, client: Self.freshClient)
        await rig.endpoint.tickets.install(on: second, client: Self.freshClient)
        await rig.reads.install(on: second)
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = Self.freshClient
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: fresh)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: first)

        await first.drop()
        try await waitUntil("the reattach's take") { await ownership(second) == [Self.take] }
        await rig.begin(stream: 1, columns: 80, rows: 24, owner: Self.freshClient)
        try await waitUntil("the fresh paint") { store.status == .live && store.sizeReport?.client == Self.freshClient }
        #expect(store.sizeNotice == nil)
        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(second) == [Self.take, Self.giveBack] }
        await store.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second) == [Self.take, Self.giveBack])
    }

    /// A new SSH connection is another connection: the old attach's give back
    /// is not sent over it.
    @Test func aNewSSHConnectionGetsNothingOfTheOldAttach() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        let firstHost = await rig.host([.server(first)])
        let session = hostSession([firstHost, await rig.host([.server(second)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: first)
        try await takeAway(store, rig: rig, on: first)

        try await firstHost.close()
        await first.drop()
        await rig.begin(stream: 1, columns: 100, rows: 30)
        try await waitUntil("the fresh paint") { store.status == .live && session.currentConnectionGeneration == 1 }
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second).isEmpty)
    }

    // MARK: Giving back

    /// An attach that ends on its own, here for refused input, gives back
    /// the size it took before it goes.
    @Test func anAttachThatEndsGivesItBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.answer(
            RexInventoryWire.terminalMethod("write"),
            with: .error(code: "invalid_params", message: "refused", status: 400))
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openShown(rig, session: session, on: control, input: input)

        #expect(input.send(Data("one\r".utf8)))
        try await waitUntil("the end") {
            if case .ended = store.status { true } else { false }
        }
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// An attach that ends while no link is its client's, here for keys typed
    /// while the link resumes, cannot give the size back. The next attach of
    /// the block on the same client, which the server gives the block back
    /// to, gives it back once the view leaves, once. Another client took the
    /// size in the showing, so the next attach takes nothing.
    @Test func theNextAttachOnTheSameClientGivesBackWhatTheLastCouldNot() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openShown(rig, session: session, on: first, input: input)
        try await takeAway(store, rig: rig, on: first)

        await first.drop()
        await second.acceptUpgrade()
        #expect(input.send(Data("one\r".utf8)))
        try await waitUntil("the reconnect") { store.status == .reconnecting }
        _ = await second.nextHello()
        await second.sendWelcome(resumed)
        await rig.begin(stream: 1, columns: 100, rows: 30)
        try await waitUntil("the new paint") { store.status == .live }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(second).isEmpty)

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(second) == [Self.giveBack] }
        await store.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second) == [Self.giveBack])
    }

    /// An attach that ends for input lost with its link, and is not opened
    /// again, leaves the size it could not give back to the Host session,
    /// which gives it back once a link takes the client back.
    @Test func aSizeNoAttachCouldGiveBackGoesBackOnceTheClientResumes() async throws {
        let rig = Rig()
        let first = await rig.server()
        await first.stopAnswering(RexInventoryWire.terminalMethod("write"))
        let second = await rig.server()
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openShown(rig, session: session, on: first, input: input)

        #expect(input.send(Data("one\r".utf8)))
        try await waitUntil("the write") {
            await requests(first, RexInventoryWire.terminalMethod("write")).count == 1
        }
        await first.drop()
        try await waitUntil("the end") {
            if case .ended = store.status { true } else { false }
        }
        #expect(await ownership(first) == [Self.take])

        await second.acceptUpgrade()
        _ = await second.nextHello()
        await second.sendWelcome(resumed)
        try await waitUntil("the give back") { await ownership(second) == [Self.giveBack] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(second) == [Self.giveBack])
        #expect(rig.world.owner(of: "block:left") == nil)
        await store.stop()
    }

    /// After another device takes the size the notice returns, and leaving
    /// takes this client out of line, so the block is never passed to it
    /// once it has gone.
    @Test func anotherDeviceTakingItBringsTheNoticeBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)
        try await takeAway(store, rig: rig, on: control)

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// A block the server passed to this client because the device that took
    /// it dropped stays as the server made it, for that device to get back
    /// when it resumes: neither leaving nor ending gives it back, and the
    /// next showing finds it this client's and takes nothing.
    @Test func aSizeTheServerHandedOverIsLeftAlone() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)

        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "take")
        try await waitUntil("the other device's take") { store.sizeReport?.owner == Self.otherDevice }
        await pushOwner(control, Self.thisClient, previous: Self.otherDevice, reason: "lost")
        try await waitUntil("the hand-over") { store.sizeReport?.owner == Self.thisClient }
        store.setViewed(false)
        store.setViewed(true)
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(control) == [Self.take])
    }

    /// A block the server handed over stays as it is only while it is this
    /// client's: once the device that dropped resumes and gets it back,
    /// with no attach of the block open to hear it, the next showing takes
    /// the size as it opens, and gives it back as it leaves.
    @Test func aHandedOverBlockItsOwnerGotBackIsTakenByTheNextShowing() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let first = try await openShown(rig, session: session, on: control)
        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "take")
        try await waitUntil("the other device's take") { first.sizeReport?.owner == Self.otherDevice }
        await pushOwner(control, Self.thisClient, previous: Self.otherDevice, reason: "lost")
        try await waitUntil("the hand-over") { first.sizeReport?.owner == Self.thisClient }
        await first.stop()
        #expect(await ownership(control) == [Self.take])

        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "restore")
        try await Task.sleep(for: .milliseconds(100))
        let second = store(session)
        second.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the next showing's take") { await ownership(control) == [Self.take, Self.take] }
        await rig.begin(stream: 1, columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the new paint") { second.status == .live }
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.lastIndex(of: Self.take))
        let streamed = try #require(methods.lastIndex(of: "data.connect"))
        #expect(taken < streamed)
        await second.stop()
        #expect(await ownership(control) == [Self.take, Self.take, Self.giveBack])
    }

    /// A block passed to this client because the device that took it let go
    /// of it, or left with a close frame, has nobody to go back to: leaving
    /// gives it back like the size the view took.
    @Test(arguments: ["disown", "disconnect"])
    func aSizeTheOwnerLetGoOfIsGivenBack(reason: String) async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openShown(rig, session: session, on: control)

        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "take")
        try await waitUntil("the other device's take") { store.sizeReport?.owner == Self.otherDevice }
        await pushOwner(control, Self.thisClient, previous: Self.otherDevice, reason: reason)
        try await waitUntil("the hand-over") { store.sizeReport?.owner == Self.thisClient }
        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// A give back asked for while the take is out waits for its answer, so
    /// the two never overlap: here the view leaves while the attach takes the
    /// size as it opens, and gives back what it took once the answer comes.
    @Test func takingAndGivingBackNeverOverlap() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = store(session)
        store.viewDidResize(cols: 80, rows: 24)

        let take = await control.nextRequest()
        #expect(take.method == Self.take)
        store.setViewed(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control) == [Self.take])
        await control.respond(
            to: take, with: ["blocks": [["block_id": "block:left", "owner": .string(Self.thisClient)]]])
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.firstIndex(of: Self.take))
        let given = try #require(methods.firstIndex(of: Self.giveBack))
        #expect(methods[taken..<given].contains(Self.resize))
        await store.stop()
    }

    // MARK: A Rex Agent's Terminal surface (ADR 0056)

    /// An Agent detail's Attach over the same runner, as a Rex Agent's
    /// Terminal surface makes it.
    private func agent(_ session: RexHostSession) -> AgentAttachStore {
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: RexTerminalAttachTests.socket))
        let runner = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), onChange: {}
        ).terminalRunner()
        let pin = TerminalCorePin()
        return AgentAttachStore(
            target: RexTerminalAttachTests.address.paneID, paneTitle: "codex", transportGeneration: nil,
            isOnStage: { true },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) },
            closePane: {})
    }

    /// A Rex Agent's Terminal surface follows the terminal screen's rule:
    /// shown, it takes the size before the first paint; kept off screen, as
    /// the retention pool keeps it while Chat or another screen shows, it
    /// gives it back; back on screen it takes it again. Another device's
    /// take brings the notice, which the surface forwards, and the user can
    /// keep that size for the showing.
    @Test func aRexAgentsTerminalSurfaceFitsAsTheTerminalScreenDoes() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let attach = agent(session)
        attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the opening take") { await ownership(control) == [Self.take] }
        await rig.begin(columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the first paint") { attach.terminal.status == .live }
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.firstIndex(of: Self.take))
        let streamed = try #require(methods.firstIndex(of: "data.connect"))
        #expect(taken < streamed)
        #expect(attach.sizeNotice == nil)

        attach.setTerminalViewed(false)
        try await waitUntil("the give back off screen") { await ownership(control) == [Self.take, Self.giveBack] }
        attach.setTerminalViewed(true)
        try await waitUntil("the take back on screen") {
            await ownership(control) == [Self.take, Self.giveBack, Self.take]
        }

        try await takeAway(attach.terminal, rig: rig, on: control)
        #expect(attach.sizeNotice?.phase == .offered)
        attach.dismissSizeNotice()
        #expect(attach.sizeNotice == nil)
        #expect(!attach.terminal.sizeShowing.fitsOnItsOwn)
        // The scene going to the background ends the showing, which leaves
        // the other device's line; coming back is the next showing.
        attach.sceneDidEnterBackground()
        try await waitUntil("out of line in the background") { await ownership(control).count == 4 }
        attach.sceneDidBecomeActive()
        try await waitUntil("the next showing's take") {
            await ownership(control) == [Self.take, Self.giveBack, Self.take, Self.giveBack, Self.take]
        }
        await attach.leave().value
        #expect(await ownership(control).last == Self.giveBack)
    }

    /// An Agent detail's Attach replaced after a possible suspension carries
    /// its showing to the new pipeline, which takes the size as it opens,
    /// before its stream starts, and the old one takes nothing on its way
    /// out.
    @Test func aRexAgentsReplacedAttachTakesTheSizeAsItOpens() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let attach = agent(session)
        attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the opening take") { await ownership(control) == [Self.take] }
        await rig.begin(columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the first paint") { attach.terminal.status == .live }

        let first = attach.terminal
        attach.sceneDidEnterBackground()
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        attach.sceneDidBecomeActive()
        attach.didBecomeActive(activation: 1, afterPossibleSuspension: true)
        try await waitUntil("the replacement") { attach.terminal !== first }
        #expect(attach.terminal.sizeShowing.fitsOnItsOwn)
        #expect(!attach.terminal.sizeShowing.isSceneInBackground)

        attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the new attach's take") { await requests(control, Self.take).count == 2 }
        await rig.begin(stream: 1, columns: 80, rows: 24, owner: Self.thisClient)
        try await waitUntil("the new paint") { attach.terminal.status == .live }
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.lastIndex(of: Self.take))
        let streamed = try #require(methods.lastIndex(of: "data.connect"))
        #expect(taken < streamed)
        await attach.leave().value
    }
}
