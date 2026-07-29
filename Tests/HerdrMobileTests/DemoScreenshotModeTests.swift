#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Testing

    @testable import HerdrMobile

    @MainActor
    @Suite("Demo screenshot mode")
    struct DemoScreenshotModeTests {
        @Test func launchArgumentIsExactAndOptIn() {
            #expect(!DemoScreenshotMode.isEnabled(arguments: []))
            #expect(!DemoScreenshotMode.isEnabled(arguments: ["--demo-screenshot"]))
            #expect(
                DemoScreenshotMode.isEnabled(
                    arguments: ["HerdrMobile", "--demo-screenshots"]))
        }

        @Test func fixtureIsStablePrivateAndCoversProductStates() {
            let hosts = DemoScreenshotFixture.hosts
            let profiles = DemoScreenshotFixture.profiles
            let agents = hosts.flatMap { profiles[$0.id]?.snapshot.agents ?? [] }

            #expect(hosts.map(\.displayName) == ["Studio Mac", "Build Server"])
            #expect(
                hosts.map(\.id) == [
                    DemoScreenshotFixture.studioHostID,
                    DemoScreenshotFixture.buildHostID,
                ])
            #expect(Set(agents.map(\.agentStatus)) == [.blocked, .working, .done, .idle])
            #expect(
                Set(agents.compactMap(\.agent))
                    == ["claude", "codex", "gemini", "opencode"])
            #expect(agents.map(\.paneID).contains("checkout:p3"))
            #expect(hosts.allSatisfy { $0.address.hasSuffix(".demo.invalid") })
        }

        @Test func compositionLoadsTheProductionConsolePipeline() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()

            let deadline = ContinuousClock.now + .seconds(5)
            while composition.console.agents.count != 5, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(composition.console.agents.count == 5)
            #expect(composition.console.agents.first?.agent.status == .blocked)
            #expect(composition.console.agents.first?.hostName == "Build Server")
            #expect(composition.console.hostStatuses.values.allSatisfy { $0 == .connected })

            composition.console.setHosts([])
        }
    }
#endif
