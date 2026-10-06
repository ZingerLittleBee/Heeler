#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import SwiftUI
    import UserNotifications

    /// The only entry point for deterministic product screenshots. The
    /// entire implementation is excluded from device and Release builds.
    enum DemoScreenshotMode {
        static let launchArgument = "--demo-screenshots"
        /// Adds Hosts that reconnect, cannot connect, or cannot sync, so the
        /// Host problem surfaces can be seen without a failing server.
        static let hostProblemsArgument = "--demo-host-problems"
        /// Opens Agent details on Chat instead of the terminal.
        static let chatArgument = "--demo-chat"

        static var showsHostProblems: Bool {
            ProcessInfo.processInfo.arguments.contains(hostProblemsArgument)
        }

        static var opensChat: Bool {
            ProcessInfo.processInfo.arguments.contains(chatArgument)
        }

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
        @State private var inputMode: AgentInputModeSettings
        @State private var detailSurface: AgentDetailSurfaceSettings
        @State private var pushRegistration: PushRegistrationStore
        @State private var notificationPreferences: NotificationPreferencesStore
        @State private var relaySettings: NotificationRelaySettings
        @State private var notificationRouter: AgentNotificationRouter
        @State private var bannerStore: AgentNotificationBannerStore
        @State private var liveActivities: HostLiveActivityCoordinator
        @State private var activity: AppActivityCoordinator
        @State private var diffLayout = DiffLayoutSettings(defaults: DemoScreenshotFixture.makeDefaults(), offersSideBySide: UIDevice.current.userInterfaceIdiom == .pad)

        init() {
            let composition = DemoScreenshotComposition.make()
            _hosts = State(initialValue: composition.hosts)
            _console = State(initialValue: composition.console)
            _terminalThemes = State(initialValue: composition.terminalThemes)
            _terminalZoom = State(initialValue: composition.terminalZoom)
            _terminalFonts = State(initialValue: composition.terminalFonts)
            _snippets = State(initialValue: composition.snippets)
            _appearance = State(initialValue: composition.appearance)
            _inputMode = State(initialValue: composition.inputMode)
            _detailSurface = State(initialValue: composition.detailSurface)
            _pushRegistration = State(initialValue: composition.pushRegistration)
            _notificationPreferences = State(initialValue: composition.notificationPreferences)
            _relaySettings = State(initialValue: composition.relaySettings)
            _notificationRouter = State(initialValue: composition.notificationRouter)
            _bannerStore = State(initialValue: composition.bannerStore)
            _liveActivities = State(initialValue: composition.liveActivities)
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
                inputMode: inputMode,
                detailSurface: detailSurface,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                notificationRouter: notificationRouter,
                bannerStore: bannerStore,
                liveActivities: liveActivities,
                activity: activity
            )
            .preferredColorScheme(appearance.preferredColorScheme)
            .environment(\.diffLayoutSettings, diffLayout)
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
        let inputMode: AgentInputModeSettings
        let detailSurface: AgentDetailSurfaceSettings
        let pushRegistration: PushRegistrationStore
        let notificationPreferences: NotificationPreferencesStore
        let relaySettings: NotificationRelaySettings
        let notificationRouter: AgentNotificationRouter
        let bannerStore: AgentNotificationBannerStore
        let liveActivities: HostLiveActivityCoordinator
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
            let detailSurface = AgentDetailSurfaceSettings(defaults: defaults)
            if DemoScreenshotMode.opensChat { detailSurface.select(.chat) }
            return DemoScreenshotComposition(
                hosts: HostStore(volatileHosts: DemoScreenshotFixture.hosts),
                console: console,
                terminalThemes: TerminalThemeSettings(defaults: defaults),
                terminalZoom: TerminalZoomSettings(defaults: defaults),
                terminalFonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults),
                appearance: AppAppearanceSettings(defaults: defaults),
                inputMode: AgentInputModeSettings(defaults: defaults),
                detailSurface: detailSurface,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                notificationRouter: notificationRouter,
                bannerStore: AgentNotificationBannerStore(
                    presentedAgent: { notificationRouter.path.last },
                    triggers: { _ in nil },
                    playSound: {}),
                liveActivities: HostLiveActivityCoordinator(
                    controller: ActivityKitLiveActivityController(),
                    preferences: LiveActivityPreferences(defaults: defaults),
                    transports: console,
                    deviceToken: { nil },
                    knownHostIDs: { Set(DemoScreenshotFixture.hosts.map(\.id)) },
                    hostDisplayName: { id in
                        DemoScreenshotFixture.hosts.first(where: { $0.id == id })?.displayName
                            ?? ""
                    },
                    isAwaitingSnapshot: { _ in false },
                    connectionStatus: { _ in .connected }),
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

        static let stagingHostID = UUID(
            uuid: (
                0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x43, 0x33,
                0x83, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33
            ))
        static let piHostID = UUID(
            uuid: (
                0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44,
                0x84, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44
            ))
        static let miniHostID = UUID(
            uuid: (
                0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x45, 0x55,
                0x85, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
            ))

        static let hosts =
            [
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
            ] + (DemoScreenshotMode.showsHostProblems ? problemHosts : [])

        /// Only with `DemoScreenshotMode.hostProblemsArgument`.
        static let problemHosts = [
            Host(
                id: stagingHostID,
                name: "Staging VPS",
                address: "staging.demo.invalid",
                username: "deploy"),
            Host(
                id: piHostID,
                name: "Raspberry Pi",
                address: "pi.demo.invalid",
                username: "pi"),
            Host(
                id: miniHostID,
                name: "Mac mini",
                address: "mini.demo.invalid",
                username: "developer"),
        ]

        /// How each problem Host fails to connect: Staging keeps retrying,
        /// the Pi stops until the user acts.
        static let connectFailures: [Host.ID: TransportError] = [
            stagingHostID: .sshUnreachable(detail: "Connection refused."),
            piHostID: .authenticationFailed,
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
                        workspace(
                            id: "mobile", label: "iOS App", repo: "heeler",
                            isLinkedWorktree: true),
                        workspace(id: "docs", label: "Product Docs", repo: "docs-site"),
                    ],
                    shells: [
                        shell(
                            paneID: "mobile:p5", workspaceID: "mobile", tab: 2,
                            label: "landing", title: "npm run dev",
                            cwd: "/Users/developer/workspace/heeler/landing"),
                        shell(
                            paneID: "mobile:p6", workspaceID: "mobile", tab: 3,
                            title: "zsh", cwd: "/Users/developer/workspace/heeler"),
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
                    "terminal:mobile:p5": devServerOutput,
                    "terminal:mobile:p6": shellPromptOutput,
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
                    ],
                    shells: [
                        shell(
                            paneID: "api:p8", workspaceID: "api", tab: 2,
                            label: "logs", title: "tail -f webhooks.log",
                            cwd: "/var/log/payments"),
                        shell(
                            paneID: "api:p9", workspaceID: "api", tab: 3,
                            title: "htop", cwd: "/home/builder"),
                    ]),
                paneSnippets: [
                    "checkout:p3": "Run the targeted UI test before commit?",
                    "api:p7": "Retry matrix: 12 of 16 cases passing",
                ],
                terminalOutputs: [
                    "checkout:p3": terminalOutput,
                    "api:p7": terminalOutput,
                    "terminal:api:p8": shellPromptOutput,
                    "terminal:api:p9": shellPromptOutput,
                ]),
            miniHostID: DemoHostProfile(
                snapshot: snapshot(agents: [], workspaces: []),
                paneSnippets: [:],
                terminalOutputs: [:],
                snapshotFailure: .apiRejected(
                    code: "internal_error", message: "session snapshot unavailable")),
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

        static let devServerOutput = """
            \u{001B}[2J\u{001B}[Hdeveloper@studio ~/workspace/heeler/landing % npm run dev\r
            \r
            \u{001B}[2m> heeler-landing@0.0.0 dev\u{001B}[0m\r
            \u{001B}[2m> astro dev\u{001B}[0m\r
            \r
            \u{001B}[32m astro  v5.14.1 ready in 412 ms\u{001B}[0m\r
            \r
            ┃ Local    http://localhost:4321/\r
            ┃ Network  use --host to expose\r
            \r
            \u{001B}[2m14:02:11 watching for file changes...\u{001B}[0m\r
            \u{001B}[2m14:02:38 [200] / 18ms\u{001B}[0m
            """

        static let shellPromptOutput = """
            \u{001B}[2J\u{001B}[H\u{001B}[32m➜\u{001B}[0m  \u{001B}[36m~\u{001B}[0m\u{0020}
            """

        static func makeDefaults() -> UserDefaults {
            let suiteName = "dev.bybee.heeler.demo-screenshots.\(UUID().uuidString)"
            return UserDefaults(suiteName: suiteName) ?? UserDefaults()
        }

        static let sidebarLayoutData = Data(
            #"{"v":1,"agent_panel_sort":"priority","sidebar":{"agents":{"rows":[[{"token":"workspace"}],[{"token":"terminal_title_stripped"}],[{"token":"agent"}]]}}}"#.utf8)

        @MainActor
        static func makeConsoleStore() -> ConsoleStore {
            let defaults = makeDefaults()
            return ConsoleStore(
                snapshotRetryDelay: .seconds(30),
                pins: PinnedAgentsStore(defaults: defaults),
                rowLayouts: AgentRowLayoutStore(defaults: defaults)
            ) { host, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        if let failure = connectFailures[host.id] { throw failure }
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
            agents: [AgentInfo], workspaces: [WorkspaceInfo],
            shells: [(pane: PaneInfo, tab: TabInfo)] = []
        ) -> SessionSnapshot {
            SessionSnapshot(
                agents: agents,
                layouts: [],
                panes: shells.map(\.pane),
                protocolVersion: 17,
                tabs: shells.map(\.tab),
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
                agentSession: DemoChatSample.session(forPane: paneID),
                cwd: cwd,
                name: name,
                terminalTitleStripped: title)
        }

        /// A plain shell pane alone in its own tab, as `tab.create` leaves it.
        private static func shell(
            paneID: String,
            workspaceID: String,
            tab: Int,
            label: String? = nil,
            title: String,
            cwd: String
        ) -> (pane: PaneInfo, tab: TabInfo) {
            let tabID = "\(workspaceID):t\(tab)"
            return (
                PaneInfo(
                    agentStatus: .unknown,
                    focused: false,
                    paneID: paneID,
                    revision: 1,
                    tabID: tabID,
                    terminalID: "terminal:\(paneID)",
                    workspaceID: workspaceID,
                    cwd: cwd,
                    foregroundCwd: cwd,
                    terminalTitleStripped: title),
                TabInfo(
                    agentStatus: .unknown,
                    focused: false,
                    label: label ?? String(tab),
                    number: tab,
                    paneCount: 1,
                    tabID: tabID,
                    workspaceID: workspaceID)
            )
        }

        private static func workspace(
            id: String,
            label: String,
            repo: String,
            isLinkedWorktree: Bool = false
        ) -> WorkspaceInfo {
            let repoRoot = isLinkedWorktree ? "/source/\(repo)" : "/workspace/\(repo)"
            return WorkspaceInfo(
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
                    isLinkedWorktree: isLinkedWorktree,
                    repoKey: "\(repoRoot)/.git",
                    repoName: repo,
                    repoRoot: repoRoot))
        }
    }

    struct DemoHostProfile: Sendable {
        let snapshot: SessionSnapshot
        let paneSnippets: [String: String]
        let terminalOutputs: [String: String]
        /// Connects, then fails every snapshot: a Host out of sync.
        var snapshotFailure: TransportError?
    }

    /// Invented Changes for screenshot mode, one Checkout per demo Agent
    /// directory. Each patch is git-diff text parsed by `GitProbe`. Counts
    /// and header totals are counted from those parsed lines, so the list
    /// and the diff stay in step.
    enum DemoChangesSample {
        private static let missingFileMessage = "No sample diff for this file."
        private static let missingDirectoryMessage = "No sample listing for this directory."
        private static let longReceiptLine =
            "let receiptFooter = \"A declined payment keeps the cart, the chosen "
            + "shipping method, and any applied store credit so the customer can "
            + "retry without starting over.\""

        private static let checkouts: [String: SampleCheckout] = {
            var samples: [String: SampleCheckout] = [:]
            for sample in [storefront(), paymentsAPI(), linkedWorktree(), productDocs()] {
                samples[sample.topLevel] = sample
            }
            return samples
        }()

        static func read(_ request: ChangesReadRequest) throws -> CheckoutChangesRead {
            guard let checkout = checkouts[request.directory] else {
                throw ChangesReadError.notAGitWorkingTree
            }
            return makeRead(checkout)
        }

        static func patch(_ request: FilePatchRequest) throws -> FilePatch {
            guard let checkout = checkout(topLevel: request.topLevel),
                let file = sampleFile(in: checkout, path: request.path)
            else {
                throw ChangesReadError.gitFailed(missingFileMessage)
            }
            return parsedPatch(for: file)
        }

        static func listUntrackedDirectory(
            _ request: UntrackedDirectoryRequest
        ) throws -> UntrackedDirectoryListing {
            guard let checkout = checkout(topLevel: request.topLevel),
                let directory = checkout.directories.first(where: {
                    Data($0.path.utf8) == request.directory
                })
            else {
                throw ChangesReadError.gitFailed(missingDirectoryMessage)
            }
            let entries = directory.children.map { child in
                ChangedFile(
                    path: Data(child.path.utf8), originalPath: nil, kind: .untracked, staging: nil)
            }.sorted { $0.path.lexicographicallyPrecedes($1.path) }
            return UntrackedDirectoryListing(
                directory: request.directory,
                entries: entries,
                total: entries.count,
                isTruncated: false,
                isSeparateRepository: false,
                limitNotice: nil)
        }

        /// The blocked reviewer Agent. One modified file carries the
        /// side-by-side screenshot shape.
        private static func storefront() -> SampleCheckout {
            SampleCheckout(
                topLevel: "/workspace/storefront",
                branch: "checkout-retry",
                commit: "4f1a9c2e8b7d6a5031e4f8c9b2a7d6e5f0c1b3a4",
                upstream: "origin/checkout-retry",
                ahead: 2,
                behind: 0,
                subject: "Keep the cart when a payment retry fails",
                committedAgo: 40 * 60,
                files: [
                    SampleFile(
                        path: "Resources/checkout-hero.png",
                        kind: .modified,
                        staging: .unstaged,
                        body: .binary),
                    SampleFile(
                        path: "Sources/Checkout/CartStore.swift",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(9, 9, "func applyRetry()",
                                context("guard let saved = savedCart else { return }"),
                                removed("saved.clear()"),
                                added("items = saved.items"),
                                context("shipping = saved.shipping")),
                        ])),
                    SampleFile(
                        path: "Sources/Checkout/CheckoutView.swift",
                        kind: .modified,
                        staging: .both,
                        body: .hunks([
                            hunk(18, 18, "struct CheckoutView",
                                context("var cart: Cart"),
                                removed("Text(cart.totalText)"),
                                added("CartTotal(cart)"),
                                context("RetryBanner(cart: cart)")),
                        ])),
                    SampleFile(
                        path: "Sources/Checkout/PaymentCoordinator.swift",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(12, 12, "func retryPayment()",
                                context("let cart = loadSavedCart()"),
                                removed("discardCart()"),
                                removed("clearShippingMethod()"),
                                removed("resetStoreCredit()"),
                                added("keepCartForRetry()"),
                                context("return cart")),
                            hunk(40, 38, "func showRetryBanner()",
                                added("showBanner(beside: cart.total)"),
                                added("rememberShippingMethod()"),
                                added(longReceiptLine, missingNewline: true)),
                        ])),
                    SampleFile(
                        path: "Sources/Checkout/PaymentSheet.swift",
                        originalPath: "Sources/Checkout/LegacyPaymentSheet.swift",
                        kind: .renamed,
                        staging: .staged,
                        body: .hunks([
                            hunk(8, 8, "struct PaymentSheet",
                                context("let title: String"),
                                removed("var showsLegacyTotal: Bool"),
                                added("var showsCartTotal: Bool"),
                                context("let currencyCode: String")),
                        ])),
                    SampleFile(
                        path: "Sources/Checkout/RetryBanner.swift",
                        kind: .added,
                        staging: .staged,
                        body: .hunks([
                            hunk(0, 1, "struct RetryBanner",
                                added("struct RetryBanner {"),
                                added("    let message: String"),
                                added("    var canRetry: Bool { !message.isEmpty }"),
                                added("}")),
                        ])),
                    SampleFile(
                        path: "Tests/CheckoutTests/CheckoutFlowTests.swift",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(14, 14, "func testRetryKeepsItems()",
                                context("let cart = CartStore()"),
                                removed("cart.apply(.decline)"),
                                added("cart.apply(.retry)"),
                                context("check(cart.items.count == 2)")),
                        ])),
                    SampleFile(
                        path: "Tests/CheckoutTests/PaymentRetryTests.swift",
                        kind: .untracked,
                        body: .hunks([
                            hunk(0, 1, "func testDeclinedPaymentKeepsTheCart()",
                                added("func testDeclinedPaymentKeepsTheCart() {"),
                                added("    let cart = CartStore()"),
                                added("    cart.apply(.retry)"),
                                added("    check(cart.items.isEmpty == false)"),
                                added("}")),
                        ])),
                ],
                directories: [
                    SampleDirectory(
                        path: "Fixtures/receipts/",
                        children: [
                            SampleFile(
                                path: "Fixtures/receipts/sample-approved.txt",
                                kind: .untracked,
                                body: .hunks([
                                    hunk(0, 1, "approved receipt",
                                        added("status: approved"),
                                        added("cart: kept"),
                                        added("retry: allowed")),
                                ])),
                            SampleFile(
                                path: "Fixtures/receipts/sample-declined.txt",
                                kind: .untracked,
                                body: .hunks([
                                    hunk(0, 1, "declined receipt",
                                        added("status: declined"),
                                        added("cart: kept"),
                                        added("retry: offered")),
                                ])),
                        ]),
                ])
        }

        private static func paymentsAPI() -> SampleCheckout {
            SampleCheckout(
                topLevel: "/workspace/payments-api",
                branch: "webhook-retries",
                commit: "91ab34cd78ef12a0b6c5d4e3f2019abc8def7654",
                upstream: "origin/webhook-retries",
                ahead: 1,
                behind: 0,
                subject: "Retry a declined webhook without dropping the event",
                committedAgo: 2 * 60 * 60,
                files: [
                    SampleFile(
                        path: "Sources/Webhooks/EventLedger.swift",
                        kind: .added,
                        staging: .staged,
                        body: .hunks([
                            hunk(0, 1, "struct EventLedger",
                                added("struct EventLedger {"),
                                added("    var pending: [String] = []"),
                                added("    mutating func keep(_ event: String) { pending.append(event) }"),
                                added("}")),
                        ])),
                    SampleFile(
                        path: "Sources/Webhooks/RetryPolicy.swift",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(6, 6, "func nextDelay(after attempt: Int)",
                                context("if attempt > 4 { return nil }"),
                                removed("return 1"),
                                added("return min(30, attempt * 2)"),
                                context("return nil")),
                        ])),
                    SampleFile(
                        path: "Tests/WebhookTests/RetryPolicyTests.swift",
                        kind: .untracked,
                        body: .hunks([
                            hunk(0, 1, "func testSecondAttemptWaitsLonger()",
                                added("func testSecondAttemptWaitsLonger() {"),
                                added("    check(RetryPolicy().nextDelay(after: 2) == 4)"),
                                added("}")),
                        ])),
                ])
        }

        /// Linked Worktree. The path is the one the demo fixture already uses.
        private static func linkedWorktree() -> SampleCheckout {
            SampleCheckout(
                topLevel: "/workspace/heeler",
                isLinkedWorktree: true,
                branch: "attach-polish",
                commit: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
                upstream: "origin/attach-polish",
                ahead: 3,
                behind: 1,
                subject: "Name the attach controls for spoken review",
                committedAgo: 3 * 60 * 60,
                files: [
                    SampleFile(
                        path: "Sources/Attach/AttachChrome.swift",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(4, 4, "struct AttachChrome",
                                context("var title: String"),
                                removed("var subtitle: String"),
                                added("var spokenTitle: String"),
                                context("var isLive: Bool")),
                        ])),
                    SampleFile(
                        path: "Sources/Attach/SpokenLabels.swift",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(2, 2, "func label(for control: AttachControl)",
                                context("switch control {"),
                                removed("case .send: return \"Send\""),
                                added("case .send: return \"Send message\""),
                                context("}")),
                        ])),
                ])
        }

        private static func productDocs() -> SampleCheckout {
            SampleCheckout(
                topLevel: "/workspace/product-docs",
                branch: "setup-guide",
                commit: "aabbccddeeff00112233445566778899abcdef01",
                upstream: "origin/setup-guide",
                ahead: 1,
                behind: 2,
                subject: "Rewrite the first-run setup steps",
                committedAgo: 26 * 60 * 60,
                files: [
                    SampleFile(
                        path: "guide/first-run.md",
                        kind: .modified,
                        staging: .unstaged,
                        body: .hunks([
                            hunk(3, 3, "First run",
                                context("Open the app and add a machine."),
                                removed("Paste a key into the terminal."),
                                added("Create a key on the device, then confirm the fingerprint."),
                                context("The machine stays reachable after the app closes.")),
                        ])),
                    SampleFile(
                        path: "guide/troubleshooting.md",
                        kind: .untracked,
                        body: .hunks([
                            hunk(0, 1, "When a connection stops",
                                added("# When a connection stops"),
                                added("Check the address, then try again."),
                                added("A refused connection leaves the previous notes on screen.")),
                        ])),
                ])
        }

        private static func makeRead(_ checkout: SampleCheckout) -> CheckoutChangesRead {
            let files = sortedForList(
                checkout.files.map(changedFile)
                    + checkout.directories.map { directory in
                        ChangedFile(
                            path: Data(directory.path.utf8), originalPath: nil,
                            kind: .untracked, staging: nil)
                    })
            return CheckoutChangesRead(
                changes: CheckoutChanges(
                    checkout: CheckoutLocation(
                        topLevel: Data(checkout.topLevel.utf8),
                        isLinkedWorktree: checkout.isLinkedWorktree,
                        displayPath: checkout.topLevel),
                    head: CheckoutHead(
                        branch: .named(checkout.branch),
                        commit: checkout.commit,
                        latestCommit: LatestCommit(
                            subject: checkout.subject,
                            committedAt: Date().addingTimeInterval(-checkout.committedAgo)),
                        upstream: CheckoutUpstream(
                            name: checkout.upstream,
                            state: .tracking(ahead: checkout.ahead, behind: checkout.behind))),
                    files: files,
                    totals: totals(for: files)),
                directoryPrefix: Data())
        }

        private static func changedFile(_ file: SampleFile) -> ChangedFile {
            ChangedFile(
                path: Data(file.path.utf8),
                originalPath: file.originalPath.map { Data($0.utf8) },
                kind: file.kind,
                staging: file.staging,
                lineCounts: lineCounts(kind: file.kind, patch: parsedPatch(for: file)))
        }

        private static func lineCounts(kind: ChangedFile.Kind, patch: FilePatch) -> LineCounts? {
            guard kind != .untracked else { return nil }
            if patch.files.contains(where: \.isBinary) { return .binary }
            var added = 0
            var removed = 0
            for diff in patch.files {
                for hunk in diff.hunks {
                    for line in hunk.lines {
                        switch line.kind {
                        case .added: added += 1
                        case .removed: removed += 1
                        case .context: break
                        }
                    }
                }
            }
            return .lines(added: added, removed: removed)
        }

        private static func totals(for files: [ChangedFile]) -> ChangesTotals {
            var totals = ChangesTotals()
            for file in files {
                if file.kind == .untracked {
                    totals.untrackedItems += 1
                } else {
                    totals.trackedFiles += 1
                }
                if case .lines(let added, let removed) = file.lineCounts {
                    totals.added += added
                    totals.removed += removed
                }
            }
            return totals
        }

        private static func sortedForList(_ files: [ChangedFile]) -> [ChangedFile] {
            files.sorted { lhs, rhs in
                let lhsConflicted = lhs.kind == .conflicted
                let rhsConflicted = rhs.kind == .conflicted
                if lhsConflicted != rhsConflicted { return lhsConflicted }
                return lhs.path.lexicographicallyPrecedes(rhs.path)
            }
        }

        private static func parsedPatch(for file: SampleFile) -> FilePatch {
            let text = patchLines(for: file).joined(separator: "\n") + "\n"
            return FilePatch(
                files: GitProbe.parsePatchFiles(Data(text.utf8), isTruncated: false),
                isTruncated: false)
        }

        private static func patchLines(for file: SampleFile) -> [String] {
            let oldHeader = file.originalPath ?? file.path
            var lines = ["diff --git a/\(oldHeader) b/\(file.path)"]
            switch file.body {
            case .binary:
                lines.append("index a1b2c3d..e4f5a6b 100644")
                lines.append("Binary files a/\(file.path) and b/\(file.path) differ")
            case .hunks(let hunks):
                if file.kind == .renamed, let original = file.originalPath {
                    lines.append("similarity index 86%")
                    lines.append("rename from \(original)")
                    lines.append("rename to \(file.path)")
                }
                if file.kind == .added || file.kind == .untracked {
                    lines.append("new file mode 100644")
                }
                lines.append("index a1b2c3d..e4f5a6b 100644")
                let oldBody: String? =
                    (file.kind == .added || file.kind == .untracked)
                    ? nil : (file.originalPath ?? file.path)
                let newBody: String? = file.kind == .deleted ? nil : file.path
                lines.append("--- \(prefixed(oldBody, prefix: "a"))")
                lines.append("+++ \(prefixed(newBody, prefix: "b"))")
                for hunk in hunks {
                    lines.append(contentsOf: hunkLines(hunk))
                }
            }
            return lines
        }

        private static func prefixed(_ path: String?, prefix: String) -> String {
            guard let path else { return "/dev/null" }
            return "\(prefix)/\(path)"
        }

        private static func hunkLines(_ hunk: SampleHunk) -> [String] {
            let oldCount = hunk.lines.filter { $0.kind != .added }.count
            let newCount = hunk.lines.filter { $0.kind != .removed }.count
            var lines = [
                "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@ \(hunk.section)"
            ]
            for line in hunk.lines {
                let prefix =
                    switch line.kind {
                    case .context: " "
                    case .added: "+"
                    case .removed: "-"
                    }
                lines.append(prefix + line.text)
                if line.missingNewline {
                    lines.append("\\ No newline at end of file")
                }
            }
            return lines
        }

        private static func hunk(
            _ oldStart: Int, _ newStart: Int, _ section: String, _ lines: SampleLine...
        ) -> SampleHunk {
            SampleHunk(oldStart: oldStart, newStart: newStart, section: section, lines: lines)
        }

        private static func context(_ text: String) -> SampleLine {
            SampleLine(kind: .context, text: text)
        }

        private static func added(_ text: String, missingNewline: Bool = false) -> SampleLine {
            SampleLine(kind: .added, text: text, missingNewline: missingNewline)
        }

        private static func removed(_ text: String) -> SampleLine {
            SampleLine(kind: .removed, text: text)
        }

        private static func checkout(topLevel: Data) -> SampleCheckout? {
            checkouts.values.first { Data($0.topLevel.utf8) == topLevel }
        }

        private static func sampleFile(in checkout: SampleCheckout, path: Data) -> SampleFile? {
            if let file = checkout.files.first(where: { Data($0.path.utf8) == path }) {
                return file
            }
            for directory in checkout.directories {
                if let child = directory.children.first(where: { Data($0.path.utf8) == path }) {
                    return child
                }
            }
            return nil
        }

        private struct SampleCheckout: Sendable {
            var topLevel: String
            var isLinkedWorktree = false
            var branch: String
            var commit: String
            var upstream: String
            var ahead: Int
            var behind: Int
            var subject: String
            var committedAgo: TimeInterval
            var files: [SampleFile]
            var directories: [SampleDirectory] = []
        }

        private struct SampleDirectory: Sendable {
            var path: String
            var children: [SampleFile]
        }

        private struct SampleFile: Sendable {
            var path: String
            var originalPath: String? = nil
            var kind: ChangedFile.Kind
            var staging: ChangedFile.Staging? = nil
            var body: SampleBody
        }

        private enum SampleBody: Sendable {
            case hunks([SampleHunk])
            case binary
        }

        private struct SampleHunk: Sendable {
            var oldStart: Int
            var newStart: Int
            var section: String
            var lines: [SampleLine]
        }

        private struct SampleLine: Sendable {
            enum Kind: Equatable, Sendable {
                case context
                case added
                case removed
            }

            var kind: Kind
            var text: String
            var missingNewline = false
        }
    }

    private actor DemoScreenshotTransport: Transport {
        private let profile: DemoHostProfile
        private var isClosed = false
        private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
        /// Like the SSH transport, each target admits one live channel.
        private var terminalContinuations: [
            TerminalAttachTarget: AsyncThrowingStream<Data, any Error>.Continuation
        ] = [:]

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

        func readSidebarLayout() async throws -> Data? {
            DemoScreenshotFixture.sidebarLayoutData
        }

        func sessionSnapshot() async throws -> SessionSnapshot {
            if let failure = profile.snapshotFailure { throw failure }
            return profile.snapshot
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
                text: (params.format == .ansi ? DemoChatSample.screen(forPane: params.target) : nil)
                    ?? profile.terminalOutputs[params.target]
                    ?? DemoScreenshotFixture.terminalOutput,
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
            guard let agent = profile.snapshot.agents.first(where: { $0.paneID == params.target })
            else {
                throw TransportError.malformedResponse("Demo profile has no matching Agent.")
            }
            return Agent(agent)
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

        func startAgentInNewWorkspace(
            _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
        ) async throws -> Agent {
            try await startAgent(request)
        }

        func closePane(_ params: PaneTarget) async throws {}
        func closeTab(_ params: TabTarget) async throws {}
        func focusAgent(_ target: AgentTarget) async throws {}
        func renameAgent(_ params: AgentRenameParams) async throws {}
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {}

        /// Screenshot Changes. Served in-process: no Host and no SSH.
        func readChanges(_ request: ChangesReadRequest) async throws -> CheckoutChangesRead {
            try DemoChangesSample.read(request)
        }

        func readFilePatch(_ request: FilePatchRequest) async throws -> FilePatch {
            try DemoChangesSample.patch(request)
        }

        func listUntrackedDirectory(
            _ request: UntrackedDirectoryRequest
        ) async throws -> UntrackedDirectoryListing {
            try DemoChangesSample.listUntrackedDirectory(request)
        }

        /// Screenshot Chat transcripts, served in-process like Changes.
        func hostHomeDirectory() async throws -> String {
            DemoChatSample.home
        }

        func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
            DemoChatSample.status(atPath: path)
        }

        func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
            DemoChatSample.list(request)
        }

        func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
            DemoChatSample.read(range)
        }

        func agentInfo(_ target: AgentTarget) async throws -> Agent {
            guard let agent = profile.snapshot.agents.first(where: { $0.paneID == target.target })
            else {
                throw TransportError.malformedResponse("Demo profile has no matching Agent.")
            }
            return Agent(agent)
        }

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
            let target = request.target
            guard terminalContinuations[target] == nil else {
                throw TransportError.terminalChannelAlreadyOpen
            }
            let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let input = TerminalAttachInputQueue()
            terminalContinuations[target] = continuation
            continuation.yield(
                Data(
                    (profile.terminalOutputs[target.identifier]
                        ?? DemoScreenshotFixture.terminalOutput)
                        .utf8)
            )
            return TerminalAttachSession(output: { output }, input: input) {
                await self.endTerminal(target)
            }
        }

        var isConnected: Bool { !isClosed }

        func close() async throws {
            isClosed = true
            endEvents()
            for continuation in terminalContinuations.values {
                continuation.finish()
            }
            terminalContinuations.removeAll()
        }

        private func endEvents() {
            eventContinuation?.finish()
            eventContinuation = nil
        }

        private func endTerminal(_ target: TerminalAttachTarget) {
            terminalContinuations.removeValue(forKey: target)?.finish()
        }
    }

    private struct DemoPushRegistrationClient: PushRegistrationClient {
        func authorizationStatus() async -> UNAuthorizationStatus { .denied }
        func requestAuthorization() async throws -> Bool { false }
        @MainActor func registerForRemoteNotifications() {}
    }
#endif
