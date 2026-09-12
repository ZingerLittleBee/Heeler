import Foundation
import Observation

/// The New Workspace remote-directory browser's model (#280): starting at
/// the remote home directory, it lists one absolute path's subdirectories at
/// a time over injected closures, so the sheet stays off the SSH types and
/// tests can script a fake lister. The Directory text field is untouched
/// until the user picks Use This Directory; a failed listing keeps the prior
/// path on screen with an error instead of clearing anything.
@MainActor
@Observable
final class RemoteDirectoryBrowser {
    typealias ResolveHome = () async throws -> String
    typealias ListDirectories = (String) async throws -> RemoteDirectoryListing

    /// The last successfully listed path; nil until the home probe answers.
    private(set) var currentPath: String?
    /// The current path's subdirectories, as the last listing reported.
    private(set) var directories: [String] = []
    /// Whether the last listing hit the server-side entry cap.
    private(set) var truncated = false
    private(set) var isLoading = false
    /// User-facing message for the last home or listing failure.
    private(set) var errorMessage: String?
    /// Narrows the current listing only; it never walks the tree.
    var filter = ""

    private let resolveHome: ResolveHome
    private let list: ListDirectories
    private var loadTask: Task<Void, Never>?

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

    /// Whether Back has a parent to return to. The filesystem root has none.
    var canGoBack: Bool {
        guard let currentPath else { return false }
        return Self.parentPath(of: currentPath) != nil
    }

    /// Resolves the remote home and loads it. A home-probe failure surfaces
    /// the error's own presentation with no path, leaving the Directory
    /// field as the fallback.
    func start() {
        load(path: nil)
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
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    /// The parent of an absolute path, or nil for the filesystem root (and
    /// for anything that is not a usable absolute path).
    static func parentPath(of path: String) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed != "/", !trimmed.isEmpty else { return nil }
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func load(path: String?) {
        loadTask?.cancel()
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
                self.currentPath = target
                self.directories = listing.directories
                self.truncated = listing.truncated
                self.errorMessage = nil
                self.isLoading = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                // The prior path and listing stay on screen; only the error
                // is new, and the Directory field is never touched here.
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
