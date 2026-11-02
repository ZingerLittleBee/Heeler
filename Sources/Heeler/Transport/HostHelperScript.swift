import Foundation

/// One exec's worth of Host Helper work (ADR 0033): the POSIX script, and the
/// step it carries out, so a scripted Host can act on the step while the script
/// itself runs against real shells in `scripts/test-host-helper-scripts.py`.
struct HostHelperScript: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        /// Everything the app needs to know, in one read that changes nothing.
        case probe
        /// Only the directories the Helper's paths come from.
        case locate
        /// Runs the Helper's `extensions/extension-folders.js`, by its text since
        /// the Helper may not be on this Host yet.
        case listExtensionFolders(node: String, lister: String, home: String)
        /// Creates each folder that is missing, parents first, and says which.
        /// `privateFolder` ends at 0700 whether or not it was new.
        case makeFolders([String], privateFolder: String)
        /// Clears what an interrupted install left, then makes a private
        /// staging directory and its subfolders.
        case prepareStaging(directory: String, staging: String, folders: [String])
        /// Each regular file's SHA-256 under `root`, but its `manifest.json`.
        case hashTree(root: String)
        /// Moves `staging` to `app`, replacing whatever was there.
        case promote(staging: String, app: String)
        case systemctl([String])
        case launchctl([String])
        /// Boots a LaunchAgent out and, once it is gone, deletes its property list
        /// in the same exec, so no read in between finds a list to load back.
        case bootOutAndRemove(service: String, propertyList: String)
        case enableLinger(user: String)
        case removeFiles([String])
        /// Removes each folder that is empty, in the order given.
        case removeEmptyFolders([String])
        case removeTree(String)
        /// Runs the Helper's own Usage query for a session, whose folder it makes
        /// so the Helper comes to follow that session's core. The whole answer
        /// is framed and capped, so a cut-off report can never read as complete.
        case usageQuery(timeZone: String, claudeLimits: Bool, session: String)
    }

    /// The unit's name, one per SSH user.
    static let unitName = "heeler-host-helper.service"
    /// The Helper directory under the user's data home.
    static let helperDirectorySuffix = "heeler/host-helper"
    /// Where the Helper's files sit in that directory, apart from the
    /// registrations and seen marks that outlive a replacement.
    static let appFolderName = "app"
    static let manifestFileName = "manifest.json"
    static let stagingPrefix = "staging-"
    /// What the Helper places in each folder Pi and Oh My Pi load extensions from.
    static let extensionFileName = "heeler-session.js"
    /// That file in the Helper's tree.
    static let extensionPath = "extensions/\(extensionFileName)"
    /// The script that finds those folders, in the Helper's tree.
    static let extensionFoldersPath = "extensions/extension-folders.js"

    let step: Step
    let nonce: String
    let text: String

    init(_ step: Step, nonce: String) {
        self.step = step
        self.nonce = nonce
        text = Self.text(for: step, nonce: nonce)
    }

    /// A user unit's `systemctl` under the runtime directory a login would
    /// have, since a Host without `pam_systemd` leaves it unset. Every
    /// `systemctl --user` the app runs starts this way.
    static func systemctlCommand(_ arguments: [String]) -> String {
        let quoted = arguments.map(quote).joined(separator: " ")
        return "XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\" systemctl --user \(quoted)"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func text(for step: Step, nonce: String) -> String {
        let lines: [String]
        switch step {
        case .probe: lines = probe
        case .locate: lines = locations
        case .listExtensionFolders(let node, let lister, let home):
            // The script itself is this shell's stdin, so Node must not read it.
            lines = ["\(quote(node)) --input-type=module -e \(quote(lister)) \(quote(home)) </dev/null"]
        case .makeFolders(let folders, let privateFolder):
            // A function, so a failure still ends the frame and the app learns
            // which folders it would otherwise leave behind.
            lines = ["umask 077", "__h_make() {"]
                + folders.map { folder in
                    let path = quote(folder)
                    return "if [ ! -d \(path) ]; then mkdir -- \(path) || return 1; "
                        + "printf 'created %s\\n' \(path); fi"
                }
                // Paths are absolute, and BSD chmod takes no `--`.
                + ["chmod 700 \(quote(privateFolder)) || return 1", "}", "__h_make"]
        case .prepareStaging(let directory, let staging, let folders):
            let dir = quote(directory)
            lines = [
                "umask 077",
                "rm -rf -- \(dir)/\(stagingPrefix)* \(dir)/\(appFolderName).old-*",
                "mkdir -p -- \(([staging] + folders).map(quote).joined(separator: " ")) || exit 1",
            ]
        case .hashTree(let root):
            lines = hashes(under: quote(root))
        case .promote(let staging, let app):
            let old = quote("\(app).old-\(nonce)")
            lines = [
                "if [ -e \(quote(app)) ]; then mv -- \(quote(app)) \(old) || exit 1; fi",
                "if ! mv -- \(quote(staging)) \(quote(app)); then "
                    + "[ ! -e \(old) ] || mv -- \(old) \(quote(app)); exit 1; fi",
                "rm -rf -- \(old)",
            ]
        case .systemctl(let arguments):
            lines = ["LC_ALL=C; export LC_ALL", systemctlCommand(arguments)]
        case .launchctl(let arguments):
            lines = ["LC_ALL=C; export LC_ALL", "launchctl \(arguments.map(quote).joined(separator: " "))"]
        case .bootOutAndRemove(let service, let propertyList):
            let done = HostHelperLaunchAgent.bootoutDone.map(String.init).joined(separator: "|")
            lines = [
                "LC_ALL=C; export LC_ALL",
                "launchctl bootout \(quote(service))",
                "__h_bootout=$?",
                "case \"$__h_bootout\" in \(done)) rm -f -- \(quote(propertyList)) ;; esac",
                "(exit \"$__h_bootout\")",
            ]
        case .enableLinger(let user):
            // Never waits on an administrator's password: a refusal comes back.
            lines = ["LC_ALL=C; export LC_ALL", "loginctl --no-ask-password enable-linger \(quote(user))"]
        case .removeFiles(let files):
            lines = files.isEmpty ? [":"] : ["rm -f -- \(files.map(quote).joined(separator: " "))"]
        case .removeEmptyFolders(let folders):
            lines = folders.isEmpty ? [":"] : folders.map { "rmdir -- \(quote($0)) 2>/dev/null || :" }
        case .removeTree(let path):
            lines = ["rm -rf -- \(quote(path))"]
        case .usageQuery(let timeZone, let claudeLimits, let session):
            lines = usageQuery(timeZone: timeZone, claudeLimits: claudeLimits, session: session, nonce: nonce)
        }
        return (["printf '%s begin\\n' \(quote(nonce))"] + lines
            + ["__h_status=$?", "printf '%s end\\n' \(quote(nonce))", "exit \"$__h_status\""])
            .joined(separator: "\n") + "\n"
    }

    /// Application Support on a Mac, whatever `XDG_DATA_HOME` an SSH login has.
    private static let dataHome =
        "case \"$(uname -s)\" in Darwin) __h_data=\"$HOME/Library/Application Support\";; "
        + "*) case \"$XDG_DATA_HOME\" in /*) __h_data=\"$XDG_DATA_HOME\";; *) __h_data=\"$HOME/.local/share\";; esac;; esac"

    private static let locations = [
        dataHome,
        "case \"$XDG_CONFIG_HOME\" in /*) __h_config=\"$XDG_CONFIG_HOME\";; *) __h_config=\"$HOME/.config\";; esac",
        "printf 'home %s\\n' \"$HOME\"",
        "printf 'data %s\\n' \"$__h_data\"",
        "printf 'config %s\\n' \"$__h_config\"",
    ]

    private static func usageQuery(
        timeZone: String, claudeLimits: Bool, session: String, nonce: String
    ) -> [String] {
        let missing = "printf '%s\\n' '{\"version\":1,\"runtime\":\"missing\"}'"
        let flags = claudeLimits ? " --claude-limits" : ""
        return [
            "LC_ALL=C; export LC_ALL",
            "umask 077",
            "(",
            "printf '%s\\n' \(quote("__HEELER_USAGE_BEGIN_\(nonce)"))",
            dataHome,
            "__h_dir=\"$__h_data\"/\(quote(helperDirectorySuffix))",
            "__h_app=\"$__h_dir\"/\(quote(appFolderName))",
            "__h_session=\"$__h_dir\"/sessions/\(quote(session))",
            "__h_usage() {",
            "  [ -f \"$__h_app/main.js\" ] || { printf 'helper-absent\\n'; return 0; }",
            "  [ -f \"$__h_app/usage-query.js\" ] || { printf 'helper-outdated\\n'; return 0; }",
            "  mkdir -p -- \"$__h_session\" || return 1",
            "  if ! IFS= read -r __h_node < \"$__h_session/runtime-node\"; then \(missing); return 0; fi 2>/dev/null",
            "  case \"$__h_node\" in /*) ;; *) \(missing); return 0 ;; esac",
            "  \"$__h_node\" \"$__h_app/usage-query.js\" --tz \(quote(timeZone)) --session \(quote(session))\(flags)",
            "  __h_result=$?",
            "  case \"$__h_result\" in 126|127) \(missing); return 0 ;; *) return \"$__h_result\" ;; esac",
            "}",
            "__h_usage",
            "__h_result=$?",
            "printf '\\n%s:%s\\n' \(quote("__HEELER_USAGE_END_\(nonce)")) \"$__h_result\"",
            ") | head -c 1048576",
        ]
    }

    /// A tree's hashes as `hash <sum> <path under root>` lines, or one
    /// `hash-tool-missing` line on a Host with neither tool.
    private static func hashes(under root: String) -> [String] {
        [
            "if command -v sha256sum >/dev/null 2>&1; then __h_sum=sha256sum; "
                + "elif command -v shasum >/dev/null 2>&1; then __h_sum='shasum -a 256'; else __h_sum=; fi",
            "if [ -z \"$__h_sum\" ]; then printf 'hash-tool-missing\\n'; else "
                + "__h_root=\(root); "
                + "find \"$__h_root\" -type f ! -path \"$__h_root/\(manifestFileName)\" -exec $__h_sum {} + 2>/dev/null "
                + "| while read -r __h_hash __h_path; do "
                + "printf 'hash %s %s\\n' \"$__h_hash\" \"${__h_path#\"$__h_root\"/}\"; done; fi",
            ":",
        ]
    }

    private static let probe: [String] = [
        "LC_ALL=C; export LC_ALL",
        "__h_kernel=$(uname -s)",
        "printf 'kernel %s\\n' \"$__h_kernel\"",
        "__h_user=$(id -un)",
        "printf 'user %s\\n' \"$__h_user\"",
    ] + locations + [
        "( \(NodeToolchainProbe.nodeOnlyScript) )",
        "if [ \"$__h_kernel\" = Darwin ]; then",
        "__h_uid=$(id -u)",
        "printf 'uid %s\\n' \"$__h_uid\"",
        "if [ -f \"$HOME/Library/LaunchAgents/\(HostHelperLaunchAgent.fileName)\" ]; then printf 'launch-agent-file\\n'; fi",
        "__h_print=$(launchctl print \"user/$__h_uid/\(HostHelperLaunchAgent.label)\" 2>&1)",
        "printf 'launchd-exit %s\\n' \"$?\"",
        // Only the service's own fields leave the Host: the values of its nested
        // dictionaries, its environment among them, are never read.
        "printf '%s\\n' \"$__h_print\" | while IFS= read -r __h_line; do "
            + "case \"$__h_line\" in \"\t\t\"*) ;; *) printf 'launchd %s\\n' \"$__h_line\" ;; esac; done",
        "else",
        // A user who has never logged in through logind has no record to show,
        // and the file is what logind itself keeps.
        "__h_linger=$(loginctl show-user \"$__h_user\" -p Linger 2>/dev/null)",
        "case \"$__h_linger\" in Linger=yes) printf 'linger yes\\n';; Linger=no) printf 'linger no\\n';; "
            + "*) if [ -e \"/var/lib/systemd/linger/$__h_user\" ]; then printf 'linger yes\\n'; "
            + "else printf 'linger no\\n'; fi;; esac",
        "if command -v systemctl >/dev/null 2>&1; then "
            + "if __h_unit=$(\(systemctlCommand(["show", unitName, "-p", "LoadState", "-p", "ActiveState", "-p", "Result", "-p", "NRestarts"])) 2>/dev/null); then "
            + "printf '%s\\n' \"$__h_unit\" | while IFS= read -r __h_line; do printf 'unit %s\\n' \"$__h_line\"; done; "
            + "else printf 'unit-unreachable\\n'; fi; else printf 'no-systemd\\n'; fi",
        "fi",
        "__h_dir=\"$__h_data/\(helperDirectorySuffix)\"",
        "__h_app=\"$__h_dir/\(appFolderName)\"",
        "__h_hex() { od -An -v -tx1 \"$1\" | tr -d ' \\n'; }",
        "if [ -f \"$__h_dir/installed.json\" ]; then printf 'record %s\\n' \"$(__h_hex \"$__h_dir/installed.json\")\"; fi",
        "if [ -e \"$__h_app\" ]; then printf 'app-present\\n'; "
            + "if [ -f \"$__h_app/\(manifestFileName)\" ]; then printf 'manifest %s\\n' \"$(__h_hex \"$__h_app/\(manifestFileName)\")\"; fi; fi",
        "if [ -d \"$__h_app\" ]; then",
    ] + hashes(under: "\"$__h_app\"") + [
        "fi",
    ]
}

/// What registers the Helper's service on a Host.
enum HostHelperServiceManager: Sendable, Equatable {
    case systemd
    case launchd
}

/// The service's state: a user unit's as `systemctl show` gives it, or a
/// LaunchAgent's as `launchctl print` does.
struct HostHelperHealth: Sendable, Equatable {
    var loadState: String
    var activeState: String
    var result: String
    var restarts: Int
    /// Nil under systemd.
    var launchd: Launchd?

    /// What only launchd's answer has. In a VM of macOS 26.5 launchd reported no
    /// failed state in the longest watch, about five minutes, and one read could
    /// catch a run about to die (ADR 0033).
    struct Launchd: Sendable, Equatable {
        var pid: Int?
        /// Whether two reads over ten seconds apart found one run. Nil until asked.
        var staysRunning: Bool?
    }

    static let launchdNotFound = "not-found"
    /// What `launchctl print` exits with for a label the domain does not hold.
    static let launchctlNotLoadedStatus: Int32 = 113

    /// Running, or between two runs of a restart that may yet work. On launchd,
    /// the moment before a run counts too, unless two reads have said otherwise.
    var isUp: Bool {
        if let launchd {
            return launchd.staysRunning ?? (activeState == "running" || activeState == "xpcproxy")
        }
        return activeState == "active" || activeState == "activating" || activeState == "reloading"
    }
    var isLoaded: Bool { loadState == "loaded" }

    init(loadState: String, activeState: String, result: String, restarts: Int, launchd: Launchd? = nil) {
        self.loadState = loadState
        self.activeState = activeState
        self.result = result
        self.restarts = restarts
        self.launchd = launchd
    }

    /// One read of `launchctl print`. Only the service's own fields count: its
    /// nested dictionaries carry a `state` of their own, one tab deeper.
    init(launchctlPrint text: String, exitStatus: Int32) {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            guard let separator = line.range(of: " = ") else { continue }
            fields[String(line[line.index(after: line.startIndex)..<separator.lowerBound])] =
                String(line[separator.upperBound...])
        }
        let state = exitStatus == 0 ? fields["state"] : nil
        let runs = Int(fields["runs"] ?? "") ?? 0
        let result: String
        if let signal = fields["last terminating signal"] {
            result = "signal \(signal)"
        } else if let code = fields["last exit code"], code != "(never exited)" {
            result = "exit \(code)"
        } else if exitStatus != 0, exitStatus != Self.launchctlNotLoadedStatus {
            result = "launchctl exit \(exitStatus)"
        } else {
            result = ""
        }
        self.init(
            loadState: exitStatus == Self.launchctlNotLoadedStatus ? Self.launchdNotFound : (state == nil ? "unknown" : "loaded"),
            activeState: state ?? "inactive",
            result: result,
            restarts: max(runs, 1) - 1,
            launchd: Launchd(pid: Int(fields["pid"] ?? "")))
    }

    /// Whether this read and a later one are both running, as the same process.
    func isSameRun(as later: HostHelperHealth) -> Bool {
        guard activeState == "running", later.activeState == "running", let pid = launchd?.pid else { return false }
        return pid == later.launchd?.pid
    }
}

/// What a probe found. Nothing here has been interpreted yet.
struct HostHelperProbe: Sendable, Equatable {
    enum Node: Sendable, Equatable {
        case found(path: String)
        case tooOld(version: String)
        case missing
    }

    var kernel = ""
    var user = ""
    /// Only a Mac's probe says, for naming launchd's domain.
    var uid = ""
    var locations: Locations
    var node = Node.missing
    var lingerOn = false
    var hasSystemd = true
    /// Nil when systemd's user manager could not be reached.
    var health: HostHelperHealth?
    /// Whether the LaunchAgent's property list is in the user's LaunchAgents folder.
    var launchAgentFilePresent = false
    var appPresent = false
    var manifest: Data?
    var record: Data?
    var hashToolMissing = false
    var hashes: [String: String] = [:]
    /// Nil when nothing asked, or the Host could not say.
    var extensionFolders: [ExtensionFolder]?

    struct Locations: Sendable, Equatable {
        var home: String
        var dataHome: String
        var configHome: String
    }

    /// A folder Pi or Oh My Pi loads extensions from, which need not exist yet.
    struct ExtensionFolder: Decodable, Sendable, Equatable {
        var path: String
        /// Whether Heeler's extension is in it.
        var installed: Bool
    }

    struct Unreadable: Error, Equatable {}

    var manager: HostHelperServiceManager { kernel == "Darwin" ? .launchd : .systemd }

    /// Reads the bytes between the script's markers, so shell startup output
    /// around them is ignored.
    static func framedLines(stdout: Data, nonce: String) throws -> [String] {
        let lines = String(decoding: stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard let begin = lines.lastIndex(of: "\(nonce) begin"[...]),
            let end = lines[begin...].lastIndex(of: "\(nonce) end"[...])
        else { throw Unreadable() }
        return lines[(begin + 1)..<end].map(String.init)
    }

    static func parseLocations(_ lines: [String]) throws -> Locations {
        var home: String?
        var data: String?
        var config: String?
        for line in lines {
            let (key, value) = split(line)
            switch key {
            case "home": home = value
            case "data": data = value
            case "config": config = value
            default: break
            }
        }
        guard let home, let data, let config, home.hasPrefix("/"), data.hasPrefix("/"), config.hasPrefix("/")
        else { throw Unreadable() }
        return Locations(home: home, dataHome: data, configHome: config)
    }

    init(locations: Locations) {
        self.locations = locations
    }

    init(stdout: Data, nonce: String) throws {
        let lines = try Self.framedLines(stdout: stdout, nonce: nonce)
        self.init(locations: try Self.parseLocations(lines))
        var unit: [String: String] = [:]
        var unitReachable = false
        var launchdExit: Int32?
        var launchdLines: [String] = []
        for line in lines {
            let (key, value) = Self.split(line)
            switch key {
            case "kernel": kernel = value
            case "user": user = value
            case "uid": uid = value
            case "launch-agent-file": launchAgentFilePresent = true
            case "launchd-exit": launchdExit = Int32(value)
            case "launchd": launchdLines.append(value)
            case "node": node = .found(path: value)
            case "node-old": node = .tooOld(version: value)
            case "node-missing": node = .missing
            case "linger": lingerOn = value == "yes"
            case "no-systemd": hasSystemd = false
            case "unit":
                unitReachable = true
                let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { unit[String(pair[0])] = String(pair[1]) }
            case "app-present": appPresent = true
            case "manifest": manifest = Self.bytes(hex: value)
            case "record": record = Self.bytes(hex: value)
            case "hash-tool-missing": hashToolMissing = true
            case "hash":
                let pair = value.split(separator: " ", maxSplits: 1)
                if pair.count == 2 { hashes[String(pair[1])] = String(pair[0]) }
            default: break
            }
        }
        if unitReachable {
            health = HostHelperHealth(
                loadState: unit["LoadState"] ?? "",
                activeState: unit["ActiveState"] ?? "",
                result: unit["Result"] ?? "",
                restarts: Int(unit["NRestarts"] ?? "") ?? 0)
        }
        if let launchdExit {
            health = HostHelperHealth(
                launchctlPrint: launchdLines.joined(separator: "\n"), exitStatus: launchdExit)
        }
    }

    private static func split(_ line: String) -> (key: String, value: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    private static func bytes(hex: String) -> Data? {
        // Counted in bytes: the Host chooses this text, so it need not be ASCII.
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Character(UnicodeScalar(digits[index])).hexDigitValue,
                let low = Character(UnicodeScalar(digits[index + 1])).hexDigitValue
            else { return nil }
            data.append(UInt8(high << 4 | low))
        }
        return data
    }

    /// The JSON line of a `.listExtensionFolders` run.
    static func parseExtensionFolders(stdout: Data, nonce: String) throws -> [ExtensionFolder] {
        struct Listing: Decodable { let folders: [ExtensionFolder] }
        let line = try framedLines(stdout: stdout, nonce: nonce).first { $0.hasPrefix("{") }
        guard let line, let listing = try? JSONDecoder().decode(Listing.self, from: Data(line.utf8)),
            listing.folders.allSatisfy({ $0.path.hasPrefix("/") })
        else { throw Unreadable() }
        return listing.folders
    }

    /// `hash <sum> <path>` lines of a `.hashTree` run.
    static func parseHashes(stdout: Data, nonce: String) throws -> [String: String]? {
        var hashes: [String: String] = [:]
        for line in try framedLines(stdout: stdout, nonce: nonce) {
            let (key, value) = split(line)
            if key == "hash-tool-missing" { return nil }
            guard key == "hash" else { continue }
            let pair = value.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { hashes[String(pair[1])] = String(pair[0]) }
        }
        return hashes
    }
}

/// The Helper as a LaunchAgent (ADR 0033): one per SSH user, in `user/<uid>`, the
/// only domain a plain SSH exec could use with or without a desktop login in a VM
/// of macOS 26.5. There that domain refused a property list without
/// `LimitLoadToSessionType`.
enum HostHelperLaunchAgent {
    static let label = "dev.bybee.heeler.host-helper"
    static let fileName = "\(label).plist"
    /// Beside the Helper's other files, and not in the `app` folder an update replaces.
    static let logFileName = "helper.log"
    /// launchd's minimum runtime is ten seconds, and a run that dies sooner is
    /// not restarted before it has passed, so two reads this far apart cannot
    /// meet the same pid in a Helper that dies at start.
    static let healthGap = Duration.seconds(11)
    /// `bootout`'s answers for stopped now, or nothing to stop. A VM of macOS 26.5
    /// answered 3 for a label it did not hold. 113, `launchctl print`'s answer for
    /// that, was not seen here, and can only mean the same.
    static let bootoutDone: [Int32] = [0, 3, HostHelperHealth.launchctlNotLoadedStatus]

    static func domain(uid: String) -> String { "user/\(uid)" }
    static func service(uid: String) -> String { "\(domain(uid: uid))/\(label)" }

    /// Node.js by its absolute path, as launchd's `PATH` holds only system directories.
    static func propertyList(nodePath: String, mainPath: String, logPath: String) throws -> Data {
        let list: [String: Any] = [
            "Label": label,
            "ProgramArguments": [nodePath, mainPath],
            "KeepAlive": true,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        return try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
    }
}

/// The user unit: the absolute Node.js path, because a user unit's `PATH` holds
/// only system directories, and a restart whenever it stops. A Helper that
/// cannot even start, for example after Node.js moved, hits the start limit
/// within seconds and ends failed for good, which Host detail shows.
enum HostHelperUnit {
    static func text(nodePath: String, mainPath: String) -> String {
        """
        [Unit]
        Description=Heeler Host Helper
        StartLimitIntervalSec=10
        StartLimitBurst=5

        [Service]
        ExecStart=\(argument(nodePath)) \(argument(mainPath))
        Restart=always
        RestartSec=1

        [Install]
        WantedBy=default.target

        """
    }

    /// A word of `ExecStart`: systemd's own quoting, and `%` and `$` escaped
    /// because it would expand them.
    private static func argument(_ word: String) -> String {
        let escaped = word
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "$", with: "$$")
        return "\"\(escaped)\""
    }
}
