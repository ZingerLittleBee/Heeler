#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import SwiftUI
    import UserNotifications

    /// The only entry point for deterministic product screenshots. The
    /// entire implementation is excluded from device and Release builds.
    enum DemoScreenshotMode {
        static let launchArgument = "--demo-screenshots"

        static var isEnabled: Bool {
            isEnabled(arguments: ProcessInfo.processInfo.arguments)
        }

        static func isEnabled(arguments: [String]) -> Bool {
            arguments.contains(launchArgument)
        }
    }

    /// A safe composition root for screenshot runs. It reuses the production
    /// Console, EventsSession, Transport, and terminal surfaces while keeping
    /// Hosts, secrets, settings, notifications, and SSH fully process-local.
    @MainActor
    struct DemoScreenshotRootView: View {
        @State private var hosts: HostStore
        @State private var console: ConsoleStore
        @State private var terminalThemes: TerminalThemeSettings
        @State private var terminalZoom: TerminalZoomSettings
        @State private var terminalFonts: TerminalFontSettings
        @State private var snippets: SnippetStore
        @State private var appearance: AppAppearanceSettings
        @State private var pushRegistration: PushRegistrationStore
        @State private var notificationPreferences: NotificationPreferencesStore
        @State private var relaySettings: NotificationRelaySettings
        @State private var notificationRouter: AgentNotificationRouter
        @State private var bannerStore: AgentNotificationBannerStore
        @State private var activity: AppActivityCoordinator

        init() {
            let composition = DemoScreenshotComposition.make()
            _hosts = State(initialValue: composition.hosts)
            _console = State(initialValue: composition.console)
            _terminalThemes = State(initialValue: composition.terminalThemes)
            _terminalZoom = State(initialValue: composition.terminalZoom)
            _terminalFonts = State(initialValue: composition.terminalFonts)
            _snippets = State(initialValue: composition.snippets)
            _appearance = State(initialValue: composition.appearance)
            _pushRegistration = State(initialValue: composition.pushRegistration)
            _notificationPreferences = State(initialValue: composition.notificationPreferences)
            _relaySettings = State(initialValue: composition.relaySettings)
            _notificationRouter = State(initialValue: composition.notificationRouter)
            _bannerStore = State(initialValue: composition.bannerStore)
            _activity = State(initialValue: composition.activity)
        }

        private var terminal: TerminalSettings {
            TerminalSettings(
                themes: terminalThemes, zoom: terminalZoom, fonts: terminalFonts,
                snippets: snippets)
        }

        var body: some View {
            ConsoleView(
                hosts: hosts,
                console: console,
                terminal: terminal,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                notificationRouter: notificationRouter,
                bannerStore: bannerStore,
                activity: activity
            )
            .preferredColorScheme(appearance.preferredColorScheme)
            .task {
                console.setHosts(hosts.hosts)
                notificationPreferences.setHosts(hosts.hosts)
                await console.resume()
            }
        }
    }

    @MainActor
    struct DemoScreenshotComposition {
        let hosts: HostStore
        let console: ConsoleStore
        let terminalThemes: TerminalThemeSettings
        let terminalZoom: TerminalZoomSettings
        let terminalFonts: TerminalFontSettings
        let snippets: SnippetStore
        let appearance: AppAppearanceSettings
        let pushRegistration: PushRegistrationStore
        let notificationPreferences: NotificationPreferencesStore
        let relaySettings: NotificationRelaySettings
        let notificationRouter: AgentNotificationRouter
        let bannerStore: AgentNotificationBannerStore
        let activity: AppActivityCoordinator

        static func make() -> DemoScreenshotComposition {
            let defaults = DemoScreenshotFixture.makeDefaults()
            let console = DemoScreenshotFixture.makeConsoleStore()
            let pushRegistration = PushRegistrationStore(client: DemoPushRegistrationClient())
            let relaySettings = NotificationRelaySettings(defaults: defaults)
            let notificationRouter = AgentNotificationRouter()
            let notificationPreferences = NotificationPreferencesStore(
                transports: console,
                deviceToken: { nil },
                relayBaseURL: { nil })
            return DemoScreenshotComposition(
                hosts: HostStore(volatileHosts: DemoScreenshotFixture.hosts),
                console: console,
                terminalThemes: TerminalThemeSettings(defaults: defaults),
                terminalZoom: TerminalZoomSettings(defaults: defaults),
                terminalFonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults),
                appearance: AppAppearanceSettings(defaults: defaults),
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                notificationRouter: notificationRouter,
                bannerStore: AgentNotificationBannerStore(
                    presentedAgent: { notificationRouter.path.last },
                    triggers: { _ in nil },
                    playSound: {}),
                activity: AppActivityCoordinator())
        }
    }

    enum DemoScreenshotFixture {
        static let studioHostID = UUID(
            uuid: (
                0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x41, 0x11,
                0x81, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
            ))
        static let buildHostID = UUID(
            uuid: (
                0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x42, 0x22,
                0x82, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
            ))

        static let hosts = [
            Host(
                id: studioHostID,
                name: "Studio Mac",
                address: "studio.demo.invalid",
                username: "developer"),
            Host(
                id: buildHostID,
                name: "Build Server",
                address: "build.demo.invalid",
                username: "builder"),
        ]

        static let profiles: [Host.ID: DemoHostProfile] = [
            studioHostID: DemoHostProfile(
                snapshot: snapshot(
                    agents: [
                        agent(
                            paneID: "mobile:p1", status: .working,
                            workspaceID: "mobile", kind: "codex",
                            name: "ios-polish", title: "Polish the Attach experience",
                            cwd: "/workspace/heeler"),
                        agent(
                            paneID: "docs:p2", status: .idle,
                            workspaceID: "docs", kind: "claude",
                            name: "docs-review", title: "Refresh the setup guide",
                            cwd: "/workspace/product-docs"),
                        agent(
                            paneID: "mobile:p4", status: .done,
                            workspaceID: "mobile", kind: "gemini",
                            name: "accessibility", title: "Audit VoiceOver labels",
                            cwd: "/workspace/heeler"),
                    ],
                    workspaces: [
                        workspace(id: "mobile", label: "iOS App", repo: "heeler"),
                        workspace(id: "docs", label: "Product Docs", repo: "docs-site"),
                    ]),
                paneSnippets: [
                    "mobile:p1": "Running AttachViewTests… 24 passed",
                    "docs:p2": "Ready when you are.",
                    "mobile:p4": "VoiceOver audit complete. 0 blockers.",
                ],
                terminalOutputs: [
                    "mobile:p1": terminalOutput,
                    "docs:p2": terminalOutput,
                    "mobile:p4": terminalOutput,
                ]),
            buildHostID: DemoHostProfile(
                snapshot: snapshot(
                    agents: [
                        agent(
                            paneID: "checkout:p3", status: .blocked,
                            workspaceID: "checkout", kind: "claude",
                            name: "reviewer", title: "Checkout review",
                            cwd: "/workspace/storefront"),
                        agent(
                            paneID: "api:p7", status: .working,
                            workspaceID: "api", kind: "opencode",
                            name: "api-tests", title: "Harden webhook retries",
                            cwd: "/workspace/payments-api"),
                    ],
                    workspaces: [
                        workspace(id: "checkout", label: "Checkout", repo: "storefront"),
                        workspace(id: "api", label: "Payments API", repo: "payments-api"),
                    ]),
                paneSnippets: [
                    "checkout:p3": "Run the targeted UI test before commit?",
                    "api:p7": "Retry matrix: 12 of 16 cases passing",
                ],
                terminalOutputs: [
                    "checkout:p3": terminalOutput,
                    "api:p7": terminalOutput,
                ]),
        ]

        static let terminalOutput = """
            \u{001B}[2J\u{001B}[H\u{001B}[1;36mHERDR  •  CLAUDE CODE\u{001B}[0m\r
            \r
            \u{001B}[1mCheckout flow review\u{001B}[0m\r
            \u{001B}[2mstorefront  •  checkout:p3\u{001B}[0m\r
            \r
            \u{001B}[32m●\u{001B}[0m Read CheckoutView.swift\r
              and PaymentCoordinator.swift\r
            \u{001B}[32m●\u{001B}[0m Ran CheckoutFlowTests\r
              \u{001B}[32m✓ 18 tests passed in 4.2s\u{001B}[0m\r
            \u{001B}[32m●\u{001B}[0m Preserved cart on payment retry\r
            \r
            Result:\r
              • cart survives retry\r
              • errors stay inline\r
              • no customer data is logged\r
            \r
            \u{001B}[33m────────────────────────────\u{001B}[0m\r
            \u{001B}[1;33m› Run the UI test before commit?\u{001B}[0m
            """

        static func makeDefaults() -> UserDefaults {
            let suiteName = "dev.bybee.heeler.demo-screenshots.\(UUID().uuidString)"
            return UserDefaults(suiteName: suiteName) ?? UserDefaults()
        }

        @MainActor
        static func makeConsoleStore() -> ConsoleStore {
            ConsoleStore(snapshotRetryDelay: .seconds(30)) { host, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        guard let profile = profiles[host.id] else {
                            throw TransportError.sshUnreachable(
                                detail: "No demo profile for Host.")
                        }
                        return DemoScreenshotTransport(profile: profile)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)),
                    keepalive: nil)
            }
        }

        private static func snapshot(
            agents: [AgentInfo], workspaces: [WorkspaceInfo]
        ) -> SessionSnapshot {
            SessionSnapshot(
                agents: agents,
                layouts: [],
                panes: [],
                protocolVersion: 17,
                tabs: [],
                version: "0.7.5-demo",
                workspaces: workspaces)
        }

        private static func agent(
            paneID: String,
            status: AgentStatus,
            workspaceID: String,
            kind: String,
            name: String,
            title: String,
            cwd: String
        ) -> AgentInfo {
            AgentInfo(
                agentStatus: status,
                focused: false,
                paneID: paneID,
                revision: 1,
                tabID: "\(workspaceID):t1",
                terminalID: "terminal:\(paneID)",
                workspaceID: workspaceID,
                agent: kind,
                cwd: cwd,
                name: name,
                terminalTitleStripped: title)
        }

        private static func workspace(
            id: String,
            label: String,
            repo: String
        ) -> WorkspaceInfo {
            WorkspaceInfo(
                activeTabID: "\(id):t1",
                agentStatus: .unknown,
                focused: false,
                label: label,
                number: 1,
                paneCount: 1,
                tabCount: 1,
                workspaceID: id,
                worktree: WorkspaceWorktreeInfo(
                    checkoutPath: "/workspace/\(repo)",
                    isLinkedWorktree: false,
                    repoKey: "/workspace/\(repo)/.git",
                    repoName: repo,
                    repoRoot: "/workspace/\(repo)"))
        }
    }

    struct DemoHostProfile: Sendable {
        let snapshot: SessionSnapshot
        let paneSnippets: [String: String]
        let terminalOutputs: [String: String]
    }

    private actor DemoScreenshotTransport: Transport {
        private let profile: DemoHostProfile
        private var isClosed = false
        private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
        private var terminalContinuation: AsyncThrowingStream<Data, any Error>.Continuation?

        init(profile: DemoHostProfile) {
            self.profile = profile
        }

        func ping() async throws -> ServerInfo {
            ServerInfo(version: profile.snapshot.version, protocolVersion: 17)
        }

        func listAgents() async throws -> [Agent] {
            profile.snapshot.agents.map(Agent.init)
        }

        func availableAgentKinds() async throws -> [SupportedAgentKind] {
            [.claude, .codex, .gemini, .opencode]
        }

        func sessionSnapshot() async throws -> SessionSnapshot {
            profile.snapshot
        }

        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            let agent = profile.snapshot.agents.first(where: { $0.paneID == params.paneID })
            return PaneReadResult(
                format: .text,
                paneID: params.paneID,
                revision: 1,
                source: params.source,
                tabID: agent?.tabID ?? "demo:t1",
                text: profile.paneSnippets[params.paneID] ?? "Ready.",
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
            let agent = profile.snapshot.agents.first(where: { $0.paneID == params.target })
            return PaneReadResult(
                format: params.format ?? .text,
                paneID: params.target,
                revision: 1,
                source: params.source,
                tabID: agent?.tabID ?? "demo:t1",
                text: profile.terminalOutputs[params.target]
                    ?? DemoScreenshotFixture.terminalOutput,
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func sendAgentKeys(_ params: AgentSendKeysParams) async throws {}

        func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
            guard let first = profile.snapshot.agents.first else {
                throw TransportError.malformedResponse("Demo profile has no Agents.")
            }
            return Agent(first)
        }

        func startAgentInNewWorktree(
            _ request: AgentLaunchRequest, worktree: WorktreeSpec
        ) async throws -> Agent {
            try await startAgent(request)
        }

        func closePane(_ params: PaneTarget) async throws {}
        func renameAgent(_ params: AgentRenameParams) async throws {}
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {}

        func subscribeToEvents(
            _ subscriptions: [EventSubscription]
        ) async throws -> HerdrEventStream {
            guard eventContinuation == nil else {
                throw TransportError.eventsChannelAlreadyOpen
            }
            let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
            eventContinuation = continuation
            return HerdrEventStream(events: events) { await self.endEvents() }
        }

        func attachTerminal(
            _ request: TerminalAttachRequest
        ) async throws -> TerminalAttachSession {
            guard terminalContinuation == nil else {
                throw TransportError.terminalChannelAlreadyOpen
            }
            let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let input = TerminalAttachInputQueue()
            terminalContinuation = continuation
            continuation.yield(
                Data(
                    (profile.terminalOutputs[request.target] ?? DemoScreenshotFixture.terminalOutput)
                        .utf8)
            )
            return TerminalAttachSession(output: { output }, input: input) {
                await self.endTerminal()
            }
        }

        var isConnected: Bool { !isClosed }

        func close() async throws {
            isClosed = true
            endEvents()
            endTerminal()
        }

        private func endEvents() {
            eventContinuation?.finish()
            eventContinuation = nil
        }

        private func endTerminal() {
            terminalContinuation?.finish()
            terminalContinuation = nil
        }
    }

    private struct DemoPushRegistrationClient: PushRegistrationClient {
        func authorizationStatus() async -> UNAuthorizationStatus { .denied }
        func requestAuthorization() async throws -> Bool { false }
        @MainActor func registerForRemoteNotifications() {}
    }
#endif
