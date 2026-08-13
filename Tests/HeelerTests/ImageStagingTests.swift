import Foundation
import Testing

@testable import Heeler

@Suite("Attachment staging domain")
struct ImageStagingTests {
    @Test func stagedImagesRequireAControlFreeAbsoluteHostPath() throws {
        #expect(throws: AttachmentStagingError.invalidRemotePath) {
            _ = try StagedImage(path: "tmp/image.png")
        }
        #expect(throws: AttachmentStagingError.invalidRemotePath) {
            _ = try StagedImage(path: "/tmp/image\u{0}.png")
        }
        #expect(try StagedImage(path: "/private/tmp/image.png").path == "/private/tmp/image.png")
    }

    @Test func progressReportsRealTransferredBytes() {
        let progress = AttachmentStageProgress(transferredBytes: 32, totalBytes: 128)
        #expect(progress.fractionCompleted == 0.25)
        #expect(
            AttachmentStageProgress(
                transferredBytes: 0,
                totalBytes: 0
            ).fractionCompleted == 0)
    }

    @Test func scriptedTransportStagesFilesWithTypedProgressAndOutcome() async throws {
        let file = PreparedFile(
            fileURL: URL(fileURLWithPath: "/tmp/scripted-report.md"),
            fileExtension: "md",
            byteCount: 128)
        let expected = try StagedFile(path: "/tmp/staged/file.md")
        let progress = AttachmentProgressRecorder()
        let transport = ScriptedTransport()
        await transport.configureFileStaging(outcomes: [.success(expected)])

        let staged = try await transport.stageFile(file) { value in
            await progress.record(value)
        }

        #expect(staged == expected)
        #expect(await transport.fileStageRequests == [file])
        #expect(await progress.values == [
            AttachmentStageProgress(transferredBytes: 0, totalBytes: 128),
            AttachmentStageProgress(transferredBytes: 128, totalBytes: 128),
        ])
    }
}

private actor AttachmentProgressRecorder {
    private(set) var values: [AttachmentStageProgress] = []

    func record(_ progress: AttachmentStageProgress) {
        values.append(progress)
    }
}
