import Foundation
import Testing
import UIKit

@testable import Heeler

/// A drop uploads on the staging the screen shows, whatever SwiftUI rebuilds
/// and wherever the retained terminal goes, and only leaving the Agent's
/// detail cancels it.
@MainActor
@Suite("Composer staging ownership")
struct ComposerStagingOwnershipTests {
    // MARK: Retained terminal

    @Test func dropAfterReturningToRetainedTerminalUploads() async throws {
        let fixture = try await ConnectedAgentFixture.make()
        let cache = AgentTerminalCache()
        let owner = UUID()
        let entry = cache.acquire(agent: fixture.agent, console: fixture.console, ownerID: owner)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually { await fixture.transport.hasLiveAttachSession })

        cache.release(entry, ownerID: owner)
        await Self.settle()
        cache.activate(entry, ownerID: owner)

        try await fixture.expectDropUploads()
        await cache.suspend()
        await fixture.tearDown()
    }

    @Test func evictionLeavesStagingAlone() async throws {
        let fixture = try await ConnectedAgentFixture.make()
        let entry = fixture.console.agentTerminals.acquire(
            agent: fixture.agent, console: fixture.console, ownerID: UUID())
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually { await fixture.transport.hasLiveAttachSession })
        let held = try await fixture.dropHeldImage()

        await fixture.console.agentTerminals.reconcile(hostID: fixture.agent.hostID, agents: [])
        #expect(fixture.console.agentTerminals.entries.isEmpty)
        #expect(!entry.isRetained)
        #expect(fixture.session.staging.state.isBusy)

        try await fixture.expectUploaded(held)
        await fixture.tearDown()
    }

    // MARK: Suspension

    @Test func suspendMarksUploadBackgroundInterrupted() async throws {
        let fixture = try await ConnectedAgentFixture.make()
        let held = try await fixture.dropHeldImage()

        await fixture.console.suspend()
        await held.gate.open()
        try #require(
            await Self.eventually {
                if case .backgroundInterrupted = fixture.session.staging.state { true } else { false }
            })

        #expect(fixture.session.staging.presentation?.commands == [.retry, .dismiss])
        #expect(fixture.composer.imageAttachments.map(\.id) == [held.attachmentID])
        #expect(!fixture.composer.canSend)
        fixture.session.staging.perform(.dismiss)
        #expect(!fixture.composer.hasPendingDroppedImages)
        #expect(fixture.composer.imageAttachments.isEmpty)
        await fixture.tearDown()
    }

    // MARK: Session

    @Test func secondWindowKeepsUploadUntilLastDetailLeaves() async throws {
        let fixture = SessionFixture()
        let (first, second) = (UUID(), UUID())
        fixture.session.detailDidAppear(first)
        fixture.session.detailDidAppear(second)
        try await fixture.dropFirstImage()

        #expect(fixture.session.detailDidDisappear(first) == nil)
        await ComposerStagingOwnershipTests.settle()
        #expect(fixture.session.staging.state.isBusy)
        #expect(fixture.composer.hasPendingDroppedImages)

        let leave = try #require(fixture.session.detailDidDisappear(second))
        #expect(!fixture.composer.hasPendingDroppedImages)
        await fixture.gate.open()
        await leave.value
        #expect(fixture.session.staging.state == .idle)
        #expect(fixture.composer.draft.isEmpty)
    }

    @Test func reappearDuringLeaveStartsQueuedDrop() async throws {
        let fixture = SessionFixture()
        let window = UUID()
        fixture.session.detailDidAppear(window)
        try await fixture.dropFirstImage()

        let leave = try #require(fixture.session.detailDidDisappear(window))
        fixture.session.detailDidAppear(window)
        fixture.composer.acceptDrop([.image(try ConnectedAgentFixture.tinyJPEGData(), suggestedName: "b.jpg")])
        #expect(fixture.composer.hasPendingDroppedImages)

        // The leave still cancels the first upload; the drop accepted after
        // the detail came back is the one that lands.
        await fixture.gate.open()
        await leave.value
        try #require(
            await Self.eventually {
                fixture.composer.readyImagePaths == ["/tmp/heeler-staged/second.jpg"]
                    && !fixture.composer.hasPendingDroppedImages
            })
        #expect(fixture.composer.draft.isEmpty)
        #expect(await fixture.stager.calls == 2)
    }

    /// Lets queued lifecycle work run: a placeholder's teardown, a release.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    static func eventually(
        timeout: Duration = .seconds(5), condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

/// A Console connected to one scripted Claude Agent, and the detail a
/// window would show for it.
@MainActor
private struct ConnectedAgentFixture {
    static let stagedPath = "/tmp/heeler-staged/drop.jpg"

    /// An image whose Host upload waits on `gate`.
    struct HeldDrop {
        let gate: ScriptedTransportCallGate
        let attachmentID: UUID
    }

    let transport: ScriptedTransport
    let console: ConsoleStore
    let agent: ConsoleAgent
    let defaults: UserDefaults
    let suiteName: String

    var session: AgentComposerSession { console.composerSession(for: agent) }
    var composer: AgentComposerStore { session.composer }

    static func make() async throws -> ConnectedAgentFixture {
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([Host.fixture()])
        await console.resume()
        try #require(await ComposerStagingOwnershipTests.eventually { console.agents.count == 1 })
        let suiteName = "composer-staging-ownership-\(UUID().uuidString)"
        return ConnectedAgentFixture(
            transport: transport, console: console, agent: try #require(console.agents.first),
            defaults: try #require(UserDefaults(suiteName: suiteName)), suiteName: suiteName)
    }

    /// Drops one image and waits until its Host upload is held.
    func dropHeldImage() async throws -> HeldDrop {
        let gate = ScriptedTransportCallGate()
        await transport.configureImageStaging(
            outcomes: [.success(try StagedImage(path: Self.stagedPath))], gate: gate)
        composer.acceptDrop([.image(try Self.tinyJPEGData(), suggestedName: "drop.jpg")])
        let attachmentID = try #require(composer.imageAttachments.first?.id)
        try #require(
            await ComposerStagingOwnershipTests.eventually { await gate.entryCount == 1 },
            "the upload should reach the Host")
        return HeldDrop(gate: gate, attachmentID: attachmentID)
    }

    /// Lets a held upload finish and expects its Host path in `readyImagePaths`.
    func expectUploaded(_ held: HeldDrop) async throws {
        await held.gate.open()
        let uploaded = await ComposerStagingOwnershipTests.eventually {
            composer.readyImagePaths == [Self.stagedPath] && !composer.hasPendingDroppedImages
        }
        #expect(uploaded, "the Host path should settle on the attachment without touching draft")
        #expect(composer.draft.isEmpty)
        #expect(await transport.stageRequests.count == 1)
    }

    /// One drop runs on the staging the detail shows and lands its Host path.
    func expectDropUploads() async throws {
        let held = try await dropHeldImage()
        #expect(session.staging.state.isBusy, "the upload should run on the staging the screen shows")
        try await expectUploaded(held)
    }

    func tearDown() async {
        await console.agentTerminals.suspend()
        console.setHosts([])
        defaults.removePersistentDomain(forName: suiteName)
    }

    static func tinyJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }
}

/// A session alone, with an image stager whose first upload waits on `gate`.
@MainActor
private struct SessionFixture {
    let gate = ScriptedTransportCallGate()
    let stager: HeldImageStager
    let session: AgentComposerSession
    var composer: AgentComposerStore { session.composer }

    init() {
        let stager = HeldImageStager(
            gate: gate, paths: ["/tmp/heeler-staged/first.jpg", "/tmp/heeler-staged/second.jpg"])
        self.stager = stager
        session = AgentComposerSession(
            composer: AgentComposerStore(target: "w1:p1") { _ in Agent(.fixture(paneID: "w1:p1")) },
            stageImage: { _, _ in try await stager.stage() },
            stageFile: { _, _ in throw AttachmentStagingError.transferFailed })
    }

    /// Drops one image and waits until its upload is held.
    func dropFirstImage() async throws {
        composer.acceptDrop([.image(try ConnectedAgentFixture.tinyJPEGData(), suggestedName: "a.jpg")])
        try #require(
            await ComposerStagingOwnershipTests.eventually { await gate.entryCount == 1 },
            "the first upload should start")
        #expect(session.staging.state.isBusy)
    }
}

private actor HeldImageStager {
    private let gate: ScriptedTransportCallGate
    private var paths: [String]
    private(set) var calls = 0

    init(gate: ScriptedTransportCallGate, paths: [String]) {
        self.gate = gate
        self.paths = paths
    }

    /// Each call takes the next path, whether or not it ends cancelled.
    func stage() async throws -> StagedImage {
        calls += 1
        guard !paths.isEmpty else { throw AttachmentStagingError.transferFailed }
        let path = paths.removeFirst()
        if calls == 1 { await gate.waitUntilOpen() }
        try Task.checkCancellation()
        return try StagedImage(path: path)
    }
}
