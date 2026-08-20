import Foundation
import Observation

/// How the Files feature reaches a Host's Transport. Each closure is late-bound
/// by the caller, so a Host edit replaces the live connection without leaving a
/// browser tied to the old session.
struct RemoteFileAccess: Sendable {
    var listDirectory: @Sendable (String) async throws -> [RemoteFileEntry]
    var readFile: @Sendable (String, Int) async throws -> RemoteFileSnapshot
    var writeFile: @Sendable (String, Data) async throws -> RemoteFileEntry
    var statFile: @Sendable (String) async throws -> RemoteFileEntry?

    init(
        listDirectory: @escaping @Sendable (String) async throws -> [RemoteFileEntry],
        readFile: @escaping @Sendable (String, Int) async throws -> RemoteFileSnapshot,
        writeFile: @escaping @Sendable (String, Data) async throws -> RemoteFileEntry,
        statFile: @escaping @Sendable (String) async throws -> RemoteFileEntry?
    ) {
        self.listDirectory = listDirectory
        self.readFile = readFile
        self.writeFile = writeFile
        self.statFile = statFile
    }
}

/// Owns the cached directory tree for one remote project. A directory keeps its
/// first listing until the user explicitly refreshes it, which avoids spending a
/// finite SSH channel on every disclosure redraw.
@MainActor
@Observable
final class ProjectFilesStore {
    enum NodeState: Sendable, Equatable {
        case unloaded
        case loading
        case loaded
        case failed(message: String)
    }

    struct Node: Identifiable, Sendable, Equatable {
        let entry: RemoteFileEntry
        var state: NodeState
        var children: [Node]

        var id: String { entry.path }
    }

    let root: String
    let hostName: String
    var onOpenFile: (@MainActor @Sendable (String) -> Void)?
    var showsHiddenFiles = false
    private(set) var rootNode: Node
    private(set) var selectedFilePath: String?

    @ObservationIgnored private let access: RemoteFileAccess
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestIDs: [String: UInt64] = [:]
    @ObservationIgnored private var expandedDirectoryPaths: Set<String> = []

    init(root: String, hostName: String, access: RemoteFileAccess) {
        self.root = root
        self.hostName = hostName
        self.access = access
        rootNode = Node(
            entry: RemoteFileEntry(
                name: Self.rootName(for: root),
                path: root,
                kind: .directory,
                sizeBytes: nil,
                modified: nil),
            state: .unloaded,
            children: [])
    }

    deinit {
        for request in requests.values {
            request.cancel()
        }
    }

    /// Loads the root only when it has not already been fetched. The browser
    /// calls this from its first appearance rather than from initialization so
    /// constructing a destination cannot begin I/O before it is presented.
    func load() async {
        expandedDirectoryPaths.insert(root)
        await loadDirectory(at: root, force: false)
    }

    /// Opens a disclosure and starts its one cached listing. Collapsing does
    /// not discard children: reopening should be instant and channel-free.
    func setDirectoryExpanded(_ path: String, isExpanded: Bool) async {
        guard node(at: path)?.entry.kind == .directory else { return }
        if isExpanded {
            expandedDirectoryPaths.insert(path)
            await loadDirectory(at: path, force: false)
        } else if path != root {
            let descendantPrefix = path + "/"
            expandedDirectoryPaths = expandedDirectoryPaths.filter {
                $0 != path && !$0.hasPrefix(descendantPrefix)
            }
        }
    }

    func isDirectoryExpanded(_ path: String) -> Bool {
        path == root || expandedDirectoryPaths.contains(path)
    }

    /// Re-fetches only visible directory branches. Collapsed branches retain
    /// their cached results until opened again, keeping a refresh bounded.
    func refresh() async {
        let paths = [root] + expandedDirectoryPaths
            .filter { $0 != root }
            .sorted()
        for path in paths {
            await loadDirectory(at: path, force: true)
        }
    }

    func retryDirectory(at path: String) async {
        await loadDirectory(at: path, force: true)
    }

    func visibleChildren(of path: String) -> [Node] {
        guard let node = node(at: path) else { return [] }
        guard showsHiddenFiles else {
            return node.children.filter { !$0.entry.name.hasPrefix(".") }
        }
        return node.children
    }

    func openFile(at path: String) {
        guard node(at: path)?.entry.kind != .directory else { return }
        selectedFilePath = path
        onOpenFile?(path)
    }

    func node(at path: String) -> Node? {
        Self.node(at: path, in: rootNode)
    }

    private func loadDirectory(at path: String, force: Bool) async {
        guard node(at: path)?.entry.kind == .directory else { return }
        if let request = requests[path] {
            await request.value
            if !force { return }
        } else if !force, node(at: path)?.state == .loaded {
            return
        }

        requestIDs[path, default: 0] &+= 1
        let requestID = requestIDs[path] ?? 0
        updateNode(at: path) { $0.state = .loading }
        let access = access
        let request = Task { [weak self, access] in
            do {
                let entries = try await access.listDirectory(path)
                try Task.checkCancellation()
                self?.finishDirectoryLoad(entries, at: path, requestID: requestID)
            } catch is CancellationError {
                self?.finishDirectoryCancellation(at: path, requestID: requestID)
            } catch {
                self?.finishDirectoryFailure(error, at: path, requestID: requestID)
            }
        }
        requests[path] = request
        await request.value
    }

    private func finishDirectoryLoad(
        _ entries: [RemoteFileEntry], at path: String, requestID: UInt64
    ) {
        guard requestIDs[path] == requestID else { return }
        updateNode(at: path) {
            let previousChildren = $0.children
            let incomingDirectoryPaths = Set(
                entries.lazy.compactMap { $0.kind == .directory ? $0.path : nil })
            for child in previousChildren
                where child.entry.kind == .directory
                    && !incomingDirectoryPaths.contains(child.entry.path)
            {
                let descendantPrefix = child.entry.path + "/"
                expandedDirectoryPaths = expandedDirectoryPaths.filter {
                    $0 != child.entry.path && !$0.hasPrefix(descendantPrefix)
                }
            }

            var cachedChildren: [String: Node] = [:]
            for child in previousChildren {
                cachedChildren[child.entry.path] = child
            }
            $0.state = .loaded
            // Transport owns ordering: preserving it avoids a second sort with
            // subtly different locale rules from the remote server. A root
            // refresh replaces metadata, not a collapsed child's cached tree.
            $0.children = entries.map { entry in
                guard let cached = cachedChildren[entry.path], cached.entry.kind == entry.kind else {
                    return Node(
                        entry: entry,
                        state: entry.kind == .directory ? .unloaded : .loaded,
                        children: [])
                }
                return Node(entry: entry, state: cached.state, children: cached.children)
            }
        }
        requests[path] = nil
    }

    private func finishDirectoryCancellation(at path: String, requestID: UInt64) {
        guard requestIDs[path] == requestID else { return }
        updateNode(at: path) { $0.state = .unloaded }
        requests[path] = nil
    }

    private func finishDirectoryFailure(
        _ error: Error, at path: String, requestID: UInt64
    ) {
        guard requestIDs[path] == requestID else { return }
        updateNode(at: path) { $0.state = .failed(message: Self.message(for: error)) }
        requests[path] = nil
    }

    private func updateNode(at path: String, _ update: (inout Node) -> Void) {
        _ = Self.updateNode(at: path, in: &rootNode, update)
    }

    private static func updateNode(
        at path: String, in node: inout Node, _ update: (inout Node) -> Void
    ) -> Bool {
        if node.entry.path == path {
            update(&node)
            return true
        }
        for index in node.children.indices {
            if updateNode(at: path, in: &node.children[index], update) {
                return true
            }
        }
        return false
    }

    private static func node(at path: String, in node: Node) -> Node? {
        if node.entry.path == path { return node }
        for child in node.children {
            if let found = Self.node(at: path, in: child) {
                return found
            }
        }
        return nil
    }

    private static func rootName(for path: String) -> String {
        guard let component = path.split(separator: "/").last, !component.isEmpty else {
            return "/"
        }
        return String(component)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? RemoteFileError {
            switch error {
            case .notFound(let path):
                return "\(path) no longer exists."
            case .permissionDenied(let path):
                return "Permission was denied for \(path)."
            case .tooLarge(_, let sizeBytes, let limit):
                return "The directory response was too large (\(sizeBytes) bytes; limit \(limit))."
            case .failure(let message):
                return message
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
