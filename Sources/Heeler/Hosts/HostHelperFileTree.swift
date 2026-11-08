import Foundation

/// One place on the Host an install writes to, as the install sheet lists it:
/// the Helper's directory, what registers its service, and the Pi and Oh My Pi
/// extensions. Each is browsed as folders rather than as absolute paths.
struct HostHelperFileLocation: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case helper
        case service(HostHelperServiceManager)
        case extensions
    }

    let kind: Kind
    /// The absolute paths written here, every one of them under `root`.
    let paths: [String]
    /// The folder the location's tree starts at.
    let root: String
    /// The user's home directory on the Host, which displayed paths shorten to `~`.
    let home: String

    var id: String { root + "|" + title }

    init(kind: Kind, paths: [String], home: String) {
        self.kind = kind
        self.paths = paths
        self.home = home
        root = Self.commonFolder(of: paths)
    }

    var title: String {
        switch kind {
        case .helper: "Helper"
        case .service(.launchd): "LaunchAgent"
        case .service(.systemd): "systemd Unit"
        case .extensions: "Pi & Oh My Pi"
        }
    }

    var folder: HostHelperFileFolder {
        HostHelperFileFolder(root: root, paths: paths, home: home)
    }

    /// Where this is, for its row: the root, or each top folder below a root
    /// that holds nothing else, so two extension folders under `~` read as
    /// `~/.omp · ~/.pi` rather than `~`.
    var summary: String {
        let folder = folder
        guard folder.files.isEmpty, folder.folders.count > 1 else { return folder.displayPath }
        return folder.folders.map { child in
            let top = child.name.split(separator: "/").first.map(String.init) ?? child.name
            return HostHelperFileFolder.display(path: "\(root)/\(top)", home: home)
        }.joined(separator: " · ")
    }

    /// The deepest folder holding every path.
    private static func commonFolder(of paths: [String]) -> String {
        let folders = paths.map { $0.split(separator: "/").dropLast() }
        guard var common = folders.first else { return "/" }
        for folder in folders.dropFirst() {
            common = common.prefix(zip(common, folder).prefix { $0 == $1 }.count)
        }
        return "/" + common.joined(separator: "/")
    }
}

/// A folder of what an install writes. A folder that holds only one folder
/// folds into it, so `.pi/agent/extensions` is one row, not three.
struct HostHelperFileFolder: Sendable, Equatable, Identifiable {
    /// Relative to the folder above it; empty for a location's root.
    let name: String
    /// Absolute.
    let path: String
    let folders: [HostHelperFileFolder]
    /// File names in this folder, sorted.
    let files: [String]
    /// Every file at any depth below.
    let fileCount: Int
    let displayPath: String

    var id: String { path }

    init(root: String, paths: [String], home: String) {
        let prefix = root == "/" ? "/" : root + "/"
        let relative = paths.filter { $0.hasPrefix(prefix) }.map { $0.dropFirst(prefix.count).split(separator: "/") }
        self.init(name: "", path: root, relative: relative, home: home)
    }

    private init(name: String, path: String, relative: [[Substring]], home: String) {
        var files: [String] = []
        var children: [String: [[Substring]]] = [:]
        for components in relative {
            guard let first = components.first else { continue }
            if components.count == 1 {
                files.append(String(first))
            } else {
                children[String(first), default: []].append(Array(components.dropFirst()))
            }
        }
        let folders = children.keys.sorted().map { child in
            HostHelperFileFolder(
                name: child, path: path == "/" ? "/\(child)" : "\(path)/\(child)",
                relative: children[child] ?? [], home: home
            ).folded()
        }
        self.init(
            name: name, path: path, folders: folders, files: files.sorted(),
            fileCount: files.count + folders.reduce(0) { $0 + $1.fileCount },
            displayPath: Self.display(path: path, home: home))
    }

    private init(
        name: String, path: String, folders: [HostHelperFileFolder], files: [String], fileCount: Int,
        displayPath: String
    ) {
        self.name = name
        self.path = path
        self.folders = folders
        self.files = files
        self.fileCount = fileCount
        self.displayPath = displayPath
    }

    private func folded() -> HostHelperFileFolder {
        guard files.isEmpty, folders.count == 1, let only = folders.first else { return self }
        return HostHelperFileFolder(
            name: "\(name)/\(only.name)", path: only.path, folders: only.folders, files: only.files,
            fileCount: only.fileCount, displayPath: only.displayPath)
    }

    /// `path` with the home directory shortened to `~`.
    static func display(path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
