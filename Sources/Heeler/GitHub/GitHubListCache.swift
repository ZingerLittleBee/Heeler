import Foundation
import OSLog

/// The GitHub lists a device keeps between launches, one per Host, so the
/// tab can show the last read at once (ADR 0065). Display only: nothing reads
/// it to decide what to do on GitHub.
protocol GitHubListCache: Sendable {
    func load(_ hostID: UUID) async -> GitHubList?
    func save(_ list: GitHubList, for hostID: UUID) async
    func remove(_ hostID: UUID) async
    /// Removes the lists of every Host not in `hostIDs`, and refuses later
    /// saves for them.
    func retainHosts(_ hostIDs: Set<UUID>) async
    func removeAll() async
}

/// The lists in memory only: demo mode and tests, whose Console stores live
/// in the app's own container and must not touch the real cache.
actor VolatileGitHubListCache: GitHubListCache {
    private var lists: [UUID: GitHubList] = [:]

    func load(_ hostID: UUID) -> GitHubList? { lists[hostID] }
    func save(_ list: GitHubList, for hostID: UUID) { lists[hostID] = list }
    func remove(_ hostID: UUID) { lists[hostID] = nil }
    func retainHosts(_ hostIDs: Set<UUID>) { lists = lists.filter { hostIDs.contains($0.key) } }
    func removeAll() { lists = [:] }
}

/// One JSON document per Host under `Caches/HeelerGitHubCache/v2/`, written
/// with complete file protection and excluded from backup, like Chat's
/// cache. A list older than `maxAge` is deleted rather than shown; one that
/// cannot be decoded is deleted. Errors are logged by domain and code only.
actor FileGitHubListCache: GitHubListCache {
    static let defaultRoot = URL.cachesDirectory.appending(path: "HeelerGitHubCache", directoryHint: .isDirectory)
    static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "GitHubCache")
    /// v2 holds each segment's one list and its searches' cursors; v1's
    /// four sections are deleted as leftovers.
    private static let versionDirectory = "v2"

    private let root: URL
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var allowedHosts: Set<UUID>?
    private var pruned = false

    init(
        root: URL = FileGitHubListCache.defaultRoot,
        maxAge: TimeInterval = FileGitHubListCache.defaultMaxAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.maxAge = maxAge
        self.now = now
    }

    private var fileManager: FileManager { .default }
    private var versionRoot: URL { root.appending(path: Self.versionDirectory, directoryHint: .isDirectory) }

    private func fileURL(_ hostID: UUID) -> URL {
        versionRoot.appending(path: "\(hostID.uuidString.lowercased()).json", directoryHint: .notDirectory)
    }

    func load(_ hostID: UUID) -> GitHubList? {
        if !pruned { prune() }
        let url = fileURL(hostID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            Self.logFailure("read", error)
            return nil
        }
        guard let list = try? Self.decoder.decode(GitHubList.self, from: data) else {
            removeFile(url)
            return nil
        }
        return list
    }

    func save(_ list: GitHubList, for hostID: UUID) {
        if let allowedHosts, !allowedHosts.contains(hostID) { return }
        let url = fileURL(hostID)
        do {
            let data = try Self.encoder.encode(list)
            try fileManager.createDirectory(
                at: versionRoot, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var directory = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var file = url
            try file.setResourceValues(values)
        } catch {
            Self.logFailure("write", error)
            removeFile(url)
        }
    }

    func remove(_ hostID: UUID) {
        removeFile(fileURL(hostID))
    }

    func retainHosts(_ hostIDs: Set<UUID>) {
        allowedHosts = hostIDs
        let keep = Set(hostIDs.map { "\($0.uuidString.lowercased()).json" })
        for url in contents(of: versionRoot) where !keep.contains(url.lastPathComponent) {
            removeFile(url)
        }
    }

    func removeAll() {
        removeFile(root)
    }

    /// Deletes leftovers outside the current version and lists past the age
    /// limit.
    private func prune() {
        pruned = true
        for url in contents(of: root) where url.lastPathComponent != Self.versionDirectory {
            removeFile(url)
        }
        let expiry = now().addingTimeInterval(-maxAge)
        for url in contents(of: versionRoot) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if url.pathExtension != "json" || (modified ?? .distantPast) < expiry {
                removeFile(url)
            }
        }
    }

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

    private func contents(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    }

    private func removeFile(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            Self.logFailure("remove", error)
        }
    }

    private static func logFailure(_ operation: String, _ error: any Error) {
        let error = error as NSError
        log.error(
            "GitHub cache \(operation, privacy: .public) failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)"
        )
    }
}
