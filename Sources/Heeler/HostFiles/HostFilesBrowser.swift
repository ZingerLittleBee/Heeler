import Foundation
import Observation

/// One name in a listed Host folder, as Files shows it.
struct HostFileEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    /// What the listing reported, which does not follow a link.
    let kind: RemoteFileKind?
    let size: UInt64?
    let modified: Date?

    var id: String { name }
    var isHidden: Bool { name.hasPrefix(".") }

    init(_ entry: RemoteFileEntry, in directory: String) {
        name = entry.name
        path = RemoteFilePath.join(directory, entry.name)
        kind = entry.status.kind
        size = entry.status.size
        modified = entry.status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// The order of a folder's rows. Kept for every Host, as Show Hidden Files is.
enum HostFileSort: String, CaseIterable, Sendable {
    case name
    case modified
    case size

    static let defaultsKey = "host-files.sort"
    static let showsHiddenKey = "host-files.shows-hidden"

    func sorted(_ entries: [HostFileEntry]) -> [HostFileEntry] {
        entries.sorted { first, second in
            switch self {
            case .name:
                // Folders first, as a file manager lists them.
                let firstIsFolder = first.kind == .directory
                if firstIsFolder != (second.kind == .directory) { return firstIsFolder }
            case .modified:
                // Newest first, folders among the files: what was just
                // written leads, whichever it is.
                if first.modified != second.modified {
                    return (first.modified ?? .distantPast) > (second.modified ?? .distantPast)
                }
            case .size:
                // A folder's size is its own record's, so folders follow.
                let firstIsFolder = first.kind == .directory
                if firstIsFolder != (second.kind == .directory) { return !firstIsFolder }
                if !firstIsFolder, first.size != second.size {
                    return (first.size ?? 0) > (second.size ?? 0)
                }
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}

/// Why a folder or a file could not be read.
enum HostFilesFailure: Equatable, Sendable {
    /// The Host's SSH server offers no SFTP.
    case unavailable
    case missing
    case denied
    case other(String)

    /// SFTP's own status codes.
    private static let noSuchFile: UInt64 = 2
    private static let permissionDenied: UInt64 = 3

    init(_ error: any Error) {
        switch error {
        case TransportError.hostFeatureUnavailable:
            self = .unavailable
        case TransportError.hostFileUnreadable(Self.noSuchFile):
            self = .missing
        case TransportError.hostFileUnreadable(Self.permissionDenied):
            self = .denied
        case TransportError.hostFileUnreadable(let status):
            self = .other(String(localized: "The Host refused the read (SFTP status \(status))."))
        case TransportError.hostFileTimedOut, TransportError.timedOut:
            self = .other(String(localized: "The Host did not answer in time."))
        case TransportError.channelFailed:
            // The detail names the transport's own failure, which says
            // nothing to someone reading a file.
            self = .other(String(localized: "The connection to the Host dropped."))
        case let error as TransportError:
            self = .other(error.presentation.message)
        default:
            self = .other(error.localizedDescription)
        }
    }

    /// The failure in one sentence, for a file.
    var fileMessage: String {
        switch self {
        case .unavailable: String(localized: "This Host's SSH server offers no SFTP, which Files reads through.")
        case .missing: String(localized: "This file is no longer on the Host.")
        case .denied: String(localized: "The Host's account is not allowed to read this file.")
        case .other(let message): message
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case TransportError.cancelled = error { return true }
        return false
    }
}

/// One Host folder's listing. Read once when its page first shows, again
/// when asked, by a pull or a button, and once more when the Host's
/// connection returns under a listing. A failed read is never repeated on
/// its own, because on a Host without SFTP each attempt costs the Host's
/// connection (#596).
@MainActor
@Observable
final class HostFolder {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(HostFilesFailure)
    }

    /// What one listing asks for, the most SFTP's reader gives.
    static let maximumEntries = 1_000
    static let maximumScanned = 20_000

    let path: String
    private(set) var phase = Phase.idle
    private(set) var entries: [HostFileEntry] = []
    /// The folder holds more than was listed.
    private(set) var isPartial = false
    /// Narrows this listing only; it never searches below it.
    var filter = ""

    @ObservationIgnored private let files: ChatHostFiles
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ordered: [HostFileSort: [HostFileEntry]] = [:]
    /// The listing showing has not been read again by a reconnect yet.
    @ObservationIgnored private var rereadsOnReconnect = false

    init(path: String, files: ChatHostFiles) {
        self.path = path
        self.files = files
    }

    var name: String {
        path == "/" ? "/" : RemoteHostPath.lastComponent(of: path)
    }

    var hiddenCount: Int {
        entries.count(where: \.isHidden)
    }

    func rows(sortedBy sort: HostFileSort, showingHidden: Bool) -> [HostFileEntry] {
        let all: [HostFileEntry]
        if let cached = ordered[sort] {
            all = cached
        } else {
            all = sort.sorted(entries)
            ordered[sort] = all
        }
        return all.filter { entry in
            (showingHidden || !entry.isHidden)
                && (filter.isEmpty || entry.name.localizedCaseInsensitiveContains(filter))
        }
    }

    /// The page showed. Only the first time reads.
    func loadIfNeeded() {
        guard phase == .idle else { return }
        reload()
    }

    /// Try Again.
    func reload() {
        phase = .loading
        startReading()
    }

    /// Check Again, on a Host whose SSH server refused SFTP: this read asks
    /// the Host, which costs its connection if it refuses once more (#596).
    func checkAgain() {
        files.retrySFTP()
        reload()
    }

    /// A pull, which keeps the rows it is pulling until the answer lands.
    func refresh() async {
        await startReading().value
    }

    /// The Host's connection came back under this page. A page that never
    /// read reads now. One showing its listing reads it again, and only a
    /// listing that lands earns the next: a read that fails here, or takes
    /// the connection down with it, is not what the following reconnect
    /// repeats. A failed page waits to be asked, as it always does.
    func hostReconnected() {
        switch phase {
        case .idle:
            reload()
        case .loaded where rereadsOnReconnect:
            rereadsOnReconnect = false
            startReading()
        default:
            break
        }
    }

    @discardableResult
    private func startReading() -> Task<Void, Never> {
        task?.cancel()
        let reading = Task { [weak self] in
            guard let self else { return }
            await self.read()
        }
        task = reading
        return reading
    }

    private func read() async {
        do {
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: path,
                    maximumEntries: Self.maximumEntries,
                    maximumScanned: Self.maximumScanned))
            guard !Task.isCancelled else { return }
            guard let listing else {
                show([], isPartial: false, phase: .failed(.missing))
                return
            }
            show(
                listing.entries.map { HostFileEntry($0, in: path) },
                isPartial: listing.truncated || listing.scanIncomplete,
                phase: .loaded)
        } catch {
            guard !Task.isCancelled, !HostFilesFailure.isCancellation(error) else { return }
            show([], isPartial: false, phase: .failed(HostFilesFailure(error)))
        }
    }

    private func show(_ entries: [HostFileEntry], isPartial: Bool, phase: Phase) {
        ordered = [:]
        self.entries = entries
        self.isPartial = isPartial
        self.phase = phase
        rereadsOnReconnect = phase == .loaded
    }
}

/// Files, open over an Agent: a read-only look at one Host's folders, from
/// the Agent's directory. It lives as long as its sheet does; the copies its
/// previews made stay in `HostFileCache`.
@MainActor
@Observable
final class HostFilesBrowser: Identifiable {
    struct Route: Hashable, Sendable {
        let directory: String
    }

    /// Where Files opened, and where Agent Directory returns.
    let agentDirectory: String
    /// The folders pushed over `/`, one page each, so Back is the parent.
    var path: [Route]
    private(set) var preview: HostFilePreview?
    /// A link being followed, by path.
    private(set) var following: String?
    /// Why a row did not open, or a folder could not be reached.
    var notice: String?
    /// The Host's connection is up. While it is not, a page keeps what it
    /// read and opens nothing. Kept here, not in a view: a pull's action
    /// goes on holding the view it was first given.
    private(set) var isHostConnected: Bool

    @ObservationIgnored let files: ChatHostFiles
    @ObservationIgnored private var folders: [String: HostFolder] = [:]
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private let hostID: Host.ID
    /// The terminal id of the Agent Files opened from.
    @ObservationIgnored private let opener: String
    @ObservationIgnored private let cache: HostFileCache
    /// How much of a file one request asks for, as this Host's link taught.
    @ObservationIgnored private let pace = HostFilePace()

    init(
        files: ChatHostFiles, hostID: Host.ID, openedBy opener: String, cache: HostFileCache,
        agentDirectory: String, isHostConnected: Bool
    ) {
        self.files = files.finishingEachRequest
        self.hostID = hostID
        self.opener = opener
        self.cache = cache
        self.isHostConnected = isHostConnected
        self.agentDirectory = Self.normalized(agentDirectory)
        path = Self.routes(to: agentDirectory)
    }

    var currentDirectory: String {
        path.last?.directory ?? "/"
    }

    func folder(at directory: String) -> HostFolder {
        if let folder = folders[directory] { return folder }
        let folder = HostFolder(path: directory, files: files)
        folders[directory] = folder
        return folder
    }

    /// A row was tapped. A link is followed first: the listing says only
    /// that it is one.
    func open(_ entry: HostFileEntry) {
        switch entry.kind {
        case .directory:
            path.append(Route(directory: entry.path))
        case .regular:
            show(entry.path, name: entry.name, size: entry.size, modified: entry.modified)
        default:
            follow(entry)
        }
    }

    func closePreview() {
        preview?.discard()
        preview = nil
    }

    /// Files closed, whether or not a preview was still open.
    func close() {
        followTask?.cancel()
        closePreview()
    }

    /// The Host's connection went, or came back. When it returns the folder
    /// showing is read again; the pages under it keep what they have until
    /// they are pulled.
    func hostConnectionChanged(_ isConnected: Bool) {
        guard isConnected != isHostConnected else { return }
        isHostConnected = isConnected
        guard isConnected else { return }
        pace.reset()
        folder(at: currentDirectory).hostReconnected()
    }

    func go(to directory: String) {
        followTask?.cancel()
        following = nil
        path = Self.routes(to: directory)
    }

    func goHome() {
        run { browser in
            let home = try await browser.files.home()
            guard RemoteFilePath.isAcceptable(home) else {
                throw TransportError.invalidDirectoryPath(path: home)
            }
            browser.path = Self.routes(to: home)
        }
    }

    /// Go to Folder: an absolute path, one under the home directory written
    /// with `~`, or one from the folder showing. A file's path opens the
    /// file in its folder, so a path an Agent printed can be pasted whole.
    func go(toTyped text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let showing = currentDirectory
        run { browser in
            let target: String
            if typed == "~" || typed.hasPrefix("~/") {
                target = RemoteFilePath.join(try await browser.files.home(), String(typed.dropFirst(2)))
            } else {
                target = typed.hasPrefix("/") ? typed : RemoteFilePath.join(showing, typed)
            }
            let routes = Self.routes(to: Self.resolved(target))
            guard let last = routes.last, RemoteFilePath.isAcceptable(last.directory) else {
                if routes.isEmpty {
                    browser.path = []
                } else {
                    browser.notice = String(localized: "Files can't open this path.")
                }
                return
            }
            do {
                if let status = try await browser.files.status(last.directory), status.kind == .regular {
                    browser.path = Array(routes.dropLast())
                    browser.show(
                        last.directory, name: RemoteHostPath.lastComponent(of: last.directory),
                        size: status.size,
                        modified: status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                    return
                }
            } catch where HostFilesFailure(error) == .denied {
                // The folder's own page says so.
            }
            browser.path = routes
        }
    }

    /// The path a message names this file by: from the Agent's directory
    /// when the file is under it, as the Agent would write it.
    func reference(to filePath: String) -> String {
        Self.reference(to: filePath, from: agentDirectory)
    }

    static func reference(to filePath: String, from agentDirectory: String) -> String {
        let prefix = agentDirectory == "/" ? "/" : agentDirectory + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : filePath
    }

    static func routes(to directory: String) -> [Route] {
        var routes: [Route] = []
        var current = ""
        for component in directory.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            routes.append(Route(directory: current))
        }
        return routes
    }

    private static func normalized(_ directory: String) -> String {
        routes(to: directory).last?.directory ?? "/"
    }

    /// A path with its `.` and `..` worked out by name, as a shell's `cd`
    /// does.
    private static func resolved(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private func show(_ path: String, name: String, size: UInt64?, modified: Date?) {
        preview?.discard()
        preview = HostFilePreview(
            path: path, name: name, size: size, modified: modified, files: files, hostID: hostID,
            openedBy: opener, cache: cache, pace: pace)
    }

    private func follow(_ entry: HostFileEntry) {
        let parent = currentDirectory
        followTask?.cancel()
        following = entry.path
        followTask = Task { [weak self] in
            guard let self else { return }
            let files = self.files
            do {
                let status = try await files.status(entry.path)
                guard !Task.isCancelled, self.currentDirectory == parent else { return }
                self.following = nil
                switch status?.kind {
                case .directory:
                    self.path.append(Route(directory: entry.path))
                case .regular:
                    self.show(
                        entry.path, name: entry.name, size: status?.size,
                        modified: status?.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                default:
                    self.notice = status == nil
                        ? String(localized: "“\(entry.name)” points to something that is no longer on the Host.")
                        : String(localized: "Files can't open “\(entry.name)”. It is not a file or a folder.")
                }
            } catch {
                guard !Task.isCancelled, !HostFilesFailure.isCancellation(error) else { return }
                self.following = nil
                self.notice = HostFilesFailure(error).fileMessage
            }
        }
    }

    private func run(_ work: @escaping @MainActor (HostFilesBrowser) async throws -> Void) {
        followTask?.cancel()
        following = nil
        followTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                guard !Task.isCancelled, !HostFilesFailure.isCancellation(error) else { return }
                self.notice = HostFilesFailure(error).fileMessage
            }
        }
    }
}

extension ChatHostFiles {
    /// These reads with every request finished once it is asked, for Files,
    /// which cancels often: a download's Cancel, a preview closed while it
    /// loads. A request dropped before the Host answers leaves its answer on
    /// the Host's shared SFTP channel, and the next request of its kind takes
    /// it, so one file's size showed for another. A cancelled Files task
    /// therefore stops between requests, never inside one.
    var finishingEachRequest: ChatHostFiles {
        ChatHostFiles(
            status: { path in try await Self.finished { try await status(path) } },
            list: { request in try await Self.finished { try await list(request) } },
            read: { range in try await Self.finished { try await read(range) } },
            home: { try await Self.finished { try await home() } },
            retrySFTP: retrySFTP)
    }

    private static func finished<Value: Sendable>(
        _ request: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        // A task of its own, which the asker's cancellation does not reach.
        let value = try await Task { try await request() }.value
        try Task.checkCancellation()
        return value
    }
}
