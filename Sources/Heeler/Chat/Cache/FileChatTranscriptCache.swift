import Foundation
import OSLog

/// Chat's on-device cache: one JSON document per conversation under
/// `Caches/HeelerChatCache/v1/<host-id>/`, written with complete file
/// protection and excluded from backup.
///
/// The cache is bounded by size (least recently used first) and age, and is
/// cleared per Host when the Host is removed. A document that cannot be read
/// because the device is locked is kept; one that cannot be decoded is
/// deleted. Errors are logged by domain and code only, never with paths,
/// ids or content.
actor FileChatTranscriptCache: ChatTranscriptCache {
    static let defaultRoot = URL.cachesDirectory.appending(path: "HeelerChatCache", directoryHint: .isDirectory)

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "ChatCache")
    private static let versionDirectory = "v1"

    private let root: URL
    private let policy: ChatCachePolicy
    private let now: @Sendable () -> Date
    private var allowedHosts: Set<UUID>?
    private var knownTotalBytes: Int64?

    init(
        root: URL = FileChatTranscriptCache.defaultRoot,
        policy: ChatCachePolicy = ChatCachePolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.policy = policy
        self.now = now
    }

    private var fileManager: FileManager { .default }
    private var versionRoot: URL { root.appending(path: Self.versionDirectory, directoryHint: .isDirectory) }

    private func hostDirectory(_ hostID: UUID) -> URL {
        versionRoot.appending(path: hostID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func fileURL(_ key: ChatCacheKey) -> URL {
        hostDirectory(key.hostID).appending(path: "\(key.storageName).json", directoryHint: .notDirectory)
    }

    private func agentDirectoryURL(_ hostID: UUID) -> URL {
        hostDirectory(hostID).appending(path: "agents.json", directoryHint: .notDirectory)
    }

    // MARK: ChatTranscriptCache

    func load(_ key: ChatCacheKey) -> ChatCacheLoadResult {
        let url = fileURL(key)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .miss
        } catch {
            Self.logFailure("read", error)
            return .unavailable
        }
        guard let document = try? Self.decoder.decode(ChatCacheDocument.self, from: data),
            document.formatVersion == ChatCacheDocument.currentFormatVersion,
            document.key == key
        else {
            removeFile(url)
            return .miss
        }
        // Reading counts as use for least-recently-used pruning.
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return .hit(document)
    }

    func save(_ document: ChatCacheDocument) {
        if let allowedHosts, !allowedHosts.contains(document.key.hostID) { return }
        let url = fileURL(document.key)
        guard let data = encodeWithinBudget(document) else {
            removeFile(url)
            return
        }
        write(data, to: url, hostID: document.key.hostID)
    }

    func loadAgentDirectory(for host: Host) async -> [ChatCachedAgent] {
        let url = agentDirectoryURL(host.id)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            Self.logFailure("read", error)
            return []
        }
        guard let directory = try? Self.decoder.decode(ChatAgentDirectory.self, from: data) else {
            removeFile(url)
            return []
        }
        let entries = directory.entries(for: host)
        if !entries.isEmpty {
            try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        }
        return entries
    }

    func saveAgentDirectory(_ agents: [ChatCachedAgent], for host: Host) async {
        if let allowedHosts, !allowedHosts.contains(host.id) { return }
        let url = agentDirectoryURL(host.id)
        let directory = ChatAgentDirectory(agents, for: host)
        guard !directory.agents.isEmpty,
            let data = try? Self.encoder.encode(directory), data.count <= policy.maxDocumentBytes
        else {
            removeFile(url)
            return
        }
        write(data, to: url, hostID: host.id)
    }

    private func write(_ data: Data, to url: URL, hostID: UUID) {
        // The first save after launch measures what is already stored.
        if knownTotalBytes == nil { prune() }
        let previousSize = fileSize(url)
        do {
            try ensureDirectory(hostDirectory(hostID))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            Self.logFailure("write", error)
            removeFile(url)
            return
        }
        let total = (knownTotalBytes ?? 0) - previousSize + Int64(data.count)
        knownTotalBytes = total
        if total > policy.totalBudget { prune() }
    }

    func remove(_ key: ChatCacheKey) {
        removeFile(fileURL(key))
    }

    func retainHosts(_ hostIDs: Set<UUID>) {
        allowedHosts = hostIDs
        let keep = Set(hostIDs.map { $0.uuidString.lowercased() })
        for url in contents(of: versionRoot) where !keep.contains(url.lastPathComponent) {
            removeFile(url)
        }
        knownTotalBytes = nil
    }

    func removeAll() {
        removeFile(root)
        knownTotalBytes = 0
    }

    func diskUsage() -> Int64 {
        if let knownTotalBytes { return knownTotalBytes }
        prune()
        return knownTotalBytes ?? 0
    }

    /// Deletes leftovers outside the current version, documents past the age
    /// limit, then the least recently used until usage is under the low-water
    /// mark, and finally empty Host directories.
    func prune() {
        for url in contents(of: root) where url.lastPathComponent != Self.versionDirectory {
            removeFile(url)
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var documents: [(url: URL, size: Int64, modified: Date)] = []
        let expiry = now().addingTimeInterval(-policy.maxAge)
        for hostDirectory in contents(of: versionRoot) {
            guard UUID(uuidString: hostDirectory.lastPathComponent) != nil,
                (try? hostDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                removeFile(hostDirectory)
                continue
            }
            for url in contents(of: hostDirectory) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard url.pathExtension == "json", values?.isDirectory != true else {
                    removeFile(url)
                    continue
                }
                let modified = values?.contentModificationDate ?? .distantPast
                guard modified >= expiry else {
                    removeFile(url)
                    continue
                }
                documents.append((url, Int64(values?.fileSize ?? 0), modified))
            }
        }
        var total = documents.reduce(Int64(0)) { $0 + $1.size }
        if total > policy.totalBudget {
            for document in documents.sorted(by: { $0.modified < $1.modified }) {
                guard total > policy.lowWater else { break }
                removeFile(document.url)
                total -= document.size
            }
        }
        for hostDirectory in contents(of: versionRoot) where contents(of: hostDirectory).isEmpty {
            removeFile(hostDirectory)
        }
        knownTotalBytes = total
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// The document's bytes, keeping only its newest entries when the whole
    /// document is over the size limit. Nil when even that does not fit.
    private func encodeWithinBudget(_ document: ChatCacheDocument) -> Data? {
        guard let data = try? Self.encoder.encode(document) else { return nil }
        guard data.count > policy.maxDocumentBytes, !document.entries.isEmpty else {
            return data.count <= policy.maxDocumentBytes ? data : nil
        }
        // Entries are roughly even in size; keep the share that should fit,
        // with room for the document's other fields.
        let share = Double(policy.maxDocumentBytes) / Double(data.count) * 0.9
        let keep = max(0, Int(Double(document.entries.count) * share))
        var trimmed = document
        trimmed.entries = Array(document.entries.suffix(keep))
        trimmed.reachedStart = false
        trimmed.coverageStart = trimmed.entries.first?.sourceOffset ?? document.coverageStart
        guard let trimmedData = try? Self.encoder.encode(trimmed),
            trimmedData.count <= policy.maxDocumentBytes
        else { return nil }
        return trimmedData
    }

    private func ensureDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private func contents(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]))
            ?? []
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func removeFile(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            Self.logFailure("remove", error)
        }
        knownTotalBytes = nil
    }

    private static func logFailure(_ operation: String, _ error: any Error) {
        let error = error as NSError
        log.error(
            "Chat cache \(operation, privacy: .public) failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)"
        )
    }
}
