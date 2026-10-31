import Foundation
import Testing
import UIKit

@testable import Heeler

/// Staged Images and Files on a core Host from the Composer down: the real
/// Console, Host session, link and Composer session, with the SSH connection
/// and the core scripted.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreStagingTests {
    private static let agentRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("claude")]), "keep": .bool(false), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ]),
    ])

    @MainActor
    private struct Fixture {
        let scripted = ScriptedCoreHost(
            channel: .core(.init(id: "c1", terminals: [HerdrCoreStagingTests.agentRecord])))
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let console: ConsoleStore

        init(platform: HostPlatform = .posix) async throws {
            let scripted = scripted
            await scripted.helper.configure { $0.platform = platform }
            console = ConsoleStore(
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
                        },
                        keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-staging-\(UUID().uuidString)") ?? .standard))
            console.setHosts([host])
            await console.resume()
            try await HerdrCoreStagingTests.until("the Agent") { [console] in !console.agents.isEmpty }
        }

        var session: AgentComposerSession {
            get throws { console.composerSession(for: try #require(console.agents.first)) }
        }

        func finish() async {
            console.setHosts([])
            await console.suspend()
        }
    }

    private static func until(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private static func pickedPhoto() throws -> ComposerStagingStore.Source {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return .photo(DataImageSelection(data: try #require(image.pngData())))
    }

    private static func pickedFile(contents: Data) throws -> (source: ComposerStagingStore.Source, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-staging-\(UUID().uuidString).txt")
        try contents.write(to: url)
        return (.file(url), url)
    }

    private static func hasCompleted(
        _ medium: ComposerStagingStore.Medium, _ session: AgentComposerSession
    ) -> Bool {
        if case .completed(let outcome) = session.staging.state { return outcome.medium == medium }
        return false
    }

    /// What a Console reads on its own. Anything else reached the core because
    /// of the upload.
    private static let consoleReads: Set<String> = ["events.subscribe", "doc.get", "server.status"]

    @Test func aCoreAgentsComposerStagesAnImageAndAFileThroughHostServices() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session

        try #require(session.staging.begin(try Self.pickedPhoto()) != nil)
        try await Self.until("the image") { Self.hasCompleted(.image, session) }
        let contents = Data("notes".utf8)
        let file = try Self.pickedFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: file.url) }
        try #require(session.staging.begin(file.source) != nil)
        try await Self.until("the file") { Self.hasCompleted(.file, session) }

        let staged = await fixture.scripted.stagedFiles
        #expect(staged.map(\.path) == [
            "/tmp/heeler-stage/stage-0/image.jpg", "/tmp/heeler-stage/stage-1/file.txt",
        ])
        #expect(staged.last?.contents == contents)
        #expect(session.composer.draft == "/tmp/heeler-stage/stage-0/image.jpg /tmp/heeler-stage/stage-1/file.txt ")

        // The path waits in the draft; delivering it is Send's job.
        #expect(Set(await fixture.scripted.methods).isSubset(of: Self.consoleReads))
        #expect(await fixture.scripted.attaches.isEmpty)
        await fixture.finish()
    }
}
