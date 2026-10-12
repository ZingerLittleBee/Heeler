#if DEBUG && targetEnvironment(simulator)
    import SwiftUI
    import Testing
    import UIKit

    @testable import Heeler

    @MainActor
    @Suite("Console tab bar bridge", .timeLimit(.minutes(1)))
    struct ConsoleTabBarBridgeTests {
        /// Opening an Agent from the compact list hides the tab bar. Until
        /// that hide reaches the pushed detail's safe area, the detail lays
        /// its bottom chrome out a bar's height too high and drops it once
        /// the push settles.
        @Test(.enabled(if: UIDevice.current.userInterfaceIdiom == .phone))
        func compactPushPlacesTheComposerAtItsSettledHeightFromTheFirstFrame() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }
            let loadDeadline = ContinuousClock.now + .seconds(5)
            while composition.console.agents.isEmpty, ContinuousClock.now < loadDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let agent = try #require(composition.console.agents.first)

            // The Console reopens its last tab; the row to open is on Agents.
            let lastTab = UserDefaults.standard.object(forKey: "console.last-list-tab")
            UserDefaults.standard.removeObject(forKey: "console.last-list-tab")
            defer { UserDefaults.standard.set(lastTab, forKey: "console.last-list-tab") }
            let view = ConsoleView(
                hosts: composition.hosts, console: composition.console,
                terminal: TerminalSettings(
                    themes: composition.terminalThemes, zoom: composition.terminalZoom,
                    fonts: composition.terminalFonts, snippets: composition.snippets),
                inputMode: composition.inputMode, detailSurface: composition.detailSurface,
                appearance: composition.appearance,
                pushRegistration: composition.pushRegistration,
                notificationPreferences: composition.notificationPreferences,
                relaySettings: composition.relaySettings,
                notificationRouter: composition.notificationRouter,
                bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
                activity: composition.activity)
            let controller = UIHostingController(rootView: view)
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
            defer { window.isHidden = true }
            try #require(window.traitCollection.horizontalSizeClass == .compact)
            try await Task.sleep(for: .milliseconds(300))

            // The same selection a tap on the list row makes.
            composition.notificationRouter.path = [agent.id]
            var samples: [CGFloat] = []
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if let composer = Self.composer(in: window) {
                    samples.append(composer.convert(composer.bounds, to: window).minY)
                }
                try await Task.sleep(for: .milliseconds(4))
            }

            let settled = try #require(samples.last, "the Composer never appeared")
            let early = samples.filter { abs($0 - settled) > 1 }
            #expect(
                early.isEmpty,
                "Composer started above its settled y \(settled): \(early.count) of \(samples.count) samples at \(Set(early).sorted())"
            )
        }

        private static func composer(in root: UIView) -> AgentComposerUITextView? {
            if let composer = root as? AgentComposerUITextView, composer.window != nil {
                return composer
            }
            for subview in root.subviews {
                if let composer = composer(in: subview) { return composer }
            }
            return nil
        }
    }
#endif
