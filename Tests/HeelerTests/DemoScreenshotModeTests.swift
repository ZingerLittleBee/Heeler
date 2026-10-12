#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Observation
    import SwiftUI
    import Testing
    import UIKit

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
            defer { composition.console.setHosts([]) }

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
                    == AgentRowLayout(rows: [
                        [.init(.workspace)], [.init(.terminalTitleStripped)], [.init(.directory)],
                    ]))
            }
            let row = try #require(composition.console.agents.first)
            let card = AgentCardPresentation(agent: row, layout: composition.console.rowLayout(for: row.hostID))
            #expect(card.headline == row.workspaceLabel)
            #expect(card.additionalRows.first == row.agent.terminalTitleStripped)
        }

        @Test func reviewerSampleListsFilesWithCounts() throws {
            let read = try DemoChangesSample.read(
                ChangesReadRequest(directory: "/workspace/storefront"))
            let changes = read.changes

            #expect(read.directoryPrefix.isEmpty)
            #expect(changes.checkout.displayPath == "/workspace/storefront")
            #expect(!changes.checkout.isLinkedWorktree)
            #expect(changes.head.branchTitle == "checkout-retry")
            #expect(changes.head.commit?.count == 40)
            #expect(changes.head.commit?.allSatisfy(\.isHexDigit) == true)
            #expect(changes.head.latestCommit?.subject == "Keep the cart when a payment retry fails")
            let committedAt = try #require(changes.head.latestCommit?.committedAt)
            let age = Date().timeIntervalSince(committedAt)
            #expect(age > 30 * 60 && age < 50 * 60)
            let upstream = try #require(changes.head.upstream)
            #expect(upstream.name == "origin/checkout-retry")
            guard case .tracking(let ahead, let behind) = upstream.state else {
                Issue.record("storefront upstream should be tracking")
                return
            }
            #expect(ahead == 2)
            #expect(behind == 0)
            #expect(!changes.isClean)
            #expect(!changes.isStatusTruncated)
            #expect(!changes.isMetadataTruncated)
            expectTotalsMatchFiles(changes)
            #expect(listsLikeProduction(changes.files))
            #expect(changes.files.map(\.displayPath) == [
                "Fixtures/receipts/",
                "Resources/checkout-hero.png",
                "Sources/Checkout/CartStore.swift",
                "Sources/Checkout/CheckoutView.swift",
                "Sources/Checkout/PaymentCoordinator.swift",
                "Sources/Checkout/PaymentSheet.swift",
                "Sources/Checkout/RetryBanner.swift",
                "Tests/CheckoutTests/CheckoutFlowTests.swift",
                "Tests/CheckoutTests/PaymentRetryTests.swift",
            ])
            #expect(changes.files.first { $0.displayPath == "Sources/Checkout/CheckoutView.swift" }?.staging == .both)
            #expect(changes.files.first { $0.displayPath == "Sources/Checkout/RetryBanner.swift" }?.kind == .added)
            #expect(changes.files.first { $0.displayPath == "Sources/Checkout/RetryBanner.swift" }?.staging == .staged)
            #expect(
                changes.files.first { $0.displayPath == "Resources/checkout-hero.png" }?.lineCounts == .binary)
            let renamed = try #require(changes.files.first { $0.kind == .renamed })
            #expect(renamed.displayPath == "Sources/Checkout/PaymentSheet.swift")
            #expect(renamed.displayOriginalPath == "Sources/Checkout/LegacyPaymentSheet.swift")
            #expect(renamed.staging == .staged)
            #expect(changes.files.contains { $0.kind == .untracked && !$0.isUntrackedDirectory })
            #expect(changes.files.contains { $0.isUntrackedDirectory })
        }

        /// The reviewer's modified file is the shape side-by-side screenshots
        /// need: unequal runs, a pure addition, context, a long line, and a
        /// missing trailing newline.
        @Test func reviewerSamplePatchHasSideBySideShape() throws {
            let read = try DemoChangesSample.read(
                ChangesReadRequest(directory: "/workspace/storefront"))
            let coordinator = try #require(
                read.changes.files.first {
                    $0.displayPath == "Sources/Checkout/PaymentCoordinator.swift"
                })
            let request = try #require(
                FilePatchRequest(file: coordinator, checkout: read.changes.checkout))
            let patch = try DemoChangesSample.patch(request)
            #expect(patch.files.count == 1)
            #expect(!patch.isTruncated)
            let hunks = try #require(patch.files.first?.hunks)
            #expect(hunks.contains { hunk in
                let removed = hunk.lines.filter { $0.kind == .removed }.count
                let added = hunk.lines.filter { $0.kind == .added }.count
                return removed != added
            })
            #expect(hunks.contains { containsRun($0.lines, removed: 3, added: 1) })
            #expect(hunks.contains { hunk in
                hunk.oldCount == 0 && !hunk.lines.isEmpty && hunk.lines.allSatisfy { $0.kind == .added }
            })
            #expect(hunks.flatMap(\.lines).contains { $0.kind == .context })
            #expect(hunks.flatMap(\.lines).contains { $0.text.count > 120 })
            #expect(hunks.flatMap(\.lines).contains { $0.missingNewline })
        }

        @Test func everyDemoDirectoryServesCountsThatMatchItsDiff() throws {
            let directories = Set(
                DemoScreenshotFixture.profiles.values.flatMap { profile in
                    profile.snapshot.agents.compactMap(\.cwd)
                })
            #expect(directories == Set([
                "/workspace/heeler",
                "/workspace/payments-api",
                "/workspace/product-docs",
                "/workspace/storefront",
            ]))
            for directory in directories {
                let read = try DemoChangesSample.read(ChangesReadRequest(directory: directory))
                #expect(!read.changes.isClean)
                #expect(read.directoryPrefix.isEmpty)
                #expect(read.changes.checkout.displayPath == directory)
                #expect(read.changes.checkout.isLinkedWorktree == (directory == "/workspace/heeler"))
                #expect(read.changes.head.commit?.count == 40)
                #expect(read.changes.head.latestCommit != nil)
                guard case .named(let branch) = read.changes.head.branch, !branch.isEmpty else {
                    Issue.record("\(directory) should name a branch")
                    continue
                }
                guard case .tracking = read.changes.head.upstream?.state else {
                    Issue.record("\(directory) should track an upstream")
                    continue
                }
                expectTotalsMatchFiles(read.changes)
                #expect(listsLikeProduction(read.changes.files))
                for file in read.changes.files {
                    if file.isUntrackedDirectory {
                        let listing = try DemoChangesSample.listUntrackedDirectory(
                            UntrackedDirectoryRequest(
                                topLevel: read.changes.checkout.topLevel, directory: file.path))
                        #expect(listing.total == listing.entries.count)
                        #expect(!listing.entries.isEmpty)
                        #expect(!listing.isTruncated)
                        #expect(listing.limitNotice == nil)
                        #expect(listsLikeProduction(listing.entries))
                        for entry in listing.entries {
                            #expect(entry.kind == .untracked)
                            #expect(entry.lineCounts == nil)
                            #expect(!entry.isUntrackedDirectory)
                            #expect(entry.displayPath.hasPrefix(file.displayPath))
                            let child = try #require(
                                FilePatchRequest(file: entry, checkout: read.changes.checkout))
                            expectConsistentPatch(try DemoChangesSample.patch(child), file: entry)
                        }
                    } else {
                        let request = try #require(
                            FilePatchRequest(file: file, checkout: read.changes.checkout))
                        expectConsistentPatch(try DemoChangesSample.patch(request), file: file)
                    }
                }
            }
        }

        @Test func sampleUsesInventedNamesOnly() throws {
            let forbidden = [
                "heeler", "herdr", "github", "anthropic", "openai", "stripe",
                "microsoft", "google", "apple", "voiceover", "claude", "codex",
                "gemini", "opencode",
            ]
            for text in try sampleTexts() {
                let folded = text.lowercased()
                for name in forbidden {
                    #expect(!folded.contains(name), "sample text contains \(name): \(text)")
                }
            }
        }

        @Test func unknownSamplePathIsAVisibleFailure() {
            #expect(throws: ChangesReadError.notAGitWorkingTree) {
                try DemoChangesSample.read(ChangesReadRequest(directory: "/var/log/payments"))
            }
            #expect(throws: ChangesReadError.gitFailed("No sample diff for this file.")) {
                try DemoChangesSample.patch(
                    FilePatchRequest(
                        topLevel: Data("/workspace/storefront".utf8),
                        path: Data("Missing.swift".utf8),
                        isUntracked: false))
            }
            #expect(throws: ChangesReadError.gitFailed("No sample listing for this directory.")) {
                try DemoChangesSample.listUntrackedDirectory(
                    UntrackedDirectoryRequest(
                        topLevel: Data("/workspace/storefront".utf8),
                        directory: Data("Missing/".utf8)))
            }
        }

        @Test func demoConsoleReadsSampleChangesWithoutAHost() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }
            await waitUntilDemoAgentsLoad(composition)

            let reviewer = try #require(composition.console.agents.first)
            #expect(reviewer.agent.status == .blocked)
            #expect(reviewer.hostName == "Build Server")
            let directory = try #require(reviewer.directory)
            #expect(directory == "/workspace/storefront")
            let live = try await composition.console.readChanges(
                ChangesReadRequest(directory: directory), on: reviewer.hostID)
            let direct = try DemoChangesSample.read(ChangesReadRequest(directory: directory))
            #expect(live.changes.files == direct.changes.files)
            #expect(live.changes.totals == direct.changes.totals)
            #expect(live.changes.checkout == direct.changes.checkout)
            #expect(live.directoryPrefix.isEmpty)
            #expect(live.changes.head.branchTitle == direct.changes.head.branchTitle)
            #expect(live.changes.head.latestCommit?.subject == direct.changes.head.latestCommit?.subject)

            let coordinator = try #require(
                live.changes.files.first {
                    $0.displayPath == "Sources/Checkout/PaymentCoordinator.swift"
                })
            let patchRequest = try #require(
                FilePatchRequest(file: coordinator, checkout: live.changes.checkout))
            let patch = try await composition.console.readFilePatch(patchRequest, on: reviewer.hostID)
            let directPatch = try DemoChangesSample.patch(patchRequest)
            #expect(patch == directPatch)
            #expect(patch.files.first?.hunks.isEmpty == false)

            let receipts = try #require(live.changes.files.first { $0.isUntrackedDirectory })
            let listingRequest = UntrackedDirectoryRequest(
                topLevel: live.changes.checkout.topLevel, directory: receipts.path)
            let listing = try await composition.console.listUntrackedDirectory(
                listingRequest, on: reviewer.hostID)
            let directListing = try DemoChangesSample.listUntrackedDirectory(listingRequest)
            #expect(listing == directListing)
            #expect(!listing.entries.isEmpty)
        }

        /// A Working demo Agent's Changes carry the possibly-incomplete label
        /// and the time they were read. A blocked demo Agent's do not.
        @Test func workingDemoAgentsShowPossiblyIncompleteChanges() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }
            await waitUntilDemoAgentsLoad(composition)

            let apiTests = try #require(
                composition.console.agents.first { $0.agent.name == "api-tests" })
            #expect(apiTests.agent.status == .working)
            let working = productionChangesStore(for: apiTests, console: composition.console)
            defer { working.cancel() }
            await working.appear()
            guard case .loaded(let workingChanges) = working.phase else {
                Issue.record("api-tests Changes should be loaded, got \(working.phase)")
                return
            }
            #expect(workingChanges.checkout.displayPath == "/workspace/payments-api")
            let freshness = try #require(working.freshness)
            #expect(freshness.readAt == working.readAt)
            #expect(
                freshness.text(relativeTo: freshness.readAt)
                    .hasPrefix("Possibly incomplete · Read at "))

            let reviewer = try #require(
                composition.console.agents.first { $0.agent.name == "reviewer" })
            #expect(reviewer.agent.status == .blocked)
            let blocked = productionChangesStore(for: reviewer, console: composition.console)
            defer { blocked.cancel() }
            await blocked.appear()
            guard case .loaded(let reviewerChanges) = blocked.phase else {
                Issue.record("reviewer Changes should be loaded, got \(blocked.phase)")
                return
            }
            #expect(reviewerChanges.checkout.displayPath == "/workspace/storefront")
            #expect(blocked.freshness == nil)
        }

        @Test func reviewerDemoChangesInsertRelativeFileReference() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }
            await waitUntilDemoAgentsLoad(composition)

            let reviewer = try #require(
                composition.console.agents.first { $0.agent.name == "reviewer" })
            #expect(reviewer.directory == "/workspace/storefront")
            let store = productionChangesStore(for: reviewer, console: composition.console)
            defer { store.cancel() }
            await store.appear()
            guard case .loaded(let changes) = store.phase else {
                Issue.record("reviewer Changes should be loaded, got \(store.phase)")
                return
            }
            #expect(changes.checkout.displayPath == "/workspace/storefront")
            #expect(store.directoryPrefix.isEmpty)
            let firstFile = try #require(changes.files.first)
            #expect(firstFile.displayPath == "Fixtures/receipts/")
            #expect(store.insertionText(for: firstFile) == "Fixtures/receipts/ ")
        }

        /// The Agents list reads each demo Agent's sample Checkout for its
        /// row through the production factory, and shows its totals there.
        @Test func demoAgentsShowTheirSampleChangesInTheirListRows() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }
            await waitUntilDemoAgentsLoad(composition)

            var expected: [ConsoleAgent.ID: String] = [:]
            for agent in composition.console.agents {
                let name = agent.agent.name ?? agent.agent.kind
                let store = productionChangesStore(for: agent, console: composition.console)
                defer { store.cancel() }
                await store.refresh()
                let badge = try #require(
                    ChangesBadge(phase: store.phase, timedOutKeepingContent: store.timedOutKeepingContent),
                    "\(name) has no totals: \(store.phase)")
                expected[agent.id] = "Changes: " + badge.accessibilityValue
                if name == "reviewer" {
                    #expect("\(badge.addedText()) \(badge.removedText())" == "+12 \u{2212}7")
                }
            }
            #expect(expected.count == 5)

            // The Console reopens its last tab; the Agents are on Agents.
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
                frame: CGRect(x: 0, y: 0, width: 402, height: 1_400), rootViewController: controller)
            defer { window.isHidden = true }

            // Two Agents share a value, so one row showing it does not mean
            // the other's read has finished; wait for every store as well.
            // A slow CI runner takes seconds to mount the whole Console.
            let shown = try await ChangesViewTests.eventually(timeout: .seconds(15)) {
                let labels = AccessibilityProbe.labels(in: controller.view)
                return expected.values.allSatisfy { value in labels.contains { $0.contains(value) } }
                    && composition.console.agents.allSatisfy { agent in
                        composition.console.rowChanges.store(for: agent)
                            .map { $0.phase != .loading } ?? false
                    }
            }
            let phases = composition.console.agents.map { agent in
                let phase = composition.console.rowChanges.store(for: agent)
                    .map { String("\($0.phase)".prefix(40)) }
                return "\(agent.agent.name ?? agent.agent.kind): \(phase ?? "none")"
            }
            #expect(
                shown,
                """
                rows showed \(AccessibilityProbe.labels(in: controller.view).filter { $0.contains("Changes") }); \
                stores \(phases); \
                on screen \(AccessibilityProbe.labels(in: controller.view).prefix(40))
                """)
            // One store per Agent, from the list itself.
            for agent in composition.console.agents {
                let store = try #require(composition.console.rowChanges.store(for: agent))
                #expect(store.phase != .loading)
            }
        }

        /// A store from the production factory: the console's Changes reads,
        /// the Host gate, and that Agent's status.
        private func productionChangesStore(
            for agent: ConsoleAgent, console: ConsoleStore
        ) -> ChangesStore {
            console.makeChangesStore(
                agentID: agent.id, hostID: agent.hostID, openingDirectory: agent.directory)
        }

        private func waitUntilDemoAgentsLoad(_ composition: DemoScreenshotComposition) async {
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
        }

        private func expectTotalsMatchFiles(_ changes: CheckoutChanges) {
            let untracked = changes.files.filter { $0.kind == .untracked }
            #expect(changes.totals.untrackedItems == untracked.count)
            #expect(changes.totals.trackedFiles == changes.files.count - untracked.count)
            var added = 0
            var removed = 0
            for file in changes.files {
                if file.kind == .untracked {
                    #expect(file.lineCounts == nil)
                    #expect(file.staging == nil)
                } else {
                    #expect(file.lineCounts != nil)
                }
                if case .lines(let fileAdded, let fileRemoved) = file.lineCounts {
                    added += fileAdded
                    removed += fileRemoved
                }
            }
            #expect(changes.totals.added == added)
            #expect(changes.totals.removed == removed)
            #expect(changes.totals.linesAreComplete)
            #expect(changes.totals.linesAreAvailable)
        }

        private func listsLikeProduction(_ files: [ChangedFile]) -> Bool {
            let ordered = files.sorted { lhs, rhs in
                let lhsConflicted = lhs.kind == .conflicted
                let rhsConflicted = rhs.kind == .conflicted
                if lhsConflicted != rhsConflicted { return lhsConflicted }
                return lhs.path.lexicographicallyPrecedes(rhs.path)
            }
            return files.map(\.path) == ordered.map(\.path)
        }

        private func containsRun(_ lines: [DiffLine], removed: Int, added: Int) -> Bool {
            let kinds = lines.map(\.kind)
            let width = removed + added
            guard width > 0, kinds.count >= width else { return false }
            for index in 0...(kinds.count - width) {
                let removedMatch = (0..<removed).allSatisfy { kinds[index + $0] == .removed }
                let addedMatch = (0..<added).allSatisfy { kinds[index + removed + $0] == .added }
                if removedMatch && addedMatch { return true }
            }
            return false
        }

        private func expectConsistentPatch(_ patch: FilePatch, file: ChangedFile) {
            #expect(!patch.isTruncated)
            #expect(!patch.files.isEmpty)
            if file.lineCounts == .binary {
                #expect(patch.files.contains { $0.isBinary })
                return
            }
            #expect(patch.files.contains { !$0.hunks.isEmpty })
            let lines = patch.files.flatMap(\.hunks).flatMap(\.lines)
            let added = lines.filter { $0.kind == .added }.count
            let removed = lines.filter { $0.kind == .removed }.count
            if file.kind == .untracked {
                #expect(file.lineCounts == nil)
                #expect(added > 0)
                #expect(removed == 0)
            } else if case .lines(let fileAdded, let fileRemoved) = file.lineCounts {
                #expect(added == fileAdded)
                #expect(removed == fileRemoved)
            } else {
                Issue.record("tracked file \(file.displayPath) is missing line counts")
            }
            for hunk in patch.files.flatMap(\.hunks) {
                let context = hunk.lines.filter { $0.kind == .context }.count
                let hunkRemoved = hunk.lines.filter { $0.kind == .removed }.count
                let hunkAdded = hunk.lines.filter { $0.kind == .added }.count
                #expect(context + hunkRemoved == hunk.oldCount)
                #expect(context + hunkAdded == hunk.newCount)
            }
        }

        /// Relative paths, diff lines, and header words. The fixture's checkout
        /// path is excluded: demo mode already names one Checkout `heeler`.
        private func sampleTexts() throws -> [String] {
            var texts: [String] = []
            let directories = Set(
                DemoScreenshotFixture.profiles.values.flatMap { profile in
                    profile.snapshot.agents.compactMap(\.cwd)
                })
            for directory in directories {
                let read = try DemoChangesSample.read(ChangesReadRequest(directory: directory))
                if case .named(let branch) = read.changes.head.branch { texts.append(branch) }
                texts.append(read.changes.head.latestCommit?.subject ?? "")
                texts.append(read.changes.head.upstream?.name ?? "")
                texts.append(read.changes.head.commit ?? "")
                for file in read.changes.files {
                    texts.append(file.displayPath)
                    if let original = file.displayOriginalPath { texts.append(original) }
                    var patches: [FilePatch] = []
                    if file.isUntrackedDirectory {
                        let listing = try DemoChangesSample.listUntrackedDirectory(
                            UntrackedDirectoryRequest(
                                topLevel: read.changes.checkout.topLevel, directory: file.path))
                        for entry in listing.entries {
                            texts.append(entry.displayPath)
                            let request = try #require(
                                FilePatchRequest(file: entry, checkout: read.changes.checkout))
                            patches.append(try DemoChangesSample.patch(request))
                        }
                    } else {
                        let request = try #require(
                            FilePatchRequest(file: file, checkout: read.changes.checkout))
                        patches.append(try DemoChangesSample.patch(request))
                    }
                    for patch in patches {
                        for diff in patch.files {
                            texts.append(diff.oldPath ?? "")
                            texts.append(diff.newPath ?? "")
                            texts.append(diff.summary ?? "")
                            for hunk in diff.hunks {
                                texts.append(hunk.section)
                                texts.append(contentsOf: hunk.lines.map(\.text))
                            }
                        }
                    }
                }
            }
            return texts
        }
    }
#endif
