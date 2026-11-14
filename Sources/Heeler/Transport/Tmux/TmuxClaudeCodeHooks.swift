import Foundation

/// Heeler's Claude Code hook script on a tmux Host (ADR 0046). It sits in
/// Heeler's own folder under the Host's data home, apart from the Host Helper,
/// beside the settings a launch passes with `--settings`. It runs the tmux the
/// Host stores, which it reads where the Helper's extensions do:
/// `<Helper dir>/tmux/<socket name>/paths.json`, the paths the app resolved
/// (ADR 0044). Placing the script writes that file too, so status works on a
/// Host without the Helper.
///
/// Pure: it builds the two scripts and reads what they print. The data home
/// comes from the Helper's own `locate` script, so the folders are the ones the
/// Helper and its extensions use.
enum TmuxClaudeCodeHooks {
    /// The folder resource the app carries the script in.
    static let resourceName = "claude-code"

    struct File: Equatable, Sendable {
        let path: String
        let contents: Data
    }

    enum LoadError: Error, Equatable {
        case missing
    }

    static func bundledScript(from bundle: Bundle = .main) throws -> Data {
        guard
            let url = bundle.url(forResource: resourceName, withExtension: nil)?
                .appendingPathComponent(ClaudeCodeHooks.scriptName),
            let data = try? Data(contentsOf: url)
        else { throw LoadError.missing }
        return data
    }

    // MARK: Where

    static func locateScript(nonce: String) -> Data {
        Data(HostHelperScript(.locate, nonce: nonce).text.utf8)
    }

    static func locations(stdout: Data, nonce: String) throws -> HostHelperProbe.Locations {
        try HostHelperProbe.parseLocations(HostHelperProbe.framedLines(stdout: stdout, nonce: nonce))
    }

    /// The stored paths for the server on `paths.socket`, where the Helper keeps them.
    static func storedPathsFile(dataHome: String, paths: TmuxPaths) -> String {
        let name = (paths.socket as NSString).lastPathComponent
        return RemoteFilePath.join(dataHome, HostHelperScript.helperDirectorySuffix, "tmux", name, "paths.json")
    }

    // MARK: What

    /// The script, the settings a launch passes, and the stored paths.
    static func files(script: Data, paths: TmuxPaths, dataHome: String) -> [File] {
        let scriptPath = ClaudeCodeHooks.scriptPath(dataHome: dataHome)
        return [
            File(path: scriptPath, contents: script),
            File(
                path: ClaudeCodeHooks.launchSettingsPath(dataHome: dataHome),
                contents: ClaudeCodeHooks.launchSettings(script: scriptPath)),
            File(path: storedPathsFile(dataHome: dataHome, paths: paths), contents: storedPaths(paths)),
        ]
    }

    static func storedPaths(_ paths: TmuxPaths) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(paths)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// One exec that writes each file whole: a private temporary file renamed
    /// into place, under folders it makes private where they are missing. A file
    /// whose last line has no newline gets one, as a here-document gives it.
    static func placeScript(_ files: [File], nonce: String) -> Data {
        let quote = HostHelperScript.quote
        let delimiter = "__HEELER_FILE_\(nonce)"
        let folders = Array(Set(files.map { ($0.path as NSString).deletingLastPathComponent })).sorted()
        var lines = [
            "printf '%s begin\\n' \(quote(nonce))",
            "umask 077",
            "__h_put() {",
            "  __h_tmp=\"$1.tmp-\(nonce)\"",
            "  if cat > \"$__h_tmp\" && mv -f -- \"$__h_tmp\" \"$1\"; then return 0; fi",
            "  rm -f -- \"$__h_tmp\"",
            "  return 1",
            "}",
            "__h_place() {",
            "  mkdir -p -- \(folders.map(quote).joined(separator: " ")) || return 1",
        ]
        for file in files {
            var text = String(decoding: file.contents, as: UTF8.self)
            if !text.hasSuffix("\n") { text += "\n" }
            lines.append("  __h_put \(quote(file.path)) <<'\(delimiter)' || return 1")
            lines.append(text + delimiter)
        }
        lines += [
            "}",
            "__h_place",
            "__h_status=$?",
            "printf '%s end\\n' \(quote(nonce))",
            "exit \"$__h_status\"",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Whether every file is in place: the script ran to its end, and said so.
    static func isPlaced(_ result: GitExecResult, nonce: String) -> Bool {
        result.exitStatus == 0 && (try? HostHelperProbe.framedLines(stdout: result.stdout, nonce: nonce)) != nil
    }

    // MARK: A launch

    /// The variable that points Claude Code at a configuration root.
    static let rootVariable = "CLAUDE_CONFIG_DIR"

    /// The root an Agent launched with `environment` reads: its own variable's,
    /// or the default under `home`. Nil when that names no absolute path.
    static func root(environment: [String: String], home: String) -> String? {
        guard let root = environment[rootVariable], !root.isEmpty else {
            return RemoteFilePath.join(home, ".claude")
        }
        return root.hasPrefix("/") ? root : nil
    }
}
