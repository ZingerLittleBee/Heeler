import CryptoKit
import Foundation
import OSLog

/// Whole Host files kept on this device once Files or a Chat preview has
/// read them, so opening one again does not download it again (ADR 0059).
///
/// A copy lives at `Caches/HostFiles/v1/<host-id>/<path-digest>/<size>-<mtime>/<name>`:
/// a folder a Host, so removing the Host removes its copies; one a path,
/// which keeps only the newest version of its file; and the file's own name,
/// which is what a share shows. A copy is found by the size and modification
/// time the Host reports, so a file written again downloads again, and a file
/// whose Host reports no modification time is never kept.
///
/// Copies are bounded by age since last opened and by total size (least
/// recently opened first), cannot be opened while the device is locked, and
/// are excluded from backup. Errors are logged by domain and code only, never
/// with paths or content.
actor HostFileCache: DeviceCache {
    struct Key: Hashable, Sendable {
        let hostID: UUID
        let path: String
        let size: UInt64
        let modificationTime: UInt32

        /// Nil when the Host reported no modification time: a file written
        /// again at the same length would then read as the kept one.
        init?(hostID: UUID, path: String, size: UInt64, modificationTime: UInt32?) {
            guard let modificationTime else { return nil }
            self.hostID = hostID
            self.path = path
            self.size = size
            self.modificationTime = modificationTime
        }

        fileprivate var pathFolderName: String {
            SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        fileprivate var versionFolderName: String { "\(size)-\(modificationTime)" }
    }

    struct Policy: Equatable, Sendable {
        /// Decimal bytes, as Settings formats them.
        var totalBudget: Int64 = 500_000_000
        /// Pruning stops once usage falls to this.
        var lowWater: Int64 = 450_000_000
        /// A copy not opened for this long goes.
        var maxAge: TimeInterval = 7 * 86_400
    }

    static let defaultRoot = URL.cachesDirectory.appending(path: "HostFiles", directoryHint: .isDirectory)

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "HostFileCache")
    private static let versionDirectory = "v1"
    private static let downloadsDirectory = "Downloads"
    private static let protection = FileProtectionType.completeUnlessOpen

    private let root: URL
    private let policy: Policy
    private let now: @Sendable () -> Date
    /// Downloads older than this were left by an earlier run.
    private let started: Date
    private var allowedHosts: Set<UUID>?
    private var knownTotalBytes: Int64?
    private var removedLegacyCopies = false

    init(
        root: URL = HostFileCache.defaultRoot,
        policy: Policy = Policy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.policy = policy
        self.now = now
        // The file system's clock, which dates the downloads' folders.
        started = Date()
    }

    private var fileManager: FileManager { .default }
    private var versionRoot: URL { root.appending(path: Self.versionDirectory, directoryHint: .isDirectory) }
    private var downloadsRoot: URL { root.appending(path: Self.downloadsDirectory, directoryHint: .isDirectory) }

    private func versionFolder(_ key: Key) -> URL {
        versionRoot
            .appending(path: key.hostID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: key.pathFolderName, directoryHint: .isDirectory)
            .appending(path: key.versionFolderName, directoryHint: .isDirectory)
    }

    // MARK: Copies

    /// The kept copy of `key`'s file, now counted as just opened; nil when
    /// none is kept.
    func file(for key: Key) -> URL? {
        guard isAllowed(key.hostID), let file = onlyFile(in: versionFolder(key)) else { return nil }
        markOpened(file)
        return file
    }

    /// Where to download a file called `name`. It is the caller's until
    /// `keep` takes it or `discard` removes it.
    func newDownload(named name: String) throws -> URL {
        let folder = downloadsRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try ensureDirectory(folder)
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    /// A finished download becomes `key`'s copy, in place of any older
    /// version of the same path. Returns where the copy is, which may be
    /// another download's that finished first; nil when it could not be
    /// kept, and the download is then still the caller's.
    func keep(_ download: URL, for key: Key) -> URL? {
        guard isAllowed(key.hostID) else { return nil }
        let version = versionFolder(key)
        if let kept = onlyFile(in: version) {
            discard(download)
            markOpened(kept)
            return kept
        }
        let pathFolder = version.deletingLastPathComponent()
        for older in contents(of: pathFolder) {
            removeItem(older)
        }
        let destination = version.appending(path: download.lastPathComponent, directoryHint: .notDirectory)
        do {
            try ensureDirectory(version)
            try fileManager.moveItem(at: download, to: destination)
        } catch {
            Self.logFailure("keep", error)
            removeItem(version)
            return nil
        }
        discard(download)
        markOpened(destination)
        prune()
        return destination
    }

    /// `data` as `key`'s copy, named `name`; nil when it could not be kept.
    func keep(_ data: Data, named name: String, for key: Key) -> URL? {
        guard isAllowed(key.hostID), let download = try? newDownload(named: name) else { return nil }
        do {
            try data.write(to: download, options: .completeFileProtectionUnlessOpen)
        } catch {
            Self.logFailure("write", error)
            discard(download)
            return nil
        }
        guard let kept = keep(download, for: key) else {
            discard(download)
            return nil
        }
        return kept
    }

    /// A download `keep` did not take, with its folder.
    func discard(_ download: URL) {
        let folder = download.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == downloadsRoot.standardizedFileURL else {
            return
        }
        removeItem(folder)
    }

    // MARK: Retention

    /// The Hosts still in the catalog: every other Host's copies go, now
    /// and when one of its downloads finishes later.
    func retainHosts(_ hostIDs: Set<UUID>) {
        allowedHosts = hostIDs
        prune()
    }

    func removeAll() {
        removeItem(versionRoot)
        knownTotalBytes = 0
    }

    func diskUsage() -> Int64 {
        if let knownTotalBytes { return knownTotalBytes }
        prune()
        return knownTotalBytes ?? 0
    }

    /// Removes what an earlier run left: unknown entries, unfinished
    /// downloads and Files' old temporary copies. Then copies of Hosts no
    /// longer listed, copies past the age limit, and the least recently
    /// opened until usage is under the low-water mark.
    func prune() {
        removeLegacyCopiesOnce()
        for url in contents(of: root)
        where ![Self.versionDirectory, Self.downloadsDirectory].contains(url.lastPathComponent) {
            removeItem(url)
        }
        for folder in contents(of: downloadsRoot) {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if created.map({ $0 < started }) ?? true { removeItem(folder) }
        }
        let expiry = now().addingTimeInterval(-policy.maxAge)
        var copies: [(version: URL, size: Int64, opened: Date)] = []
        for host in contents(of: versionRoot) {
            guard let hostID = UUID(uuidString: host.lastPathComponent), isAllowed(hostID), isDirectory(host)
            else {
                removeItem(host)
                continue
            }
            for pathFolder in contents(of: host) {
                for version in contents(of: pathFolder) {
                    let values = onlyFile(in: version).flatMap {
                        try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    }
                    guard let values, let opened = values.contentModificationDate, opened >= expiry else {
                        removeItem(version)
                        continue
                    }
                    copies.append((version, Int64(values.fileSize ?? 0), opened))
                }
            }
        }
        var total = copies.reduce(Int64(0)) { $0 + $1.size }
        if total > policy.totalBudget {
            for copy in copies.sorted(by: { $0.opened < $1.opened }) {
                guard total > policy.lowWater else { break }
                removeItem(copy.version)
                total -= copy.size
            }
        }
        removeEmptyFolders()
        knownTotalBytes = total
    }

    // MARK: Helpers

    private func isAllowed(_ hostID: UUID) -> Bool {
        allowedHosts?.contains(hostID) ?? true
    }

    /// The one file a version folder holds.
    private func onlyFile(in folder: URL) -> URL? {
        contents(of: folder).first { !isDirectory($0) }
    }

    /// A copy's modification date is when it was last opened, which is
    /// what the age limit and the size budget go by.
    private func markOpened(_ file: URL) {
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
    }

    /// Files' copies from before this cache, which a crash could leave in
    /// the temporary folder.
    private func removeLegacyCopiesOnce() {
        guard !removedLegacyCopies else { return }
        removedLegacyCopies = true
        removeItem(fileManager.temporaryDirectory.appending(path: "HostFiles", directoryHint: .isDirectory))
    }

    private func removeEmptyFolders() {
        for host in contents(of: versionRoot) {
            for pathFolder in contents(of: host) where contents(of: pathFolder).isEmpty {
                removeItem(pathFolder)
            }
            if contents(of: host).isEmpty { removeItem(host) }
        }
    }

    private func ensureDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func contents(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]))
            ?? []
    }

    private func removeItem(_ url: URL) {
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
            "Host file cache \(operation, privacy: .public) failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)"
        )
    }
}
