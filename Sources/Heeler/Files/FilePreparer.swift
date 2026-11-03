import Foundation

struct PreparedFile: Sendable, Equatable {
    let fileURL: URL
    let fileExtension: String
    let byteCount: Int64
    /// The picked file's name without its extension, cleaned for the Host, or nil
    /// when it kept no letter or digit.
    let stem: String?

    init(fileURL: URL, fileExtension: String, byteCount: Int64, pickedName: String? = nil) {
        self.fileURL = fileURL
        self.fileExtension = Self.safeExtension(fileExtension)
        self.byteCount = byteCount
        stem = pickedName.flatMap(Self.cleanStem)
    }

    /// The Host copy's name: the picked file's own, cleaned, with its safe extension.
    var remoteFilename: String {
        let stem = stem ?? "file"
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    private static let maximumStemLength = 64

    /// Device names Windows opens in any folder, whatever extension follows.
    private static let windowsDeviceNames: Set<String> = Set(
        ["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] })

    /// As herdr-core's `terminal.put` cleans a name, so both routes land the same:
    /// ASCII letters and digits, `.`, `-` and `_` kept, anything else `_`, and no
    /// leading dot. No trailing dot either, which Windows drops, and no device name.
    static func cleanStem(_ name: String) -> String? {
        let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let kept = (base as NSString).deletingPathExtension.map { character -> Character in
            let isKept = character.isASCII && (character.isLetter || character.isNumber)
            return isKept || "._-".contains(character) ? character : "_"
        }
        var stem = String(String(kept).drop { $0 == "." }.prefix(maximumStemLength))
        while stem.hasSuffix(".") { stem.removeLast() }
        guard stem.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let device = stem.prefix { $0 != "." }
        guard windowsDeviceNames.contains(device.lowercased()) else { return stem }
        return "\(device)_\(stem.dropFirst(device.count))"
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
/// and has a random local name. The picked name, cleaned, names only the Host copy.
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
                byteCount: size.int64Value,
                pickedName: sourceURL.lastPathComponent)
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
