import Foundation

struct PreparedFile: Sendable, Equatable {
    let fileURL: URL
    let fileExtension: String
    let byteCount: Int64

    init(fileURL: URL, fileExtension: String, byteCount: Int64) {
        self.fileURL = fileURL
        self.fileExtension = Self.safeExtension(fileExtension)
        self.byteCount = byteCount
    }

    var remoteFilename: String {
        fileExtension.isEmpty ? "file" : "file.\(fileExtension)"
    }

    func remove(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    static func safeExtension(_ candidate: String) -> String {
        let candidate = candidate.lowercased()
        guard !candidate.isEmpty, candidate.count <= 16 else { return "" }
        guard
            candidate.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 0x30...0x39, 0x61...0x7A:
                    true
                default:
                    false
                }
            })
        else { return "" }
        return candidate
    }
}

protocol FilePreparing: Sendable {
    func prepare(_ sourceURL: URL) async throws -> PreparedFile
}

enum FilePreparationError: Error, Sendable, Equatable {
    case selectionUnavailable
    case sourceTooLarge
    case localStorageFailed
}

/// Copies a document-picker result into protected app-owned temporary storage.
/// The private copy keeps retries independent from the provider's security scope
/// and replaces the original filename with a random local name.
actor FilePreparer: FilePreparing {
    static let maximumByteCount = 64 * 1_024 * 1_024
    static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeelerPreparedFiles", isDirectory: true)

    private let maximumByteCount: Int64
    private let directory: URL
    private let fileManager: FileManager

    init(
        maximumByteCount: Int64 = Int64(FilePreparer.maximumByteCount),
        directory: URL = FilePreparer.defaultDirectory,
        fileManager: FileManager = .default
    ) {
        self.maximumByteCount = maximumByteCount
        self.directory = directory
        self.fileManager = fileManager
    }

    func prepare(_ sourceURL: URL) async throws -> PreparedFile {
        try Task.checkCancellation()
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw FilePreparationError.selectionUnavailable
        }
        guard values.isRegularFile == true else {
            throw FilePreparationError.selectionUnavailable
        }
        if let sourceByteCount = values.fileSize,
            Int64(sourceByteCount) > maximumByteCount
        {
            throw FilePreparationError.sourceTooLarge
        }

        do {
            try Self.ensureDirectory(directory, fileManager: fileManager)
        } catch {
            throw FilePreparationError.localStorageFailed
        }
        let fileExtension = PreparedFile.safeExtension(sourceURL.pathExtension)
        let filename =
            fileExtension.isEmpty
            ? UUID().uuidString.lowercased()
            : "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let destinationURL = directory.appendingPathComponent(filename)

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try Task.checkCancellation()
            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                throw FilePreparationError.selectionUnavailable
            }
            guard size.int64Value <= maximumByteCount else {
                throw FilePreparationError.sourceTooLarge
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destinationURL.path)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = destinationURL
            try mutableURL.setResourceValues(resourceValues)
            return PreparedFile(
                fileURL: destinationURL,
                fileExtension: fileExtension,
                byteCount: size.int64Value)
        } catch let error as FilePreparationError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch is CancellationError {
            try? fileManager.removeItem(at: destinationURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw FilePreparationError.localStorageFailed
        }
    }

    static func cleanupRemnants(
        in directory: URL = defaultDirectory,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            try fileManager.removeItem(at: url)
        }
    }

    private static func ensureDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }
}
