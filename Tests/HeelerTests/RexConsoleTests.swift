import Foundation
import Synchronization
import Testing

@testable import Heeler

/// What a Rex Host offers and how the Console shows it while this build does
/// not connect to Rex (ADR 0047): nothing to start, close or rename, no
/// integrations, and a standing state instead of a connection.
@MainActor
@Suite("Rex Console")
struct RexConsoleTests {
    private nonisolated static let kernels: [String?] = [
        nil, HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel, HerdrCoreLocator.windowsKernel,
    ]

    private var rex: Host {
        Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: "/run/user/1000/rex/server.sock"))
    }

    @Test(arguments: [HostPlatform?.none, .posix, .nativeWindows], Self.kernels)
    func aRexHostOffersNoAction(platform: HostPlatform?, kernel: String?) {
        for isLocatingCore in [false, true] {
            let offers = HostCapabilities(
                serverKind: .rex, platform: platform, coreKernel: kernel, isLocatingCore: isLocatingCore)

            #expect(!offers.startsAgents)
            #expect(!offers.startsTerminals)
            #expect(!offers.renameAgent)
            #expect(!offers.renamesWorkspaces)
            #expect(!offers.namesNewWorkspaces)
            #expect(!offers.worktrees)
            #expect(!offers.uploads)
            #expect(!offers.composerSend)
            #expect(!offers.composerStop)
            #expect(!offers.chat)
            #expect(offers.chatPrograms == [])
            #expect(!offers.tabNames)
            #expect(!offers.closeTab)
            #expect(!offers.syncLayoutFromPlugin)
            #expect(!offers.takeOver)
            #expect(!offers.hostScripts)
            #expect(!offers.isNativeWindowsCore)
        }
        #expect(rex.capabilities == HostCapabilities(serverKind: .rex))
    }

    /// The Notifications, Live Activities and Usage surfaces each pick their
    /// Hosts by kind, and none of them picks a Rex Host.
    @Test func noIntegrationTreatsARexHostAsItsOwn() {
        #expect(!ServerKind.rex.hasHostIntegrations)
        #expect(PreflightCheck.cases(for: .rex) == [.connection, .herdrInstalled, .serverRunning])
        #expect(PreflightCheck.herdrInstalled.title(for: .rex) == "Rex installed")
        #expect(PreflightCheck.serverRunning.title(for: .rex) == "Rex server socket")

        let notifications = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [:]),
            deviceToken: { nil },
            ceremony: NotificationRegistrationCeremony(
                keys: NotificationKeyStore(secrets: InMemorySecretStore())))
        notifications.setHosts([rex])
        #expect(notifications.hosts.isEmpty)
    }

    /// However the Console is woken, a Rex Host's projection asks nothing of
    /// any factory: no Events session, no core, no tmux server.
    @Test func theConsoleNeverDialsARexHost() async {
        let dials = Mutex<[String]>([])
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            makeSession: { _, subscriptions in
                dials.withLock { $0.append("events") }
                return EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        dials.withLock { $0.append("events connect") }
                        return ScriptedTransport()
                    }, keepalive: nil)
            },
            connectCore: { _ in
                dials.withLock { $0.append("core") }
                throw TransportError.sshUnreachable(detail: "unscripted")
            },
            connectTmux: { _ in
                dials.withLock { $0.append("tmux") }
                throw TransportError.sshUnreachable(detail: "unscripted")
            },
            makeCoreSession: { _ in
                dials.withLock { $0.append("core session") }
                return HerdrCoreHostSession { throw TransportError.sshUnreachable(detail: "unscripted") }
            },
            makeTmuxSession: { host in
                dials.withLock { $0.append("tmux session") }
                return TmuxHostSession(storedPaths: host.storedTmuxPaths) { _ in
                    throw TransportError.sshUnreachable(detail: "unscripted")
                }
            })
        defer { store.setHosts([]) }
        let rex = rex

        store.setHosts([rex])
        await store.resume()
        await store.retryHost(rex.id)
        await store.retryFailedHosts()
        await store.reactivate()
        let statuses = HeelerPluginStatusStore()
        await statuses.refresh([rex.id], transports: store)

        #expect(dials.withLock { $0 } == [])
        #expect(store.hostStatuses[rex.id] == .failed(.rexNotConnectableYet))
        #expect(store.agents.isEmpty)
        #expect(store.terminals.isEmpty)
        #expect(store.hostIssues(for: [rex]).map(\.condition) == [.cannotConnect])
        #expect(statuses.status(for: rex.id) == .unsupportedServerKind)
        await #expect(throws: TransportError.rexNotConnectableYet) {
            try await store.remoteHomeDirectory(on: rex.id)
        }
    }

    /// The failure says what is missing and that no retry changes it.
    @Test func theStandingStateSaysThisBuildCannotConnectRex() {
        let error = TransportError.rexNotConnectableYet
        #expect(!error.isRetryable)
        #expect(error.presentation.summary == "Rex support is not finished")
        #expect(error.presentation.message.contains("does not connect to them yet"))
    }
}
