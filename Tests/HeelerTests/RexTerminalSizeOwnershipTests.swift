import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// Taking a Rex terminal's size for the view and giving it back (ADR 0051),
/// from the store the view uses to a fake server's block: only a tap takes
/// it, once, through the same gate as input; what the user took goes back
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
        _ session: RexHostSession, input: TerminalInputController = TerminalInputController()
    ) -> AttachTerminalStore {
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: RexTerminalAttachTests.socket))
        let runner = RexConsoleProjection(host: host, session: session, onChange: {}).terminalRunner()
        let pin = TerminalCorePin()
        return AttachTerminalStore(
            target: .terminal(RexTerminalAttachTests.address.paneID), input: input,
            settleSizeNotice: { try await Task.sleep(for: .milliseconds(30)) },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })
    }

    /// A live 80x24 view of a block another device sized 100x30.
    private func openSizedElsewhere(
        _ rig: Rig, session: RexHostSession, stream: Int = 0,
        input: TerminalInputController = TerminalInputController()
    ) async throws -> AttachTerminalStore {
        let store = store(session, input: input)
        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin(stream: stream, columns: 100, rows: 30)
        try await waitUntil("the first paint") { store.status == .live }
        try await waitUntil("the notice") { store.sizeNotice?.phase == .offered }
        return store
    }

    /// Takes the size from the notice, and waits for the view's grid to be
    /// asked for as the block's owner.
    private func takeFromTheNotice(_ store: AttachTerminalStore, on server: FakeRexServer) async throws {
        let before = await requests(server, Self.resize).count
        store.takeSize()
        try await waitUntil("the take and the size after it") {
            let takes = await requests(server, Self.take).count
            let resizes = await requests(server, Self.resize).count
            return takes == 1 && resizes > before
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

    // MARK: Taking

    /// The notice's action takes the block for this client, then asks for
    /// the view's grid as its owner; the notice goes, and ending the attach
    /// gives the size back.
    @Test func aTapTakesTheSizeAndAsksForTheViewsGrid() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        #expect(store.sizeNotice?.server == .init(columns: 100, rows: 30))
        #expect(await ownership(control).isEmpty)

        try await takeFromTheNotice(store, on: control)
        let take = try #require(await requests(control, Self.take).first)
        #expect(
            take.payload == ["session_id": "session:studio", "block_ids": ["block:left"], "mode": "take"])
        let methods = await control.requests.map(\.method)
        let taken = try #require(methods.firstIndex(of: Self.take))
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
        let giveBack = try #require(await requests(control, Self.giveBack).first)
        #expect(giveBack.payload == ["session_id": "session:studio", "block_ids": ["block:left"]])
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// Nothing takes the size without a tap: not opening, not the owner
    /// letting go, not leaving and coming back, not the app's return, not a
    /// fresh client that paints afresh, and not ending.
    @Test func nothingTakesTheSizeWithoutATap() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = Self.freshClient
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: fresh)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)

        await pushOwner(first, nil, previous: Self.otherDevice, reason: "disconnect")
        try await waitUntil("no owner") { store.sizeReport?.owner == nil }
        try await waitUntil("the notice to go") { store.sizeNotice == nil }
        await pushOwner(first, Self.otherDevice, previous: nil, reason: "take")
        store.setViewed(false)
        store.setViewed(true)
        store.didBecomeActive()
        store.sceneDidEnterBackground()
        try await Task.sleep(for: .milliseconds(100))

        await first.drop()
        await rig.begin(stream: 1, columns: 100, rows: 30)
        try await waitUntil("the fresh paint") { store.status == .live && store.sizeReport?.client == Self.freshClient }
        try await waitUntil("the notice again") { store.sizeNotice?.phase == .offered }
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(first).isEmpty)
        #expect(await ownership(second).isEmpty)
    }

    /// A take is never sent again: not when its client is replaced by a
    /// fresh one, whose new attach never took and so gives nothing back, and
    /// not by the old attach, whose give back finds no link of its client's.
    @Test func aFreshClientNeverTakesAgainNorGivesBackForTheOld() async throws {
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
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: first)

        await first.drop()
        await rig.begin(stream: 1, columns: 100, rows: 30)
        try await waitUntil("the fresh paint") { store.status == .live && store.sizeReport?.client == Self.freshClient }
        try await waitUntil("the notice again") { store.sizeNotice?.phase == .offered }
        store.setViewed(false)
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second).isEmpty)
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
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: first)

        try await firstHost.close()
        await first.drop()
        await rig.begin(stream: 1, columns: 100, rows: 30)
        try await waitUntil("the fresh paint") { store.status == .live && session.currentConnectionGeneration == 1 }
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(first) == [Self.take])
        #expect(await ownership(second).isEmpty)
    }

    /// A refused take says so, asks for no size, and leaves nothing to give
    /// back.
    @Test func aRefusedTakeSaysSoAndGivesNothingBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        await control.answer(Self.take, with: .error(code: "conflict", message: "attach first", status: 409))
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        let resizes = await requests(control, Self.resize).count

        store.takeSize()
        let refused = try #require(AttachTerminalStore.sizeTakeFailure(.refused))
        try await waitUntil("the refusal") { store.sizeNotice?.phase == .failed(refused) }
        store.setViewed(false)
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(control) == [Self.take])
        #expect(await requests(control, Self.resize).count == resizes)
    }

    /// A take with no answer by its deadline is never sent again, and says
    /// so; it may have arrived, so leaving gives it back.
    @Test func anUnansweredTakeIsNeverSentAgainButIsGivenBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        let session = hostSession([await rig.host([.server(control)])], inputDeadline: .milliseconds(150))
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)

        store.takeSize()
        #expect(store.sizeNotice?.phase == .taking)
        _ = await control.nextRequest()
        let unknown = try #require(AttachTerminalStore.sizeTakeFailure(.unknown))
        try await waitUntil("no answer") { store.sizeNotice?.phase == .failed(unknown) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ownership(control) == [Self.take])
        #expect(store.status == .live)

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// A take while no link is the terminal's is not sent, and not sent once
    /// a link takes the client back.
    @Test func aTakeWithNoLinkIsNotSent() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)

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
        await store.stop()
        #expect(await ownership(first).isEmpty)
        #expect(await ownership(second).isEmpty)
    }

    // MARK: Giving back

    /// Leaving the view gives back what the user took; coming back takes
    /// nothing, and nothing is given back twice.
    @Test func leavingGivesTheSizeBackAndComingBackTakesNothing() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: control)

        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        #expect(rig.world.owner(of: "block:left") == nil)
        store.setViewed(true)
        store.didBecomeActive()
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// The scene going to the background gives the size back too.
    @Test func theSceneGoingToTheBackgroundGivesItBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: control)

        store.sceneDidEnterBackground()
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        store.didBecomeActive()
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// An attach that ends on its own, here for refused input, gives back
    /// what the user took before it goes.
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
        let store = try await openSizedElsewhere(rig, session: session, input: input)
        try await takeFromTheNotice(store, on: control)

        #expect(input.send(Data("one\r".utf8)))
        try await waitUntil("the end") {
            if case .ended = store.status { true } else { false }
        }
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// An attach that ends while no link is its client's, here for keys typed
    /// while the link resumes, cannot give the size back. The next attach of
    /// the block on the same client, which the server gives the block back
    /// to, gives it back once the view leaves, once.
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
        let store = try await openSizedElsewhere(rig, session: session, input: input)
        try await takeFromTheNotice(store, on: first)

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
        let store = try await openSizedElsewhere(rig, session: session, input: input)
        try await takeFromTheNotice(store, on: first)

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

    /// After another device takes the size back the notice returns, and
    /// leaving takes this client out of line, so the block is never passed
    /// to it once it has gone.
    @Test func anotherDeviceTakingItBackBringsTheNoticeBack() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: control)

        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "take")
        try await waitUntil("the notice again") { store.sizeNotice?.phase == .offered }
        store.setViewed(false)
        try await waitUntil("the give back") { await ownership(control) == [Self.take, Self.giveBack] }
        await store.stop()
        #expect(await ownership(control) == [Self.take, Self.giveBack])
    }

    /// A block the server passed to this client because the device that took
    /// it back dropped stays as the server made it, for that device to get
    /// back when it resumes: neither leaving nor ending gives it back.
    @Test func aSizeTheServerHandedOverIsLeftAlone() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: control)

        await pushOwner(control, Self.otherDevice, previous: Self.thisClient, reason: "take")
        try await waitUntil("the other device's take") { store.sizeReport?.owner == Self.otherDevice }
        await pushOwner(control, Self.thisClient, previous: Self.otherDevice, reason: "lost")
        try await waitUntil("the hand-over") { store.sizeReport?.owner == Self.thisClient }
        store.setViewed(false)
        try await Task.sleep(for: .milliseconds(100))
        await store.stop()
        #expect(await ownership(control) == [Self.take])
    }

    /// A block passed to this client because the device that took it back
    /// let go of it, or left with a close frame, has nobody to go back to:
    /// leaving gives it back like the size the user took.
    @Test(arguments: ["disown", "disconnect"])
    func aSizeTheOwnerLetGoOfIsGivenBack(reason: String) async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)
        try await takeFromTheNotice(store, on: control)

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
    /// the two never overlap.
    @Test func takingAndGivingBackNeverOverlap() async throws {
        let rig = Rig()
        let control = await rig.server()
        await control.stopAnswering(Self.take)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openSizedElsewhere(rig, session: session)

        store.takeSize()
        let take = await control.nextRequest()
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
}
