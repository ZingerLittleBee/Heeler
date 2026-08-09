import Foundation
import Testing

@testable import Heeler

@Suite("File preparer")
struct FilePreparerTests {
  @Test func preparedFileNormalizesUnsafeExtensions() {
    let file = PreparedFile(
      fileURL: URL(fileURLWithPath: "/tmp/source"),
      fileExtension: "../SH",
      byteCount: 1)

    #expect(file.fileExtension.isEmpty)
    #expect(file.remoteFilename == "file")
  }

  @Test func createsProtectedPrivateCopyWithSafeExtension() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("file-preparer-\(UUID().uuidString)", isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
    let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = sourceDirectory.appendingPathComponent("Report.TXT")
    let data = Data("attachment contents".utf8)
    try data.write(to: sourceURL)

    let prepared = try await FilePreparer(
      maximumByteCount: 1_024,
      directory: outputDirectory
    )
    .prepare(sourceURL)

    #expect(prepared.fileExtension == "txt")
    #expect(prepared.remoteFilename == "file.txt")
    #expect(prepared.byteCount == Int64(data.count))
    #expect(try Data(contentsOf: prepared.fileURL) == data)
    #expect(prepared.fileURL.deletingLastPathComponent() == outputDirectory)
  }

  @Test func rejectsFilesAboveTheConfiguredLimitWithoutLeavingACopy() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("file-preparer-limit-\(UUID().uuidString)", isDirectory: true)
    let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("large.bin")
    try Data(repeating: 0x41, count: 9).write(to: sourceURL)

    await #expect(throws: FilePreparationError.sourceTooLarge) {
      try await FilePreparer(maximumByteCount: 8, directory: outputDirectory)
        .prepare(sourceURL)
    }
    let remnants = try? FileManager.default.contentsOfDirectory(
      at: outputDirectory,
      includingPropertiesForKeys: nil)
    #expect(remnants?.isEmpty != false)
  }
}
