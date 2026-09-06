#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Observation
    import Testing

    @testable import Heeler

    @MainActor
    @Suite("Demo screenshot mode", .timeLimit(.minutes(1)))
    struct DemoScreenshotModeTests {
        @Test func launchArgumentIsExactAndOptIn() {
            #expect(!DemoScreenshotMode.isEnabled(arguments: []))
            #expect(!DemoScreenshotMode.isEnabled(arguments: ["--demo-screenshot"]))
            #expect(
                DemoScreenshotMode.isEnabled(
                    arguments: ["Heeler", "--demo-screenshots"]))
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

            while composition.console.agents.count != 5
                || composition.hosts.hosts.contains(where: {
                    composition.console.sidebarSnapshots.snapshot(for: $0.id) == nil
                })
            {
                let changes = AsyncStream<Void>.makeStream()
                withObservationTracking {
                    _ = composition.console.agents
                    _ = composition.console.sidebarSnapshots.states
                } onChange: {
                    changes.continuation.yield(())
                }
                for await _ in changes.stream { break }
                changes.continuation.finish()
            }

            #expect(composition.console.agents.count == 5)
            #expect(composition.console.agents.first?.agent.status == .blocked)
            #expect(composition.console.agents.first?.hostName == "Build Server")
            #expect(composition.console.hostStatuses.values.allSatisfy { $0 == .connected })

            for host in composition.hosts.hosts {
                let bytes = try await composition.console.withNotificationTransport(for: host.id) {
                    try await $0.readSidebarLayout()
                }
                #expect(bytes == DemoScreenshotFixture.sidebarLayoutData)
                #expect(composition.console.rowLayout(for: host.id)
                    == AgentRowLayoutSnapshot.decode(DemoScreenshotFixture.sidebarLayoutData)?.layout)
            }
            let row = try #require(composition.console.agents.first)
            let card = AgentCardPresentation(agent: row, layout: composition.console.rowLayout(for: row.hostID))
            #expect(card.headline == row.workspaceLabel)
            #expect(card.additionalRows.first == row.agent.terminalTitleStripped)
            composition.console.setHosts([])
        }
    }
#endif
