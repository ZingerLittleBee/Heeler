import Foundation
import Testing

@testable import Heeler

/// A native Windows core Host in the Console, through `ConsoleStore`: where its
/// Terminals land by their Windows directories, and what it offers while each later
/// Windows ticket has yet to turn its action on.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWindowsConsoleTests {
    private let host = Host(address: "win.example", username: "me", serverKind: .herdrCore)

    private static func record(
        _ address: String, cwd: String, labels: [String: String] = [:], argv: [String] = [#"C:\Windows\System32\cmd.exe"#]
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7), "keep": .bool(false),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private func started(_ terminals: [JSONValue], services: any HostServices) async throws -> ConsoleStore {
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
            ], services: services)
        await transport.setKernel(HerdrCoreLocator.windowsKernel)
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            coreHostMemory: HerdrCoreHostMemory(
                defaults: UserDefaults(suiteName: "core-windows-\(UUID().uuidString)") ?? .standard))
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return store
    }

    /// A Console over the real `HerdrCoreSSHTransport`, so what it says of a Host's
    /// platform is what the real path says. `before` runs ahead of each connection.
    private func storeOnScripted(
        _ scripted: ScriptedCoreHost, session: String = "work", memory: HerdrCoreHostMemory? = nil,
        before: @escaping @Sendable () async throws -> Void = {}
    ) -> ConsoleStore {
        ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: {
                        try await before()
                        await scripted.setConnected(true)
                        return scripted.transport(session: session)
                    }, keepalive: nil)
            },
            coreHostMemory: memory
                ?? HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-windows-\(UUID().uuidString)") ?? .standard))
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func finish(_ store: ConsoleStore) async {
        store.setHosts([])
        await store.suspend()
    }

    // MARK: Windows directories

    @Test func terminalsLandInDerivedWorkspacesKeyedByTheirWindowsDirectories() async throws {
        let store = try await started(
            [
                Self.record("t1", cwd: #"C:\Users\me\src\api"#),
                Self.record("t2", cwd: #"C:\Users\me\src\api"#),
                Self.record("t3", cwd: #"D:\work\web\"#),
            ], services: ScriptedCoreServices(platform: .nativeWindows))
        try await waitUntil("the Terminals") { store.terminals.count == 3 }

        let workspaces = store.workspaces(for: host.id)
        #expect(Set(workspaces.map(\.label)) == ["api", "web"])
        let api = try #require(workspaces.first { $0.label == "api" })
        #expect(api.id == HerdrCoreOrganization.workspaceID(directory: #"C:\Users\me\src\api"#))
        #expect(store.terminals.first { $0.paneID == "t1" }?.workspaceID == api.id)
        #expect(store.terminals.first { $0.paneID == "t2" }?.workspaceID == api.id)
        #expect(store.terminals.first { $0.paneID == "t3" }?.workspaceID != api.id)
        await finish(store)
    }

    private func labelOnlySpace(
        at directory: String, gitRoots: [String: String]
    ) async throws -> (store: ConsoleStore, scripted: ScriptedCoreHost) {
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            channel: .core(.init(terminals: [
                Self.record("t1", cwd: directory, labels: ["herdr.space": "lonely"])
            ])))
        await scripted.setWindowsGitRoots(gitRoots)
        let store = storeOnScripted(scripted)
        store.setHosts([host])
        await store.resume()
        return (store, scripted)
    }

    /// From a subfolder of a repository, the space is named for the repository,
    /// through the real transport's Windows path. Git for Windows prints `/`.
    @Test func aLabelOnlySpaceIsNamedForItsCheckoutFolder() async throws {
        let directory = #"C:\Users\me\src\api\pkg"#
        let (store, scripted) = try await labelOnlySpace(
            at: directory, gitRoots: [directory: "C:/Users/me/src/api"])

        try await waitUntil("the checkout's name") {
            store.workspaces(for: host.id).first?.label == "api"
        }
        #expect(await scripted.log.contains("windows-checkouts"))
        #expect(await scripted.posixCheckoutAsks == 0)
        // Worktrees stay off: a root says nothing of which repository it is.
        #expect(store.workspaces(for: host.id).first?.checkoutPath == nil)
        await finish(store)
    }

    @Test func aLabelOnlySpaceOutsideGitIsNamedForItsFolder() async throws {
        let (store, scripted) = try await labelOnlySpace(at: #"C:\Users\me\notes\"#, gitRoots: [:])

        try await waitUntil("the read") { await scripted.log.contains("windows-checkouts") }
        try await waitUntil("the folder's name") {
            store.workspaces(for: host.id).first?.label == "notes"
        }
        await finish(store)
    }

    /// A checkout at the home folder reads `~`, however git spells its path.
    @Test func aCheckoutAtTheHomeFolderReadsTilde() async throws {
        let directory = #"C:\Users\me\dotfiles"#
        let (store, _) = try await labelOnlySpace(at: directory, gitRoots: [directory: "C:/Users/me"])

        try await waitUntil("the home folder's name") {
            store.workspaces(for: host.id).first?.label == "~"
        }
        await finish(store)
    }

    /// Asks again on the next link, as a Unix read that failed does.
    @Test func aCheckoutReadThatWasCutShortDoesNotNameTheSpace() async throws {
        let directory = #"C:\Users\me\src\api\pkg"#
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            channel: .core(.init(terminals: [
                Self.record("t1", cwd: directory, labels: ["herdr.space": "lonely"])
            ])))
        await scripted.setWindowsGitRoots([directory: "C:/Users/me/src/api"])
        await scripted.setWindowsCheckoutAnswer(
            GitExecResult(stdout: Data("\(ScriptedCoreHost.nonce) begin\n".utf8), stderr: Data(), exitStatus: 0))
        let store = storeOnScripted(scripted)
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the first read") { await scripted.log.contains("windows-checkouts") }
        try await waitUntil("the directory's name") { store.workspaces(for: host.id).first?.label == "pkg" }

        await scripted.setWindowsCheckoutAnswer(nil)
        await store.retryHost(host.id)
        try await waitUntil("the checkout's name") { store.workspaces(for: host.id).first?.label == "api" }
        await finish(store)
    }

    /// The Chat read refuses native Windows, so the name comes from the locator.
    @Test func aSpaceInTheWindowsHomeFolderReadsTilde() async throws {
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            channel: .core(.init(terminals: [
                Self.record("t1", cwd: #"C:\Users\me"#, labels: ["herdr.space": "lonely"])
            ])))
        let store = storeOnScripted(scripted)
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the home folder's name") {
            store.workspaces(for: host.id).first?.label == "~"
        }
        let log = await scripted.log
        #expect(!log.contains { $0.hasPrefix("open") })
        #expect(!log.contains("locator"))
        await finish(store)
    }

    @Test func aTerminalsProgramIsNamedWithoutItsWindowsFolder() async throws {
        let store = try await started(
            [Self.record("t1", cwd: #"C:\work"#, argv: [#"C:\Program Files\PowerShell\7\pwsh.exe"#, "-NoLogo"])],
            services: ScriptedCoreServices(platform: .nativeWindows))
        try await waitUntil("the Terminal") { store.terminals.count == 1 }

        #expect(store.terminals.first?.pane.title == "pwsh.exe")
        await finish(store)
    }

    // MARK: What it offers

    /// New Agent, New Terminal, New Workspace, staging, Send and Stop are on, its name
    /// field and Rename off, and what later tickets turn on stays hidden.
    private func expectWindowsOffers(_ offers: HostCapabilities, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!offers.renameAgent, sourceLocation: sourceLocation)
        #expect(!offers.renameWorkspace(id: "space-s1"), sourceLocation: sourceLocation)
        #expect(!offers.worktrees, sourceLocation: sourceLocation)
        #expect(offers.startsAgents, sourceLocation: sourceLocation)
        #expect(offers.startsTerminals, sourceLocation: sourceLocation)
        #expect(offers.newTerminalRequest(workspaceID: "w", cwd: #"C:\work"#) != nil, sourceLocation: sourceLocation)
        #expect(!offers.namesNewWorkspaces, sourceLocation: sourceLocation)
        #expect(offers.uploads, sourceLocation: sourceLocation)
        #expect(offers.composerSend, sourceLocation: sourceLocation)
        #expect(offers.composerStop, sourceLocation: sourceLocation)
        #expect(!offers.chat, sourceLocation: sourceLocation)
    }

    @Test func aConnectedWindowsCoreHostOffersWhatItsTicketsTurnedOn() async throws {
        let store = try await started(
            [Self.record("t1", cwd: #"C:\work"#)], services: ScriptedCoreServices(platform: .nativeWindows))
        try await waitUntil("the kernel") { store.hostCoreKernels[host.id] == HerdrCoreLocator.windowsKernel }

        let offers = store.capabilities(for: host.id)
        expectWindowsOffers(offers)
        #expect(offers.closeTab)
        #expect(!offers.takeOver)

        let hosts = [host]
        #expect(hosts.offeringNewItem(listsTerminals: true) { store.capabilities(for: $0.id) } == hosts)
        #expect(hosts.offeringNewItem(listsTerminals: false) { store.capabilities(for: $0.id) } == hosts)
        await finish(store)
    }

    @Test func thePlatformAloneSaysTheSame() {
        expectWindowsOffers(HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows))
        expectWindowsOffers(HostCapabilities(serverKind: .herdrCore, coreKernel: HerdrCoreLocator.windowsKernel))
    }

    /// A stopped core has no snapshot, and what it offers must not wait for one.
    @Test func aWindowsHostWhoseCoreIsStoppedOffersTheSameAndConnectsToNothing() async throws {
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(pipe: false), channel: .core(.init()))
        let store = storeOnScripted(scripted)
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the kernel") { store.hostCoreKernels[host.id] == HerdrCoreLocator.windowsKernel }

        expectWindowsOffers(store.capabilities(for: host.id))
        #expect(await scripted.connectCommands.isEmpty)
        await finish(store)
    }

    /// These stop the session for good, so nothing later would bring the kernel.
    @Test func aWindowsHostThatCannotConnectStillHidesWhatWindowsLacks() async throws {
        let cases: [(what: String, scripted: ScriptedCoreHost, session: String)] = [
            (
                "update required",
                ScriptedCoreHost(
                    windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
                    channel: .answersHello(ScriptedCoreHost.helloReply(features: ["framed"]))),
                "work"
            ),
            (
                "not installed",
                ScriptedCoreHost(
                    windowsLocator: ScriptedCoreHost.windowsLocatorLines(executable: nil), channel: .core(.init())),
                "work"
            ),
            (
                "a session name it refuses",
                ScriptedCoreHost(windowsLocator: ScriptedCoreHost.windowsLocatorLines(), channel: .core(.init())),
                "my work"
            ),
        ]
        for (what, scripted, session) in cases {
            let store = storeOnScripted(scripted, session: session)
            store.setHosts([host])
            await store.resume()

            try await waitUntil("\(what) to stop the session") {
                if case .failed = store.hostStatuses[host.id] { return true }
                return false
            }
            try await waitUntil("the kernel after \(what)") {
                store.hostCoreKernels[host.id] == HerdrCoreLocator.windowsKernel
            }

            expectWindowsOffers(store.capabilities(for: host.id))
            await finish(store)
        }
    }

    /// Nothing can start before the first locator says what this Host is.
    @Test func aCoreHostBeingLocatedForTheFirstTimeOffersNothingToStartYet() async throws {
        let gate = ScriptedTransportCallGate()
        let scripted = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(socketFile: true), channel: .core(.init()))
        let store = storeOnScripted(scripted, before: { await gate.waitUntilOpen() })
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the first attempt") { store.hostStatuses[host.id] == .connecting }
        #expect(!store.capabilities(for: host.id).startsAgents)
        #expect(!store.capabilities(for: host.id).startsTerminals)
        #expect(![host].offersNewItem(listsTerminals: true) { store.capabilities(for: $0.id) })

        await gate.open()
        try await waitUntil("the kernel") { store.capabilities(for: host.id).startsAgents }
        #expect(store.capabilities(for: host.id).startsTerminals)
        await finish(store)
    }

    /// A relaunch knows before the Host answers, or whether it answers at all.
    @Test func aWindowsHostOnceLocatedHidesWhatWindowsLacksWhileItCannotBeReached() async throws {
        let defaults = try #require(UserDefaults(suiteName: "core-windows-\(UUID().uuidString)"))
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(pipe: false), channel: .core(.init()))
        let first = storeOnScripted(scripted, memory: HerdrCoreHostMemory(defaults: defaults))
        first.setHosts([host])
        await first.resume()
        try await waitUntil("the kernel") { first.hostCoreKernels[host.id] == HerdrCoreLocator.windowsKernel }
        // Not `finish`: a Host taken off the catalog takes its memory along.
        await first.suspend()

        let relaunched = storeOnScripted(
            scripted, memory: HerdrCoreHostMemory(defaults: defaults),
            before: { throw TransportError.sshUnreachable(detail: "gone") })
        relaunched.setHosts([host])
        expectWindowsOffers(relaunched.capabilities(for: host.id))
        await relaunched.resume()
        try await waitUntil("the failed attempt") {
            if case .reconnecting = relaunched.hostStatuses[host.id] { return true }
            return false
        }
        expectWindowsOffers(relaunched.capabilities(for: host.id))
        await finish(relaunched)
    }

    /// Another core on the machine is still that machine.
    @Test func aHostsKernelOutlivesItsCore() throws {
        let defaults = try #require(UserDefaults(suiteName: "core-windows-\(UUID().uuidString)"))
        let memory = HerdrCoreHostMemory(defaults: defaults)
        memory.noteCore("c1", for: host.id)
        memory.noteKernel(HerdrCoreLocator.windowsKernel, for: host.id)
        memory.noteCore("c2", for: host.id)
        #expect(HerdrCoreHostMemory(defaults: defaults).kernel(for: host.id) == HerdrCoreLocator.windowsKernel)
    }

    /// The machine behind a Host's address can change.
    @Test func aRememberedKernelGivesWayToTheOneTheLocatorFinds() async throws {
        let defaults = try #require(UserDefaults(suiteName: "core-windows-\(UUID().uuidString)"))
        let memory = HerdrCoreHostMemory(defaults: defaults)
        memory.noteKernel(HerdrCoreLocator.windowsKernel, for: host.id)
        let scripted = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(socketFile: true), channel: .core(.init()))
        let store = storeOnScripted(scripted, memory: memory)
        store.setHosts([host])
        #expect(store.capabilities(for: host.id).uploads)
        await store.resume()

        try await waitUntil("the Host's own kernel") { store.hostCoreKernels[host.id] == "Linux" }
        #expect(memory.kernel(for: host.id) == "Linux")
        await finish(store)
    }

    /// The other direction: nothing about a Unix core Host changes.
    @Test func aUnixCoreHostStillStartsAgentsAndTerminals() {
        for platform in [HostPlatform?.none, .posix] {
            let offers = HostCapabilities(serverKind: .herdrCore, platform: platform, coreKernel: "Linux")
            #expect(offers.startsAgents)
            #expect(offers.startsTerminals)
        }
        // And a Herdr TUI Host's are its own, on Windows too.
        let tui = HostCapabilities(serverKind: .herdrTUI, platform: .nativeWindows)
        #expect(tui.startsAgents)
        #expect(tui.renameAgent)
        #expect(tui.worktrees)
    }

    // MARK: What a Host says when its core is stopped

    @Test func notRunningOnWindowsSaysHowToStartItOnThatMachine() {
        let presentation = TransportError.herdrCoreNotRunning(
            socketPath: ScriptedCoreHost.windowsPipe, socketFilePresent: false
        ).presentation
        #expect(presentation.summary == "herdr-core is not running")
        #expect(presentation.detail?.contains(ScriptedCoreHost.windowsPipe) == true)
        #expect(presentation.recoverySuggestion?.contains("desktop session") == true)
        #expect(presentation.recoverySuggestion?.contains("PowerShell") == true)
        #expect(TransportError.herdrCoreNotRunning(
            socketPath: ScriptedCoreHost.windowsPipe, socketFilePresent: false
        ).isRetryable)
    }
}
