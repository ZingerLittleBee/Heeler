import CryptoKit
import Foundation

@testable import Heeler

/// A Linux Host for the Host Helper, without SSH or a shell: an in-memory file
/// tree and a scripted systemd. It acts on each script's step, as the real
/// scripts do in `scripts/test-host-helper-scripts.py`, and keeps every script's
/// text and every file write, in order, for tests to read.
actor ScriptedHelperHost: HostHelperHost {
    struct File: Equatable, Sendable {
        var contents: Data
        var mode: UInt32
    }

    struct Failure: Error, Equatable {}

    static let home = "/home/me"
    static let helperDirectory = "/home/me/.local/share/heeler/host-helper"
    static let unit = "/home/me/.config/systemd/user/heeler-host-helper.service"
    static let unitLink = "/home/me/.config/systemd/user/default.target.wants/heeler-host-helper.service"
    static let node = "/home/me/.volta/tools/node/22.1.0/bin/node"

    var platform = HostPlatform.posix
    var kernel = "Linux"
    var hasSystemd = true
    var node = HostHelperProbe.Node.found(path: ScriptedHelperHost.node)
    var lingerOn = true
    /// Whether anything answers at the user bus.
    var userManagerReachable = true
    var activeState = "inactive"
    var result = "success"
    var restarts = 0
    /// What `systemctl` prints when told to act and refusing it.
    var systemctlFailure: String?
    /// Refuses `enable-linger` with this message.
    var lingerRefusal: String?
    /// Corrupts this file of an upload as it lands, as a bad link might.
    var corruptUploadNamed: String?
    var failUploadsNamed: String?

    private(set) var files: [String: File] = [:]
    private(set) var folders: [String: UInt32] = [:]
    /// Every step, in order.
    private(set) var steps: [HostHelperScript.Step] = []
    /// Every script's text, in order.
    private(set) var scripts: [String] = []
    /// Every file write, in order, with what directory it kept private.
    private(set) var writes: [(path: String, privateDirectory: String?)] = []
    private(set) var reads: [String] = []
    /// Steps and writes as one list, for order checks.
    private(set) var journal: [String] = []

    init() {
        for folder in ["/home", Self.home] { folders[folder] = 0o755 }
    }

    func configure(_ change: @Sendable (isolated ScriptedHelperHost) -> Void) {
        change(self)
    }

    func clearLog() {
        steps = []
        scripts = []
        writes = []
        reads = []
        journal = []
    }

    func removeFile(_ path: String) {
        files[path] = nil
    }

    func seedFolder(_ path: String, mode: UInt32 = 0o755) {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/\(component)"
            if folders[current] == nil { folders[current] = mode }
        }
    }

    func seedFile(_ path: String, _ contents: Data, mode: UInt32 = 0o600) {
        seedFolder((path as NSString).deletingLastPathComponent)
        files[path] = File(contents: contents, mode: mode)
    }

    /// Everything under a folder, for tests of what an install left.
    func filePaths() -> Set<String> { Set(files.keys) }

    func hostPlatform() async throws -> HostPlatform { platform }

    func readHostHelperFile(at path: String, privateDirectory: String) async throws -> Data? {
        reads.append(path)
        journal.append("read \(path)")
        guard folders[privateDirectory] != nil else { throw Failure() }
        return files[path]?.contents
    }

    func replaceHostHelperFile(_ contents: Data, at path: String, privateDirectory: String?) async throws {
        writes.append((path, privateDirectory))
        journal.append("write \(path)")
        let name = (path as NSString).lastPathComponent
        if name == failUploadsNamed { throw Failure() }
        guard folders[(path as NSString).deletingLastPathComponent] != nil else { throw Failure() }
        if let privateDirectory { folders[privateDirectory] = 0o700 }
        files[path] = File(
            contents: name == corruptUploadNamed ? Data("corrupt".utf8) : contents, mode: 0o600)
    }

    func runHostHelperScript(_ script: HostHelperScript) async throws -> GitExecResult {
        steps.append(script.step)
        scripts.append(script.text)
        journal.append(Self.describe(script.step))
        var lines: [String] = []
        var status: Int32 = 0
        var stderr = ""
        switch script.step {
        case .probe:
            lines = probeLines()
        case .locate:
            lines = locationLines()
        case .makeFolders(let chain, let privateFolder):
            for folder in chain where folders[folder] == nil {
                folders[folder] = 0o700
                lines.append("created \(folder)")
            }
            folders[privateFolder] = 0o700
        case .prepareStaging(let directory, let staging, let subfolders):
            for path in Array(files.keys) + Array(folders.keys)
            where path.hasPrefix("\(directory)/staging-") || path.hasPrefix("\(directory)/app.old-") {
                files[path] = nil
                folders[path] = nil
            }
            for folder in [staging] + subfolders {
                var current = staging
                folders[staging] = 0o700
                for component in folder.dropFirst(staging.count).split(separator: "/") {
                    current += "/\(component)"
                    folders[current] = 0o700
                }
            }
        case .hashTree(let root):
            lines = hashLines(root: root)
        case .promote(let staging, let app):
            removeTree(app)
            move(staging, to: app)
        case .systemctl(let arguments):
            if let failure = systemctlFailure, arguments.first != "reset-failed" {
                status = 1
                stderr = failure
            } else {
                applySystemctl(arguments)
            }
        case .enableLinger:
            if let lingerRefusal {
                status = 1
                stderr = lingerRefusal
            } else {
                lingerOn = true
            }
        case .removeFiles(let paths):
            for path in paths { files[path] = nil }
        case .removeEmptyFolders(let paths):
            for path in paths where isEmpty(path) { folders[path] = nil }
        case .removeTree(let path):
            removeTree(path)
        }
        let framed = (["\(script.nonce) begin"] + lines + ["\(script.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(framed.utf8), stderr: Data(stderr.utf8), exitStatus: status)
    }

    private func isEmpty(_ folder: String) -> Bool {
        !(files.keys.contains { $0.hasPrefix(folder + "/") } || folders.keys.contains { $0.hasPrefix(folder + "/") })
    }

    private func removeTree(_ path: String) {
        for key in files.keys where key == path || key.hasPrefix(path + "/") { files[key] = nil }
        for key in folders.keys where key == path || key.hasPrefix(path + "/") { folders[key] = nil }
    }

    private func move(_ source: String, to target: String) {
        for (key, value) in files where key.hasPrefix(source + "/") {
            files[key] = nil
            files[target + key.dropFirst(source.count)] = value
        }
        for (key, value) in folders where key == source || key.hasPrefix(source + "/") {
            folders[key] = nil
            folders[target + key.dropFirst(source.count)] = value
        }
    }

    private func applySystemctl(_ arguments: [String]) {
        switch arguments.first {
        case "enable":
            files[Self.unitLink] = File(contents: Data(), mode: 0o777)
        case "disable":
            files[Self.unitLink] = nil
            if arguments.contains("--now") { activeState = "inactive" }
        case "restart":
            activeState = "active"
            result = "success"
        default:
            break
        }
    }

    private func locationLines() -> [String] {
        ["home \(Self.home)", "data \(Self.home)/.local/share", "config \(Self.home)/.config"]
    }

    private func hashLines(root: String) -> [String] {
        files.keys.filter { $0.hasPrefix(root + "/") && $0 != "\(root)/manifest.json" }.sorted().compactMap { path in
            guard let file = files[path] else { return nil }
            let sum = SHA256.hash(data: file.contents).map { String(format: "%02x", $0) }.joined()
            return "hash \(sum) \(path.dropFirst(root.count + 1))"
        }
    }

    private func probeLines() -> [String] {
        var lines = ["kernel \(kernel)", "user me"] + locationLines()
        switch node {
        case .found(let path): lines.append("node \(path)")
        case .tooOld(let version): lines.append("node-old \(version)")
        case .missing: lines.append("node-missing")
        }
        lines.append("linger \(lingerOn ? "yes" : "no")")
        if !hasSystemd {
            lines.append("no-systemd")
        } else if !userManagerReachable {
            lines.append("unit-unreachable")
        } else {
            let loaded = files[Self.unit] != nil
            lines += [
                "unit LoadState=\(loaded ? "loaded" : "not-found")", "unit ActiveState=\(activeState)",
                "unit Result=\(result)", "unit NRestarts=\(restarts)",
            ]
        }
        let directory = Self.helperDirectory
        if let record = files["\(directory)/installed.json"] { lines.append("record \(Self.hex(record.contents))") }
        let app = "\(directory)/app"
        if folders[app] != nil {
            lines.append("app-present")
            if let manifest = files["\(app)/manifest.json"] { lines.append("manifest \(Self.hex(manifest.contents))") }
            lines += hashLines(root: app)
        }
        return lines
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ step: HostHelperScript.Step) -> String {
        switch step {
        case .probe: "probe"
        case .locate: "locate"
        case .makeFolders: "makeFolders"
        case .prepareStaging: "prepareStaging"
        case .hashTree: "hashTree"
        case .promote: "promote"
        case .systemctl(let arguments): "systemctl \(arguments.joined(separator: " "))"
        case .enableLinger: "enableLinger"
        case .removeFiles(let paths): "removeFiles \(paths.joined(separator: " "))"
        case .removeEmptyFolders(let paths): "removeEmptyFolders \(paths.joined(separator: " "))"
        case .removeTree(let path): "removeTree \(path)"
        }
    }
}

/// A small Helper for install tests, with real hashes in its manifest.
enum HostHelperFixture {
    static func bundle(version: String = "\(HostHelperCompatibility.bundled)") -> HostHelperBundle {
        let files = [
            "main.js": Data("console.log('main')\n".utf8),
            "package.json": Data("{\"type\":\"module\"}\n".utf8),
            "shared/delivery/push.js": Data("export const push = 1;\n".utf8),
            "version.json": Data("{\"version\":\"\(version)\"}\n".utf8),
        ]
        let manifest = HostHelperManifest(
            version: version,
            files: files.keys.sorted().map { path in
                HostHelperManifest.File(
                    path: path,
                    sha256: SHA256.hash(data: files[path] ?? Data()).map { String(format: "%02x", $0) }.joined())
            })
        return HostHelperBundle(
            manifest: manifest, manifestData: (try? JSONEncoder().encode(manifest)) ?? Data(), files: files)
    }
}
