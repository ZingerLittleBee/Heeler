import Foundation

/// A Staged Image or File on a native Windows core Host, where it goes through the
/// core's `terminal.put` and lands beside the Terminal it names (ADR 0032). Pure:
/// it builds the one call and reads the path out of the answer.
enum HerdrCoreStaging {
    /// What one `terminal.put` takes, exactly this much included (herdr compatibility).
    static let maximumBytes: Int64 = 8 * 1024 * 1024

    struct Source: Sendable, Equatable {
        let fileURL: URL
        let name: String
        let byteCount: Int64

        init(_ image: PreparedImage) {
            fileURL = image.fileURL
            name = "image.\(image.format.fileExtension)"
            byteCount = image.byteCount
        }

        init(_ file: PreparedFile) {
            fileURL = file.fileURL
            name = file.remoteFilename
            byteCount = file.byteCount
        }
    }

    /// Refuses a file past the limit before reading a byte of it.
    static func params(for source: Source, terminal: String) throws -> JSONValue {
        guard source.byteCount <= maximumBytes else { throw AttachmentStagingError.exceedsCoreFileLimit }
        guard source.byteCount > 0,
            let size = try? FileManager.default.attributesOfItem(atPath: source.fileURL.path)[.size] as? NSNumber,
            size.int64Value == source.byteCount
        else { throw AttachmentStagingError.invalidPreparedSource }
        guard let contents = try? Data(contentsOf: source.fileURL) else {
            throw AttachmentStagingError.localReadFailed
        }
        return .object([
            "terminal": .string(terminal),
            "name": .string(source.name),
            "data": .string(contents.base64EncodedString()),
        ])
    }

    /// The path as the core reports it: it may clean or number the name.
    static func path(in result: JSONValue, for source: Source) throws -> String {
        guard let path = result["path"]?.stringValue else {
            throw TransportError.malformedResponse("herdr-core: terminal.put named no path.")
        }
        guard HerdrCoreWire.integer(result["bytes"]) == Int(source.byteCount) else {
            throw AttachmentStagingError.byteCountMismatch
        }
        return path
    }

    /// What the base64 text of `byteCount` bytes takes on the wire.
    static func encodedBytes(_ byteCount: Int64) -> Int {
        Int((byteCount + 2) / 3 * 4)
    }
}

/// A file for a Composer on any Host. On a native Windows core Host, one `terminal.put`
/// carries 8 MiB, not the 64 MiB `FilePreparer` keeps for every other Host, so a file
/// past it is refused here, in those words, before any of it is copied.
struct WindowsCoreFilePreparer: FilePreparing {
    let isOnWindows: @MainActor @Sendable () -> Bool
    var preparer: any FilePreparing = FilePreparer()

    func prepare(_ sourceURL: URL) async throws -> PreparedFile {
        if await isOnWindows(), Self.isPastTheLimit(sourceURL) {
            throw AttachmentStagingError.exceedsCoreFileLimit
        }
        return try await preparer.prepare(sourceURL)
    }

    /// A size that cannot be read is the preparer's to report.
    private static func isPastTheLimit(_ url: URL) -> Bool {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) > HerdrCoreStaging.maximumBytes
    }
}
