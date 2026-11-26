import Foundation
import HeelerSSH
import Synchronization
import Testing
import UIKit

@testable import Heeler

/// Images and files a Rex Agent's Composer stages (ADR 0056), as a tmux
/// Agent's do (ADRs 0005 and 0006): through a seam on the Host's SSH
/// connection that can do nothing else, for the server the Agent opened on
/// only, offered wherever Chat or the Composer is on a Host whose server named
/// Linux, macOS or Windows, and typed with the message, once. Paths, names and
/// contents are invented.
@MainActor
@Suite("Rex staging", .timeLimit(.minutes(1)))
struct RexStagingTests {
    private static let socket = "/run/user/1000/rex/server.sock"
    private static let prompt = ["\u{1B}[0m\u{1B}[2m>\u{1B}[0m ", "", "", ""]

    private static var rex: Host {
        Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: socket))
    }

    private struct IgnoringClipboard: AttachmentClipboard {
        func copy(_: String) throws {}
    }

    private func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        throw CancellationError()
    }

    private static func photo() throws -> ComposerStagingStore.Source {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return .photo(DataImageSelection(data: try #require(image.pngData())))
    }

    /// A file picked by this name, alone in a folder of its own: remove the folder.
    private static func pickedFile(named name: String, contents: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rex-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private static func completed(_ staging: ComposerStagingStore) -> ComposerStagingStore.Outcome? {
        if case .completed(let outcome) = staging.state { return outcome }
        return nil
    }

    private static func failure(_ staging: ComposerStagingStore) -> ComposerStagingStore.Failure? {
        if case .failed(let failure) = staging.state { return failure }
        return nil
    }

    // MARK: A Console with one Rex Agent

    /// A Console whose one Rex Host dials `connection`, its studio's left
    /// terminal running Claude Code reporting `state`, with that terminal's
    /// screen and keyboard answered as Chat reads them.
    @MainActor
    private struct Rig {
        let console: ConsoleStore
        let connection: ScriptedRexHost
        let server: FakeRexServer
        let agent: ConsoleAgent

        func pasted() async -> [String] {
            await RexChatRig.inputs(server).filter { $0.method == "block.event" }.compactMap {
                $0.payload?["event"]?["payload"]?["text"]?.stringValue
            }
        }

        func written() async -> [String] {
            await RexChatRig.inputs(server).filter { $0.method == RexChatRig.write }.compactMap {
                $0.payload?["args"]?["data"]?.stringValue
            }
        }

        /// The Agent's Composer with a staging of the test's own, which copies
        /// nothing to the clipboard, over the Console's stagers for the Agent.
        func composer() -> (composer: AgentComposerStore, staging: ComposerStagingStore) {
            let session = console.composerSession(for: agent)
            let staging = ComposerStagingStore(
                stageImage: console.imageStager(for: agent.hostID, beside: agent.agent.paneID, keepingTo: session.corePin),
                stageFile: console.fileStager(for: agent.hostID, beside: agent.agent.paneID, keepingTo: session.corePin),
                clipboard: IgnoringClipboard(), composer: session.composer,
                // As the Console's own staging for a Rex Agent says them.
                saysTransportFailures: true)
            session.composer.bindStaging(staging)
            return (session.composer, staging)
        }
    }

    private func rig(reporting state: String? = "idle", connection: ScriptedRexHost? = nil) async throws -> Rig {
        let world = FakeRexWorld(sessions: [RexChatRig.studio(reporting: state)])
        let server = FakeRexServer()
        await world.install(on: server)
        await FakeRexChatBlock(lines: Self.prompt).install(on: server, world: world)
        let connection = connection ?? ScriptedRexHost(control: [.server(server)])
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "rex-staging-pins-\(UUID().uuidString)") ?? .standard),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") }, keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession { throw TransportError.sshUnreachable(detail: "unscripted") }
            },
            makeTmuxSession: { host in
                TmuxHostSession(storedPaths: host.storedTmuxPaths) { _ in
                    throw TransportError.sshUnreachable(detail: "unscripted")
                }
            },
            makeRexSession: { host in
                RexHostSession(
                    storedSocket: host.rexSocket,
                    connect: { socket, previous in
                        try await RexSSHTransport.connect(
                            over: connection, socket: socket, resuming: previous, options: .testing)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)))
            },
            coreHostMemory: HerdrCoreHostMemory(
                defaults: UserDefaults(suiteName: "rex-staging-memory-\(UUID().uuidString)") ?? .standard))
        let rex = Self.rex
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the Agent, with uploads") {
            !console.agents.isEmpty && console.capabilities(for: rex.id).uploads
                && console.isHostReadyForInput(rex.id)
        }
        let agent = try #require(console.agents.first)
        return Rig(console: console, connection: connection, server: server, agent: agent)
    }

    // MARK: What a Rex Host offers

    /// Uploads open with Chat, once the server has named Linux, macOS or
    /// Windows, and so do the detail's attachments on Chat and the terminal.
    /// The rest of a Rex Host's menus stay as they were.
    @Test(arguments: [
        (nil, false), (HerdrCoreLocator.linuxKernel, true), (HerdrCoreLocator.macOSKernel, true),
        (HerdrCoreLocator.windowsKernel, true),
    ] as [(String?, Bool)])
    func uploadsOpenWhereChatDoes(kernel: String?, opens: Bool) {
        let capabilities = HostCapabilities(serverKind: .rex, coreKernel: kernel)
        #expect(capabilities.uploads == opens)
        #expect(capabilities.chat == opens)
        #expect(capabilities.composerSend)
        let offers = AgentDetailMenuOffers(
            capabilities: capabilities, workspaceID: "session:studio", removesSavedChat: false)
        #expect(offers.attachments == opens)
        #expect(!offers.newAgent && !offers.renameAgent && !offers.renameWorkspace && !offers.close)
        // The catalog's Host knows no kernel, so nothing offers them ahead.
        #expect(!Self.rex.capabilities.uploads)
    }

    // MARK: Native Windows (ADR 0056's update of 2026-11-25)

    /// On native Windows the stage folder sits in the account's temp folder,
    /// opened over SFTP as `/C:/...`, and the Agent reads the same file as
    /// `C:\...`. Anything that is no SFTP drive path gives no Windows path.
    @Test func aWindowsStageLivesInTheAccountsTempFolder() throws {
        let parent = WindowsStagePath.parentDirectory(home: "/C:/Users/dev", suffix: "a1b2c3d4")
        #expect(parent == "/C:/Users/dev/AppData/Local/Temp/heeler.a1b2c3d4")
        #expect(RemoteFilePath.isAcceptable(parent))
        #expect(
            WindowsStagePath.windowsPath(fromSFTP: "\(parent)/stage-0f1e/image.png")
                == #"C:\Users\dev\AppData\Local\Temp\heeler.a1b2c3d4\stage-0f1e\image.png"#)
        #expect(WindowsStagePath.windowsPath(fromSFTP: "/home/dev/image.png") == nil)
        #expect(WindowsStagePath.windowsPath(fromSFTP: #"C:\Users\dev"#) == nil)
        let suffix = WindowsStagePath.randomSuffix()
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) })
        let staged = try StagedImage(path: #"C:\Users\dev\AppData\Local\Temp\heeler.a1b2c3d4\stage-0f1e\image.png"#)
        #expect(staged.path.hasPrefix("C:\\"))
    }

    /// A sent message shows a Windows stage's image or video as a label, as
    /// it shows a POSIX one, and leaves any other Windows path as it is.
    @Test func aWindowsStagedPathReadsAsStagedMedia() {
        let stage = #"C:\Users\dev\AppData\Local\Temp\heeler.a1b2c3d4\stage-0f1e"#
        #expect(ChatImageLink.isStagedImagePath(stage + #"\image.png"#))
        #expect(ChatImageLink.isStagedVideoPath(stage + #"\clip.mp4"#))
        #expect(!ChatImageLink.isStagedImagePath(#"C:\Users\dev\Pictures\image.png"#))
        #expect(!ChatImageLink.isStagedImagePath(stage + #"\notes.txt"#))
    }

    // MARK: A Windows stage's steps

    /// A Windows Host's SFTP, in memory: folders, files by size, every step in
    /// order, and the steps told to fail.
    private final class WindowsFiles: Sendable {
        struct State {
            var folders: Set<String> = []
            var sizes: [String: UInt64] = [:]
            var steps: [String] = []
            var failingFolders: Set<String> = []
            var writtenSize: UInt64 = 4
            var renameFails = false
        }

        let state = Mutex(State())

        var files: WindowsStageUpload.Files {
            WindowsStageUpload.Files(
                makeDirectory: { [self] path in
                    try self.state.withLock { state in
                        state.steps.append("mkdir \(path)")
                        guard !state.failingFolders.contains(path) else { throw SSHError.sftpFailure(status: 2) }
                        state.folders.insert(path)
                    }
                },
                write: { [self] path in
                    self.state.withLock { state in
                        state.steps.append("write \(path)")
                        state.sizes[path] = state.writtenSize
                    }
                },
                size: { [self] path in self.state.withLock { $0.sizes[path] } },
                rename: { [self] from, to in
                    try self.state.withLock { state in
                        state.steps.append("rename \(from)")
                        guard !state.renameFails else { throw SSHError.sftpFailure(status: 2) }
                        state.sizes[to] = state.sizes.removeValue(forKey: from)
                    }
                },
                remove: { [self] path in
                    self.state.withLock { state in
                        state.steps.append("remove \(path)")
                        state.sizes[path] = nil
                    }
                })
        }
    }

    private static let windowsHome = "/C:/Users/dev"
    private static let windowsParent = "/C:/Users/dev/AppData/Local/Temp/heeler.a1b2c3d4"

    private static func stage(
        _ upload: inout WindowsStageUpload, on host: WindowsFiles, id: String = "0f1e", byteCount: Int64 = 4
    ) async throws -> String {
        try await upload.stage(
            "image.png", byteCount: byteCount, home: windowsHome, files: host.files, suffix: { "a1b2c3d4" },
            stageID: { id })
    }

    /// The first stage makes the connection's folder, then its own, writes
    /// the `.part`, checks its size and renames it; the next stage keeps the
    /// folder, and the Agent reads the Windows form of the path.
    @Test func aWindowsStageMakesItsFolderOnceAndRenamesThePart() async throws {
        let host = WindowsFiles()
        var upload = WindowsStageUpload()

        let path = try await Self.stage(&upload, on: host)

        #expect(path == #"C:\Users\dev\AppData\Local\Temp\heeler.a1b2c3d4\stage-0f1e\image.png"#)
        #expect(upload.parent == Self.windowsParent)
        let stage = "\(Self.windowsParent)/stage-0f1e"
        #expect(
            host.state.withLock { $0.steps } == [
                "mkdir \(Self.windowsParent)", "mkdir \(stage)", "write \(stage)/image.png.part",
                "rename \(stage)/image.png.part",
            ])
        #expect(host.state.withLock { $0.sizes } == ["\(stage)/image.png": 4])

        _ = try await Self.stage(&upload, on: host, id: "2a3b")
        #expect(host.state.withLock { $0.steps.filter { $0.hasPrefix("mkdir") } }.count == 3)
        #expect(host.state.withLock { $0.steps }.contains("mkdir \(Self.windowsParent)/stage-2a3b"))
    }

    /// A kept folder that was cleaned away is made again once, under a new
    /// name, and kept in its place.
    @Test func aKeptFolderThatIsGoneIsMadeAgainOnce() async throws {
        let host = WindowsFiles()
        let gone = "/C:/Users/dev/AppData/Local/Temp/heeler.gone0000"
        host.state.withLock { $0.failingFolders = ["\(gone)/stage-0f1e"] }
        var upload = WindowsStageUpload(parent: gone)

        _ = try await Self.stage(&upload, on: host)

        #expect(upload.parent == Self.windowsParent)
        #expect(
            host.state.withLock { $0.steps.filter { $0.hasPrefix("mkdir") } } == [
                "mkdir \(gone)/stage-0f1e", "mkdir \(Self.windowsParent)", "mkdir \(Self.windowsParent)/stage-0f1e",
            ])
    }

    /// A temp folder that cannot be made says so, and nothing is written.
    @Test func aFolderThatCannotBeMadeSaysSoAndWritesNothing() async throws {
        let host = WindowsFiles()
        host.state.withLock { $0.failingFolders = [Self.windowsParent] }
        var upload = WindowsStageUpload()

        await #expect(throws: AttachmentStagingError.remoteTemporaryDirectoryFailed) {
            _ = try await Self.stage(&upload, on: host)
        }
        #expect(upload.parent == nil)
        #expect(!host.state.withLock { $0.steps }.contains { $0.hasPrefix("write") })
    }

    /// A `.part` of another size, or one that cannot be renamed, is removed;
    /// the connection's folder is still kept.
    @Test(arguments: [false, true])
    func aPartThatFailsIsRemoved(failsRename: Bool) async throws {
        let host = WindowsFiles()
        host.state.withLock {
            $0.writtenSize = failsRename ? 4 : 3
            $0.renameFails = failsRename
        }
        var upload = WindowsStageUpload()

        if failsRename {
            await #expect(throws: SSHError.sftpFailure(status: 2)) { _ = try await Self.stage(&upload, on: host) }
        } else {
            await #expect(throws: AttachmentStagingError.byteCountMismatch) {
                _ = try await Self.stage(&upload, on: host)
            }
            #expect(!host.state.withLock { $0.steps }.contains { $0.hasPrefix("rename") })
        }
        let part = "\(Self.windowsParent)/stage-0f1e/image.png.part"
        #expect(host.state.withLock { $0.steps.last } == "remove \(part)")
        #expect(host.state.withLock { $0.sizes }.isEmpty)
        #expect(upload.parent == Self.windowsParent)
    }

    // MARK: The seam

    /// The staging a Rex Host is handed is no Host's services, Transport,
    /// connection or reads, so nothing can cast it back to do anything else;
    /// it stages an image and a file over the Host's SSH connection and asks
    /// nothing of the server. The Host's services stay closed.
    @Test func theSeamStagesAndDoesNothingElse() async throws {
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt))
        defer { rig.end() }
        let staging = try await rig.projection.session.withConnection { $0.transport.staging }
        #expect((staging as? any HostServices) == nil)
        #expect((staging as? any Transport) == nil)
        #expect((staging as? any RexHostConnection) == nil)
        #expect((staging as? any RexHostReads) == nil)
        await #expect(throws: TransportError.self) {
            try await rig.projection.withHostServices { _ in 0 }
        }
        let logged = await rig.connection.log
        let asked = await rig.server.requests.count

        let contents = Data("lab notes".utf8)
        let url = try Self.pickedFile(named: "notes.txt", contents: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = PreparedFile(
            fileURL: url, fileExtension: "txt", byteCount: Int64(contents.count), pickedName: "lab notes.txt")
        let image = PreparedImage(
            fileURL: url, format: .jpeg, pixelWidth: 1, pixelHeight: 1, byteCount: Int64(contents.count))
        let pin = TerminalCorePin(joined: rig.projection.inventoryCore)
        let progress = Mutex<[Int64]>([])
        let reporter = AttachmentStageProgressReporter { report in progress.withLock { $0.append(report.transferredBytes) } }

        let stagedFile = try await rig.projection.fileStager(beside: RexChatRig.paneID, keepingTo: pin)(file, reporter)
        let stagedImage = try await rig.projection.imageStager(beside: RexChatRig.paneID, keepingTo: pin)(image, reporter)

        #expect(stagedFile.path == "/tmp/heeler.lab0/stage-0/lab_notes.txt")
        #expect(stagedImage.path == "/tmp/heeler.lab1/stage-1/image.jpg")
        #expect(await rig.connection.stagedFiles.map(\.contents) == [contents, contents])
        #expect(progress.withLock { $0 } == [0, 9, 0, 9])
        #expect(await rig.connection.log == logged + ["stage lab_notes.txt", "stage image.jpg"])
        #expect(await rig.server.requests.count == asked)
    }

    /// A staging begun for an Agent of a server instance that is gone stages
    /// nothing, as Chat's requests to the block do, and says so in Rex's
    /// words, with no Retry; one for the instance on the connection stages.
    @Test func aStagingKeepsToTheServerItsAgentOpenedOn() async throws {
        let world = FakeRexWorld(sessions: [RexChatRig.studio()])
        let rig = try await RexChatRig.start(FakeRexChatBlock(lines: Self.prompt), world: world, servers: 2)
        defer { rig.end() }
        let first = rig.projection.inventoryCore
        let pin = TerminalCorePin(joined: first)

        world.restart(as: "instance-b")
        await rig.server.close(.goingAway)
        try await rig.waitUntil("the next instance") {
            rig.projection.inventoryCore != first && !rig.projection.isAwaitingSnapshot
        }

        let url = try Self.pickedFile(named: "notes.txt", contents: Data("lab".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = PreparedFile(fileURL: url, fileExtension: "txt", byteCount: 3)
        let image = PreparedImage(fileURL: url, format: .jpeg, pixelWidth: 1, pixelHeight: 1, byteCount: 3)
        let reporter = AttachmentStageProgressReporter { _ in }
        await #expect(throws: TransportError.rexServerGone) {
            _ = try await rig.projection.fileStager(beside: RexChatRig.paneID, keepingTo: pin)(file, reporter)
        }
        await #expect(throws: TransportError.rexServerGone) {
            _ = try await rig.projection.imageStager(beside: RexChatRig.paneID, keepingTo: pin)(image, reporter)
        }
        #expect(await rig.connection.stagedFiles.isEmpty)
        #expect(await !rig.connection.log.contains { $0.hasPrefix("stage ") })

        let composer = AgentComposerStore(target: RexChatRig.paneID) { _ in throw TransportError.cancelled }
        let staging = ComposerStagingStore(
            stageImage: rig.projection.imageStager(beside: RexChatRig.paneID, keepingTo: pin),
            stageFile: rig.projection.fileStager(beside: RexChatRig.paneID, keepingTo: pin),
            clipboard: IgnoringClipboard(), composer: composer,
            saysTransportFailures: rig.projection.stagingSaysTransportFailures)
        try #require(staging.begin(.file(url)) != nil)
        try await rig.waitUntil("the refusal") { Self.failure(staging) != nil }
        #expect(Self.failure(staging)?.message == TransportError.rexServerGone.presentation.message)
        #expect(Self.failure(staging)?.isRetryable == false)
        #expect(composer.draft.isEmpty)

        let current = TerminalCorePin(joined: rig.projection.inventoryCore)
        let staged = try await rig.projection.fileStager(beside: RexChatRig.paneID, keepingTo: current)(file, reporter)
        #expect(await rig.connection.stagedFiles.map(\.path) == [staged.path])
    }

    /// A staging holds one ordinary session slot while its bytes go. The
    /// control link's events slot and the data links' attach slots are not
    /// among them, so a held upload holds up no inventory, typing or open
    /// terminal, and Chat's reads still take the slots left.
    @Test func aHeldStagingHoldsUpNoLinkAndNoRead() async throws {
        let world = FakeRexWorld(sessions: [RexChatRig.studio()])
        let server = FakeRexServer()
        await world.install(on: server)
        let admission = SSHChannelAdmission()
        let connection = ScriptedRexHost(
            control: [.server(server)], data: [.server(FakeRexServer(), welcome: nil)], admission: admission,
            processes: { _ in [:] })
        let dialer = RexHostSessionTests.Dialer([connection])
        let session = RexHostSession(
            storedSocket: Self.rex.rexSocket, connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)))
        let projection = RexConsoleProjection(host: Self.rex, session: session, pins: PinnedAgentsStore(), onChange: {})
        projection.start(isActive: true)
        defer { projection.end() }
        try await waitUntil("the terminals") { !projection.isAwaitingSnapshot }

        let url = try Self.pickedFile(named: "big.bin", contents: Data(repeating: 7, count: 64))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = PreparedFile(fileURL: url, fileExtension: "bin", byteCount: 64, pickedName: "big.bin")
        let stager = projection.fileStager(
            beside: RexChatRig.paneID, keepingTo: TerminalCorePin(joined: projection.inventoryCore))
        await connection.holdStages(true)
        let upload = Task { try await stager(file, AttachmentStageProgressReporter { _ in }) }
        try await waitUntil("the upload in its slot") { await connection.stagesEntered == 1 }
        #expect(await admission.snapshot().ordinarySession == 1)

        _ = try await session.withConnection { try await $0.control.call("server.status") }
        let data = try await session.withConnection { try await $0.transport.openDataChannel() }
        let reads = try await session.withConnection { $0.transport.reads }
        _ = try await reads.readProcesses(HostProcessReader.Request(pids: ["4242"]))
        #expect(await admission.snapshot().attach == 1)
        #expect(await admission.snapshot().ordinarySession == 1)

        await connection.holdStages(false)
        #expect(try await upload.value.path == "/tmp/heeler.lab0/stage-0/big.bin")
        #expect(await admission.snapshot().ordinarySession == 0)
        try await data.close(timeout: .zero)
    }

    // MARK: Staged, then sent

    /// An image and a file staged from a Rex Agent's Composer land on the
    /// Host, the file's path in the draft and the image's beside it, and Send
    /// types them with the message as one paste and one Enter in the block's
    /// lane, through Composer Send on either route (Chat's own send policy is
    /// not run here). An Agent at Unknown attaches and sends as one at Idle
    /// does: its status limits Stop and the Blocked Card only.
    @Test(arguments: ["idle", nil] as [String?], [ComposerRoute.terminal, .chat])
    func stagedPathsAreTypedWithTheMessageOnce(state: String?, route: ComposerRoute) async throws {
        let rig = try await rig(reporting: state)
        defer { rig.console.setHosts([]) }
        #expect(rig.agent.agent.status == (state == nil ? .unknown : .idle))
        let offers = AgentDetailMenuOffers(
            capabilities: rig.console.capabilities(for: rig.agent.hostID), workspaceID: rig.agent.agent.workspaceID,
            removesSavedChat: false)
        #expect(offers.attachments)
        let (composer, staging) = rig.composer()

        try #require(staging.begin(try Self.photo()) != nil)
        try await waitUntil("the image") { composer.readyImagePaths.count == 1 }
        let url = try Self.pickedFile(named: "lab notes.txt", contents: Data("lab notes".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try #require(staging.begin(.file(url)) != nil)
        try await waitUntil("the file") { Self.completed(staging)?.medium == .file }

        let image = "/tmp/heeler.lab0/stage-0/image.jpg"
        let file = "/tmp/heeler.lab1/stage-1/lab_notes.txt"
        #expect(await rig.connection.stagedFiles.map(\.path) == [image, file])
        #expect(await rig.connection.stagedFiles.last?.contents == Data("lab notes".utf8))
        #expect(composer.readyImagePaths == [image])
        #expect(composer.draft == "\(file) ")
        #expect(await RexChatRig.inputs(rig.server).isEmpty)

        composer.replaceDraft(with: composer.draft + "compare these")
        var policy = ComposerDeliveryPolicy.terminal
        policy.route = route
        #expect(await composer.send(policy: policy) == .submittedViaAttach)

        #expect(await rig.pasted() == ["\(file) compare these \(image) "])
        #expect(await rig.written() == ["\r"])
        #expect(await RexChatRig.inputs(rig.server).map(\.method) == ["block.event", RexChatRig.write])
        #expect(composer.readyImagePaths.isEmpty && composer.draft.isEmpty)
        #expect(
            await rig.connection.log == ["control \(Self.socket)", "stage image.jpg", "stage lab_notes.txt"])
    }

    /// A staging that fails, as one whose connection dropped mid-transfer
    /// does, one cancelled while its bytes go, and an image removed before
    /// Send type nothing: the draft stays as it was, nothing reaches the
    /// block, and the next Send types the message alone.
    @Test func aFailedCancelledOrRemovedStagingTypesNothing() async throws {
        let rig = try await rig()
        defer { rig.console.setHosts([]) }
        let (composer, staging) = rig.composer()
        composer.replaceDraft(with: "keep this")
        let url = try Self.pickedFile(named: "notes.txt", contents: Data("lab".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await rig.connection.failStages(with: [.transferFailed])
        try #require(staging.begin(.file(url)) != nil)
        try await waitUntil("the failure") { Self.failure(staging) != nil }
        #expect(Self.failure(staging)?.isRetryable == true)
        #expect(composer.draft == "keep this")

        await rig.connection.holdStages(true)
        try #require(staging.begin(try Self.photo()) != nil)
        try await waitUntil("the upload in its slot") { await rig.connection.stagesEntered == 2 }
        staging.perform(.cancel)
        try await waitUntil("the cancel") { !staging.state.isBusy }
        await rig.connection.holdStages(false)
        try await waitUntil("the image gone") { composer.imageAttachments.isEmpty }
        #expect(composer.readyImagePaths.isEmpty)

        try #require(staging.begin(try Self.photo()) != nil)
        try await waitUntil("the image") { composer.readyImagePaths.count == 1 }
        let attachment = try #require(composer.imageAttachments.first)
        composer.removeImageAttachment(id: attachment.id)
        #expect(composer.readyImagePaths.isEmpty)

        #expect(await rig.connection.stagedFiles.count == 1)
        #expect(composer.draft == "keep this")
        #expect(await RexChatRig.inputs(rig.server).isEmpty)

        #expect(await composer.send() == .submittedViaAttach)
        #expect(await rig.pasted() == ["keep this"])
        #expect(await rig.written() == ["\r"])
    }
}
