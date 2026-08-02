import Foundation
import Testing

@testable import Heeler

@Suite("Image staging domain")
struct ImageStagingTests {
    @Test func stagedImagesRequireAControlFreeAbsoluteHostPath() throws {
        #expect(throws: ImageStagingError.invalidRemotePath) {
            _ = try StagedImage(path: "tmp/image.png")
        }
        #expect(throws: ImageStagingError.invalidRemotePath) {
            _ = try StagedImage(path: "/tmp/image\u{0}.png")
        }
        #expect(try StagedImage(path: "/private/tmp/image.png").path == "/private/tmp/image.png")
    }

    @Test func progressReportsRealTransferredBytes() {
        let progress = ImageStageProgress(transferredBytes: 32, totalBytes: 128)
        #expect(progress.fractionCompleted == 0.25)
        #expect(
            ImageStageProgress(transferredBytes: 0, totalBytes: 0).fractionCompleted == 0)
    }
}
