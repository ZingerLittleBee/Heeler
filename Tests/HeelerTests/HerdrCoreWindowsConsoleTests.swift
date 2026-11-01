import Foundation
import Testing

@testable import Heeler

/// A native Windows core Host in the Console, through `ConsoleStore`: where its
/// Terminals land by their Windows directories, and what it offers until each later
/// Windows ticket turns an action on.
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

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
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

    @Test func aLabelOnlySpaceIsNamedForItsCheckoutFolder() async throws {
        let directory = #"C:\Users\me\src\api\pkg"#
        let services = ScriptedCoreServices(
            roots: [directory: #"C:\Users\me\src\api"#], platform: .nativeWindows)
        let store = try await started(
            [Self.record("t1", cwd: directory, labels: ["herdr.space": "lonely"])], services: services)

        try await waitUntil("the checkout's name") {
            store.workspaces(for: host.id).first?.label == "api"
        }
        await finish(store)
    }

    @Test func aLabelOnlySpaceOutsideGitIsNamedForItsFolder() async throws {
        let store = try await started(
            [Self.record("t1", cwd: #"C:\Users\me\notes\"#, labels: ["herdr.space": "lonely"])],
            services: ScriptedCoreServices(platform: .nativeWindows))

        try await waitUntil("the folder's name") {
            store.workspaces(for: host.id).first?.label == "notes"
        }
        await finish(store)
    }

    /// The Chat read refuses native Windows, so the name comes from the locator.
    @Test func aSpaceInTheWindowsHomeFolderReadsTilde() async throws {
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            channel: .core(.init(terminals: [
                Self.record("t1", cwd: #"C:\Users\me"#, labels: ["herdr.space": "lonely"])
            ])))
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: {
                        await scripted.setConnected(true)
                        return scripted.transport()
                    }, keepalive: nil)
            },
            coreHostMemory: HerdrCoreHostMemory(
                defaults: UserDefaults(suiteName: "core-windows-\(UUID().uuidString)") ?? .standard))
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

    private func expectNothingToStart(_ offers: HostCapabilities, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!offers.renameAgent, sourceLocation: sourceLocation)
        #expect(!offers.renameWorkspace(id: "space-s1"), sourceLocation: sourceLocation)
        #expect(!offers.worktrees, sourceLocation: sourceLocation)
        #expect(!offers.startsAgents, sourceLocation: sourceLocation)
        #expect(!offers.startsTerminals, sourceLocation: sourceLocation)
        #expect(offers.newTerminalRequest(workspaceID: "w", cwd: #"C:\work"#) == nil, sourceLocation: sourceLocation)
        #expect(!offers.namesNewWorkspaces, sourceLocation: sourceLocation)
        #expect(!offers.uploads, sourceLocation: sourceLocation)
        #expect(!offers.composerSend, sourceLocation: sourceLocation)
        #expect(!offers.composerStop, sourceLocation: sourceLocation)
        #expect(!offers.chat, sourceLocation: sourceLocation)
    }

    @Test func aConnectedWindowsCoreHostOffersOnlyWhatItsLaterTicketsLeaveOn() async throws {
        let store = try await started(
            [Self.record("t1", cwd: #"C:\work"#)], services: ScriptedCoreServices(platform: .nativeWindows))
        try await waitUntil("the kernel") { !store.capabilities(for: host.id).startsAgents }

        let offers = store.capabilities(for: host.id)
        expectNothingToStart(offers)
        #expect(offers.closeTab)
        #expect(!offers.takeOver)

        let hosts = [host]
        #expect(hosts.offeringNewItem(listsTerminals: true) { store.capabilities(for: $0.id) }.isEmpty)
        #expect(hosts.offeringNewItem(listsTerminals: false) { store.capabilities(for: $0.id) }.isEmpty)
        #expect(!hosts.offersNewItem(listsTerminals: true) { store.capabilities(for: $0.id) })
        #expect(!hosts.offersNewItem(listsTerminals: false) { store.capabilities(for: $0.id) })
        await finish(store)
    }

    @Test func thePlatformAloneHidesThemToo() {
        expectNothingToStart(HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows))
        expectNothingToStart(HostCapabilities(serverKind: .herdrCore, coreKernel: HerdrCoreLocator.windowsKernel))
    }

    /// A stopped core has no snapshot, and New Agent must not wait for one.
    @Test func aWindowsHostWhoseCoreIsStoppedOffersNothingToStartEither() async throws {
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(pipe: false), channel: .core(.init()))
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession(
                    connect: {
                        await scripted.setConnected(true)
                        return scripted.transport()
                    }, keepalive: nil)
            },
            coreHostMemory: HerdrCoreHostMemory(
                defaults: UserDefaults(suiteName: "core-windows-\(UUID().uuidString)") ?? .standard))
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the kernel") { !store.capabilities(for: host.id).startsAgents }

        expectNothingToStart(store.capabilities(for: host.id))
        #expect(await scripted.connectCommands.isEmpty)
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
