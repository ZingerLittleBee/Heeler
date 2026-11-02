import CryptoKit
import Foundation

@testable import Heeler

/// A Linux Host, or with `macOS` a Mac, for the Host Helper, without SSH or a
/// shell: an in-memory file tree and a scripted systemd or launchd. It acts on
/// each script's step, as the real scripts do in
/// `scripts/test-host-helper-scripts.py`, and keeps every script's text and every
/// file write, in order, for tests to read.
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

    static let macHome = "/Users/me"
    static let macHelperDirectory = "/Users/me/Library/Application Support/heeler/host-helper"
    static let launchAgent = "/Users/me/Library/LaunchAgents/dev.bybee.heeler.host-helper.plist"
    static let macDomain = "user/501"
    static let macService = "user/501/dev.bybee.heeler.host-helper"

    /// launchd holds the agent.
    var agentLoaded = false
    /// What the next reads of `launchctl print` answer, as real outputs. Past
    /// these, a loaded agent reads as running under `agentPid`.
    var launchctlPrints: [String] = []
    var agentPid = 1116
    /// `bootstrap` answers this, as launchd does for a copy another domain holds.
    var bootstrapRefusal: (status: Int32, message: String)?
    /// `bootout` answers this, whatever launchd holds.
    var bootoutRefusal: (status: Int32, message: String)?
    /// Runs once, right after a `bootout` that stopped the agent, as another
    /// connection reading the Helper at that moment would.
    var afterBootout: (@Sendable () async -> Void)?
    /// The manifest of the Helper the service last started, which stays as it was
    /// until something starts it again. Nil while the service is stopped.
    private(set) var runningCode: Data?

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
    /// What a failed upload throws.
    var uploadError: any Error = Failure()
    /// The folder `mkdir` refuses, and what it says, as when a file has its name.
    var folderRefusal: (folder: String, message: String)?
    /// A Host with neither `sha256sum` nor `shasum`.
    var hashToolMissing = false
    /// Fails the Node.js run that finds the extension folders, with this message.
    var extensionFoldersFailure: String?

    /// The Node.js the service names has gone. Setting the service up again with
    /// the Host's current Node.js clears it.
    var serviceNodeGone = false
    /// The Node.js a session's record names has gone, which only the Helper's next
    /// connection to that session's core rewrites.
    var recordNodeGone = false

    /// What the Helper's Usage query prints, per session.
    private var usageAnswers: [String: Data] = [:]

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

    /// A Mac with Application Support and no LaunchAgents folder yet.
    static func macOS() async -> ScriptedHelperHost {
        let host = ScriptedHelperHost()
        await host.becomeMac()
        return host
    }

    private func becomeMac() {
        kernel = "Darwin"
        node = .found(path: "/opt/homebrew/bin/node")
        folders = [:]
        seedFolder("\(Self.macHome)/Library/Application Support")
    }

    private var isMac: Bool { kernel == "Darwin" }
    private var homeDirectory: String { isMac ? Self.macHome : Self.home }
    private var helperDirectory: String { isMac ? Self.macHelperDirectory : Self.helperDirectory }

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

    /// The files a Usage read looks for in an installed Helper.
    func installApp(usage: Bool = true) {
        seedFile("\(Self.helperDirectory)/app/main.js", Data())
        if usage { seedFile("\(Self.helperDirectory)/app/usage-query.js", Data()) }
    }

    /// What the Helper has for a session once it has recorded its core.
    func seedUsage(_ report: Data, session: String) {
        seedFile("\(Self.helperDirectory)/sessions/\(session)/runtime-node", Data((Self.node + "\n").utf8))
        usageAnswers[session] = report
    }

    /// Everything under a folder, for tests of what an install left.
    func filePaths() -> Set<String> { Set(files.keys) }

    func hostPlatform() async throws -> HostPlatform { platform }

    // MARK: What a harness edit asks of the same files

    func readHostFile(_ range: RemoteFileRange) -> RemoteFileSlice {
        guard let file = files[range.path]?.contents else { return RemoteFileSlice(data: Data(), length: nil) }
        let start = min(Int(range.offset), file.count)
        return RemoteFileSlice(
            data: file[start..<min(start + range.maxBytes, file.count)], length: UInt64(file.count))
    }

    func replaceHostText(path: String, expected: Data?, contents: Data?) throws {
        guard files[path]?.contents == expected else { throw HostTextFileError.changedSinceRead }
        journal.append("\(contents == nil ? "removeText" : "writeText") \(path)")
        files[path] = contents.map { File(contents: $0, mode: files[path]?.mode ?? 0o600) }
    }

    func createFolder(_ path: String) {
        journal.append("makeFolder \(path)")
        seedFolder(path)
    }

    func removeFolderIfEmpty(_ path: String) {
        journal.append("removeFolder \(path)")
        guard !files.keys.contains(where: { $0.hasPrefix("\(path)/") }) else { return }
        folders[path] = nil
    }

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
        if name == failUploadsNamed { throw uploadError }
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
        case .listExtensionFolders(_, _, let home):
            if let extensionFoldersFailure {
                status = 1
                stderr = extensionFoldersFailure
            } else {
                lines = [extensionFoldersLine(home: home)]
            }
        case .makeFolders(let chain, let privateFolder):
            for folder in chain where folders[folder] == nil {
                if let folderRefusal, folderRefusal.folder == folder {
                    status = 1
                    stderr = folderRefusal.message
                    break
                }
                folders[folder] = 0o700
                lines.append("created \(folder)")
            }
            if status == 0 { folders[privateFolder] = 0o700 }
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
        case .launchctl(let arguments):
            let answer = applyLaunchctl(arguments)
            lines = answer.lines
            status = answer.status
            stderr = answer.stderr
        case .launchdHealth:
            let read = printAnswer()
            if read.status == 0 {
                lines = Self.ownFields(ofPrint: read.text)
            } else {
                status = read.status
                stderr = read.text
            }
        case .bootOutAndRemove(let service, let propertyList):
            let answer = applyLaunchctl(["bootout", service])
            lines = answer.lines
            status = answer.status
            stderr = answer.stderr
            if HostHelperLaunchAgent.bootoutDone.contains(status) { files[propertyList] = nil }
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
        case .usageQuery(_, _, let session):
            lines = ["__HEELER_USAGE_BEGIN_\(script.nonce)", usageBody(session: session), "__HEELER_USAGE_END_\(script.nonce):0"]
        }
        if let afterBootout, isStoppedByBootout(script.step) {
            self.afterBootout = nil
            await afterBootout()
        }
        let framed = (["\(script.nonce) begin"] + lines + ["\(script.nonce) end"]).joined(separator: "\n") + "\n"
        return GitExecResult(stdout: Data(framed.utf8), stderr: Data(stderr.utf8), exitStatus: status)
    }

    private func isStoppedByBootout(_ step: HostHelperScript.Step) -> Bool {
        switch step {
        case .launchctl(let arguments): arguments.first == "bootout" && !agentLoaded
        case .bootOutAndRemove: !agentLoaded
        default: false
        }
    }

    /// Acts as the Usage script does: it checks the Helper's files, makes the
    /// session's folder, and has no report without the record's Node.js path.
    private func usageBody(session: String) -> String {
        let directory = helperDirectory
        guard files["\(directory)/app/main.js"] != nil else { return "helper-absent" }
        guard files["\(directory)/app/usage-query.js"] != nil else { return "helper-outdated" }
        folders["\(directory)/sessions"] = 0o700
        folders["\(directory)/sessions/\(session)"] = 0o700
        let missing = #"{"version":1,"runtime":"missing"}"#
        if recordNodeGone, files["\(directory)/sessions/\(session)/runtime-node"] != nil {
            return serviceNodeGone ? "helper-node-gone" : missing
        }
        guard files["\(directory)/sessions/\(session)/runtime-node"] != nil, let report = usageAnswers[session]
        else { return missing }
        return String(decoding: report, as: UTF8.self)
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
            if arguments.contains("--now") {
                activeState = "inactive"
                runningCode = nil
            }
        case "stop":
            activeState = "inactive"
            runningCode = nil
        case "restart":
            activeState = "active"
            result = "success"
            runningCode = files["\(helperDirectory)/app/manifest.json"]?.contents
            serviceNodeGone = false
        default:
            break
        }
    }

    /// launchd's answers, by the spike's records (`docs/agents/herdr-compatibility.md`).
    private func applyLaunchctl(_ arguments: [String]) -> (lines: [String], status: Int32, stderr: String) {
        switch arguments.first {
        case "bootstrap":
            if let bootstrapRefusal { return ([], bootstrapRefusal.status, bootstrapRefusal.message) }
            guard arguments.count == 3, arguments[1] == Self.macDomain, let list = files[arguments[2]]?.contents,
                let agent = try? PropertyListSerialization.propertyList(from: list, format: nil) as? [String: Any],
                agent["LimitLoadToSessionType"] as? String == "Background"
            else { return ([], 5, "Bootstrap failed: 5: Input/output error") }
            agentLoaded = true
            runningCode = files["\(helperDirectory)/app/manifest.json"]?.contents
            serviceNodeGone = false
            return ([], 0, "")
        case "bootout":
            if let bootoutRefusal { return ([], bootoutRefusal.status, bootoutRefusal.message) }
            guard agentLoaded, arguments.count == 2, arguments[1] == Self.macService else {
                return ([], 3, "Boot-out failed: 3: No such process")
            }
            agentLoaded = false
            runningCode = nil
            return ([], 0, "")
        default:
            return ([], 64, "Unrecognized subcommand")
        }
    }

    /// The script leaves a nested dictionary's values on the Host.
    private static func ownFields(ofPrint text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.hasPrefix("\t\t") }
    }

    private func printAnswer() -> (text: String, status: Int32) {
        if !launchctlPrints.isEmpty { return (launchctlPrints.removeFirst(), 0) }
        guard agentLoaded else {
            return ("Bad request.\nCould not find service", HostHelperHealth.launchctlNotLoadedStatus)
        }
        return ("\(Self.macService) = {\n\tstate = running\n\truns = 1\n\tpid = \(agentPid)\n\tlast exit code = (never exited)\n}", 0)
    }

    /// What `extensions/extension-folders.js` prints, whose own tests are Node's.
    private func extensionFoldersLine(home: String) -> String {
        let profiles = "\(home)/.omp/profiles"
        let names = folders.keys
            .filter { ($0 as NSString).deletingLastPathComponent == profiles }
            .map { ($0 as NSString).lastPathComponent }
            .sorted()
        let paths = ["\(home)/.pi/agent/extensions", "\(home)/.omp/agent/extensions"]
            + names.map { "\(profiles)/\($0)/agent/extensions" }
        let entries = paths.map { path in
            let installed = files["\(path)/\(HostHelperScript.extensionFileName)"] != nil
            return "{\"path\":\"\(path)\",\"installed\":\(installed)}"
        }
        return "{\"folders\":[\(entries.joined(separator: ","))]}"
    }

    private func locationLines() -> [String] {
        let data = isMac ? "Library/Application Support" : ".local/share"
        return ["home \(homeDirectory)", "data \(homeDirectory)/\(data)", "config \(homeDirectory)/.config"]
    }

    private func hashLines(root: String) -> [String] {
        if hashToolMissing { return ["hash-tool-missing"] }
        return files.keys.filter { $0.hasPrefix(root + "/") && $0 != "\(root)/manifest.json" }.sorted().compactMap { path in
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
        if isMac {
            lines.append("uid 501")
            if files[Self.launchAgent] != nil { lines.append("launch-agent-file") }
            let read = printAnswer()
            lines.append("launchd-exit \(read.status)")
            lines += Self.ownFields(ofPrint: read.text).map { "launchd \($0)" }
        } else if !hasSystemd {
            lines += ["linger \(lingerOn ? "yes" : "no")", "no-systemd"]
        } else if !userManagerReachable {
            lines += ["linger \(lingerOn ? "yes" : "no")", "unit-unreachable"]
        } else {
            let loaded = files[Self.unit] != nil
            lines += [
                "linger \(lingerOn ? "yes" : "no")",
                "unit LoadState=\(loaded ? "loaded" : "not-found")", "unit ActiveState=\(activeState)",
                "unit Result=\(result)", "unit NRestarts=\(restarts)",
            ]
        }
        if serviceNodeGone { lines.append("helper-node-gone") }
        let directory = helperDirectory
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
        case .listExtensionFolders: "listExtensionFolders"
        case .makeFolders: "makeFolders"
        case .prepareStaging: "prepareStaging"
        case .hashTree: "hashTree"
        case .promote: "promote"
        case .systemctl(let arguments): "systemctl \(arguments.joined(separator: " "))"
        case .launchctl(let arguments): "launchctl \(arguments.joined(separator: " "))"
        case .launchdHealth(let service): "launchctl print \(service)"
        case .bootOutAndRemove(let service, _): "launchctl bootout \(service)"
        case .enableLinger: "enableLinger"
        case .removeFiles(let paths): "removeFiles \(paths.joined(separator: " "))"
        case .removeEmptyFolders(let paths): "removeEmptyFolders \(paths.joined(separator: " "))"
        case .removeTree(let path): "removeTree \(path)"
        case .usageQuery(_, _, let session): "usageQuery \(session)"
        }
    }
}

/// A small Helper for install tests, with real hashes in its manifest.
enum HostHelperFixture {
    static func bundle(
        version: String = "\(HostHelperCompatibility.bundled)", extraFiles: [String: Data] = [:]
    ) -> HostHelperBundle {
        let files = extraFiles.merging([
            "main.js": Data("console.log('main')\n".utf8),
            "package.json": Data("{\"type\":\"module\"}\n".utf8),
            HostHelperScript.extensionPath: Data("export default function () {}\n".utf8),
            HostHelperScript.extensionFoldersPath: Data("console.log('{}')\n".utf8),
            "shared/delivery/push.js": Data("export const push = 1;\n".utf8),
            "version.json": Data("{\"version\":\"\(version)\"}\n".utf8),
        ]) { $1 }
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
