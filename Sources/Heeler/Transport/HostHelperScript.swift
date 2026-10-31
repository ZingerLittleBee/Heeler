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
        case enableLinger(user: String)
        case removeFiles([String])
        /// Removes each folder that is empty, in the order given.
        case removeEmptyFolders([String])
        case removeTree(String)
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
        case .makeFolders(let folders, let privateFolder):
            lines = ["umask 077"]
                + folders.map { folder in
                    let path = quote(folder)
                    return "if [ ! -d \(path) ]; then mkdir -- \(path) || exit 1; "
                        + "printf 'created %s\\n' \(path); fi"
                }
                // Paths are absolute, and BSD chmod takes no `--`.
                + ["chmod 700 \(quote(privateFolder)) || exit 1"]
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
        case .enableLinger(let user):
            // Never waits on an administrator's password: a refusal comes back.
            lines = ["LC_ALL=C; export LC_ALL", "loginctl --no-ask-password enable-linger \(quote(user))"]
        case .removeFiles(let files):
            lines = files.isEmpty ? [":"] : ["rm -f -- \(files.map(quote).joined(separator: " "))"]
        case .removeEmptyFolders(let folders):
            lines = folders.isEmpty ? [":"] : folders.map { "rmdir -- \(quote($0)) 2>/dev/null || :" }
        case .removeTree(let path):
            lines = ["rm -rf -- \(quote(path))"]
        }
        return (["printf '%s begin\\n' \(quote(nonce))"] + lines
            + ["__h_status=$?", "printf '%s end\\n' \(quote(nonce))", "exit \"$__h_status\""])
            .joined(separator: "\n") + "\n"
    }

    private static let locations = [
        "case \"$XDG_DATA_HOME\" in /*) __h_data=\"$XDG_DATA_HOME\";; *) __h_data=\"$HOME/.local/share\";; esac",
        "case \"$XDG_CONFIG_HOME\" in /*) __h_config=\"$XDG_CONFIG_HOME\";; *) __h_config=\"$HOME/.config\";; esac",
        "printf 'home %s\\n' \"$HOME\"",
        "printf 'data %s\\n' \"$__h_data\"",
        "printf 'config %s\\n' \"$__h_config\"",
    ]

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
        "printf 'kernel %s\\n' \"$(uname -s)\"",
        "__h_user=$(id -un)",
        "printf 'user %s\\n' \"$__h_user\"",
    ] + locations + [
        "( \(NodeToolchainProbe.nodeOnlyScript) )",
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

/// A user unit's state as `systemctl show` gives it.
struct HostHelperHealth: Sendable, Equatable {
    var loadState: String
    var activeState: String
    var result: String
    var restarts: Int

    /// Running, or between two runs of a restart that may yet work.
    var isUp: Bool { activeState == "active" || activeState == "activating" || activeState == "reloading" }
    var isLoaded: Bool { loadState == "loaded" }
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
    var locations: Locations
    var node = Node.missing
    var lingerOn = false
    var hasSystemd = true
    /// Nil when systemd's user manager could not be reached.
    var health: HostHelperHealth?
    var appPresent = false
    var manifest: Data?
    var record: Data?
    var hashToolMissing = false
    var hashes: [String: String] = [:]

    struct Locations: Sendable, Equatable {
        var home: String
        var dataHome: String
        var configHome: String
    }

    struct Unreadable: Error, Equatable {}

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
        for line in lines {
            let (key, value) = Self.split(line)
            switch key {
            case "kernel": kernel = value
            case "user": user = value
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
    }

    private static func split(_ line: String) -> (key: String, value: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    private static func bytes(hex: String) -> Data? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
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
