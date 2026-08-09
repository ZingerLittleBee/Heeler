import Foundation
import Testing

@testable import Heeler

@Suite("Composer attachments")
@MainActor
struct ComposerAttachmentTests {
    @Test func linksActionOnlyAppearsWhenLinksExist() {
        #expect(AgentComposerLinkPresentation(count: 0) == nil)

        let oneLink = AgentComposerLinkPresentation(count: 1)
        #expect(oneLink?.count == 1)
        #expect(oneLink?.accessibilityValue == "1 distinct link")

        let multipleLinks = AgentComposerLinkPresentation(count: 3)
        #expect(multipleLinks?.count == 3)
        #expect(multipleLinks?.accessibilityValue == "3 distinct links")
    }

    @Test func stagedImagePathIsInsertedIntoDraftWithoutATerminalInputSession() async throws {
        let prepared = try makePreparedImage()
        let composer = RecordingComposerDraft()
        let input = TerminalInputController()
        let store = ImageAttachStore(
            preparer: StaticImagePreparer(prepared: prepared),
            stageImage: { _, reporter in
                await reporter.report(
                    ImageStageProgress(transferredBytes: 32, totalBytes: 32))
                return try StagedImage(path: "/tmp/staged/image.jpg")
            },
            clipboard: RecordingAttachmentClipboard(),
            input: input,
            composer: composer)

        #expect(input.liveGeneration == nil)
        store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil { store.state.isCompleted }

        #expect(composer.draft == "/tmp/staged/image.jpg ")
        #expect(store.state.completedResult?.inserted == true)
    }

    @Test func stagedFilePathIsInsertedAndCopied() async throws {
        let prepared = try makePreparedFile()
        let composer = RecordingComposerDraft()
        let clipboard = RecordingAttachmentClipboard()
        let store = FileAttachStore(
            preparer: StaticFilePreparer(prepared: prepared),
            stageFile: { _, reporter in
                await reporter.report(
                    ImageStageProgress(transferredBytes: 64, totalBytes: 64))
                return try StagedFile(path: "/tmp/staged/file.txt")
            },
            clipboard: clipboard,
            composer: composer)

        store.select(URL(fileURLWithPath: "/provider/report.txt"))
        try await waitUntil {
            if case .completed = store.state { true } else { false }
        }

        #expect(composer.draft == "/tmp/staged/file.txt ")
        #expect(clipboard.copiedPaths == ["/tmp/staged/file.txt"])
        guard case .completed(let result) = store.state else {
            Issue.record("Expected a completed file attachment")
            return
        }
        #expect(result.inserted)
        #expect(result.copied)
    }

    private func makePreparedImage() throws -> PreparedImage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-image-\(UUID().uuidString).jpg")
        try Data(repeating: 0x41, count: 32).write(to: url)
        return PreparedImage(
            fileURL: url,
            format: .jpeg,
            pixelWidth: 8,
            pixelHeight: 8,
            byteCount: 32)
    }

    private func makePreparedFile() throws -> PreparedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-file-\(UUID().uuidString).txt")
        try Data(repeating: 0x42, count: 64).write(to: url)
        return PreparedFile(fileURL: url, fileExtension: "txt", byteCount: 64)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

private actor StaticImagePreparer: ImagePreparing {
    let prepared: PreparedImage

    init(prepared: PreparedImage) {
        self.prepared = prepared
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        prepared
    }
}

private actor StaticFilePreparer: FilePreparing {
    let prepared: PreparedFile

    init(prepared: PreparedFile) {
        self.prepared = prepared
    }

    func prepare(_ sourceURL: URL) async throws -> PreparedFile {
        prepared
    }
}

@MainActor
private final class RecordingComposerDraft: ComposerDraftOperations {
    private(set) var draft = ""

    func replaceDraft(with text: String) {
        draft = text
    }

    func insertIntoDraft(_ text: String) {
        draft.append(text)
    }
}

@MainActor
private final class RecordingAttachmentClipboard: ImageClipboard {
    private(set) var copiedPaths: [String] = []

    func copy(_ path: String) throws {
        copiedPaths.append(path)
    }
}
