import Foundation
import Observation

/// The New Workspace remote-directory browser's model (#280): starting at
/// the remote home directory, it lists one absolute path's subdirectories at
/// a time over injected closures, so the sheet stays off the SSH types and
/// tests can script a fake lister. Selecting a folder updates the Workspace
/// draft; a failed listing keeps the prior path and filter on screen.
@MainActor
@Observable
final class RemoteDirectoryBrowser: Identifiable {
    typealias ResolveHome = () async throws -> String
    typealias ListDirectories = (String) async throws -> RemoteDirectoryListing

    /// The last successfully listed path; nil until the home probe answers.
    private(set) var currentPath: String?
    /// The current path's subdirectories, as the last listing reported.
    private(set) var directories: [String] = []
    /// The names in `directories` that are symbolic links.
    private(set) var symbolicLinks: Set<String> = []
    /// Whether the last listing hit the server-side entry cap.
    private(set) var truncated = false
    private(set) var isLoading = false
    /// User-facing message for the last home or listing failure.
    private(set) var errorMessage: String?
    /// Why the owner turned down the folder it was offered, shown in place
    /// until the browser moves to another folder.
    var refusal: String?
    /// Narrows the current listing only; it never walks the tree.
    var filter = ""

    private let resolveHome: ResolveHome
    private let list: ListDirectories
    private var loadTask: Task<Void, Never>?
    private var requestedPath: String?

    init(resolveHome: @escaping ResolveHome, list: @escaping ListDirectories) {
        self.resolveHome = resolveHome
        self.list = list
    }

    /// The current listing narrowed by the filter, in server order.
    var visibleDirectories: [String] {
        guard !filter.isEmpty else { return directories }
        return directories.filter {
            $0.localizedCaseInsensitiveContains(filter)
        }
    }

    /// Whether a listed name is a symbolic link to a directory.
    func isSymbolicLink(_ name: String) -> Bool {
        symbolicLinks.contains(name)
    }

    /// Whether Back has a parent to return to. The filesystem root has none.
    var canGoBack: Bool {
        guard let currentPath else { return false }
        return Self.parentPath(of: currentPath) != nil
    }

    /// Resolves the remote home and loads it.
    func start() {
        load(path: nil)
    }

    /// Retries the failed destination instead of sending the user home.
    func retry() {
        load(path: requestedPath)
    }

    /// Enters one of the current listing's subdirectories.
    func enter(_ name: String) {
        guard let currentPath else { return }
        load(path: Self.childPath(currentPath, name: name))
    }

    /// Returns to the current path's parent.
    func goBack() {
        guard let currentPath, let parent = Self.parentPath(of: currentPath) else { return }
        load(path: parent)
    }

    /// Cancels the in-flight home probe or listing. The owner calls this on
    /// navigate-away and on dismiss so a late answer never lands on a stale
    /// path.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    /// The child path for entering `name` under `parent`.
    static func childPath(_ parent: String, name: String) -> String {
        RemoteHostPath.childPath(parent, name: name)
    }

    /// The parent of an absolute path, or nil for the filesystem root (and
    /// for anything that is not a usable absolute path).
    static func parentPath(of path: String) -> String? {
        RemoteHostPath.parentPath(of: path)
    }

    private func load(path: String?) {
        loadTask?.cancel()
        requestedPath = path
        errorMessage = nil
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let target: String
                if let path {
                    target = path
                } else {
                    target = try await self.resolveHome()
                    try Task.checkCancellation()
                }
                let listing = try await self.list(target)
                try Task.checkCancellation()
                guard !Task.isCancelled else { return }
                if self.currentPath != target {
                    self.filter = ""
                    self.refusal = nil
                }
                self.currentPath = target
                self.directories = listing.directories
                self.symbolicLinks = listing.symbolicLinks
                self.truncated = listing.truncated
                self.errorMessage = nil
                self.isLoading = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                // Keep the prior path, listing and filter until navigation succeeds.
                self.errorMessage = Self.message(for: error)
                self.isLoading = false
            }
        }
    }

    private static func message(for error: any Error) -> String {
        if let transportError = error as? TransportError {
            return transportError.presentation.message
        }
        return "Loading directories failed: \(error)"
    }
}

extension RemoteDirectoryListing {
    /// Links one listing follows; past them it reads as truncated.
    static let maximumFollowedLinks = 100

    /// One POSIX Host directory's subdirectories and the symbolic links in
    /// it that resolve to a directory, sorted by name, over the Host file
    /// reads. For a folder a program reads by the path it is given, such as
    /// a Claude Code Account, a link is as good a choice as a directory. A
    /// link that is broken or cannot be followed is left out.
    static func followingLinks(at path: String, over transport: any Transport) async throws -> Self {
        let request = RemoteFileListingRequest(directory: path, kinds: [.directory, .symlink])
        guard let listing = try await transport.listFiles(request) else {
            throw TransportError.invalidDirectoryPath(path: path)
        }
        var directories: [String] = []
        var links: Set<String> = []
        var truncated = listing.truncated || listing.scanIncomplete
        var followed = 0
        for entry in listing.entries {
            try Task.checkCancellation()
            switch entry.status.kind {
            case .directory:
                directories.append(entry.name)
            case .symlink:
                guard followed < maximumFollowedLinks else {
                    truncated = true
                    continue
                }
                followed += 1
                let target = try? await transport.fileStatus(
                    atPath: RemoteHostPath.childPath(path, name: entry.name))
                guard target?.kind == .directory else { continue }
                directories.append(entry.name)
                links.insert(entry.name)
            default:
                continue
            }
        }
        return Self(directories: directories, truncated: truncated, symbolicLinks: links)
    }
}
