import Foundation

/// Finds a Host's core without starting one (ADR 0031). Pure: it builds one
/// read-only script, which a caller runs in one bounded exec, and parses what
/// the script prints.
///
/// The script runs only `herdr-core --version`, which exits while parsing its
/// arguments, never `hc` by that name: the installer links `hc` only when no
/// other program owns the name, and every other subcommand can start a core.
/// It keeps the exec's PATH as it is.
enum HerdrCoreLocator {
    /// hc refuses this session name, so no script exists for it.
    struct SessionRefused: Error, Equatable {
        let session: String
    }

    /// The output was cut short or does not read as this script's.
    struct MalformedOutput: Error, Equatable {}

    struct Location: Equatable, Sendable {
        enum SocketSource: Equatable, Sendable {
            /// The path the session's `core.lock` names. It outlives its core.
            case lock
            /// No `core.lock` names a path yet: where the session's core would bind.
            case sessionDefault
        }

        /// Absolute. Nil when neither place holds a program that identifies
        /// itself as the core, which reads as not installed.
        let executablePath: String?
        /// As `--version` reports it. Advisory: a core other than the one this
        /// build was tested with still connects if `hello` passes.
        let version: String?
        let socketPath: String
        let socketSource: SocketSource
        let socketFilePresent: Bool
        /// The longest socket path this Host's kernel allows.
        let socketPathLimit: Int
        /// The user's login shell from the account database, when it was readable.
        let loginShell: String?

        var fitsSocketPathLimit: Bool { socketPath.utf8.count <= socketPathLimit }
        var isStaleLock: Bool { socketSource == .lock && !socketFilePresent }
    }

    /// `sun_path` less its NUL: 107 bytes on Linux, 103 on macOS. A kernel the
    /// app has no record of gets the shorter limit.
    static func socketPathLimit(kernel: String) -> Int {
        kernel == "Linux" ? 107 : 103
    }

    /// Everything from the Host is a quoted word or a variable, so a session
    /// name can never become shell syntax. `nonce` frames the output.
    static func script(session: String, nonce: String) throws -> Data {
        guard HerdrCoreSessionName.isValid(session) else { throw SessionRefused(session: session) }
        let name = HerdrCoreSessionName.normalized(session)
        return Data(
            """
            __session=\(quoted(name))
            __nl='
            '
            printf '%s begin\\n' \(quoted(nonce))
            printf 'kernel %s\\n' "$(uname -s 2>/dev/null)"
            __probe() {
                case "$1" in /*) ;; *) return 1 ;; esac
                [ -x "$1" ] || return 1
                __version=$("$1" --version 2>/dev/null </dev/null) || return 1
                __version=${__version%%"$__nl"*}
                case "$__version" in 'hc '[0-9]*|'herdr-core '[0-9]*) ;; *) return 1 ;; esac
                printf 'executable %s\\n' "$1"
                printf 'version %s\\n' "${__version#* }"
            }
            __candidate=$(command -v herdr-core 2>/dev/null) || __candidate=
            __probe "$__candidate" || __probe "${HOME:-}/.local/bin/herdr-core" || :
            __state=${XDG_STATE_HOME:-${HOME:-}/.local/state}/herdr-core/$__session
            if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
                __run=$XDG_RUNTIME_DIR/herdr-core
            elif [ -d "/run/user/$(id -u)" ]; then
                __run=/run/user/$(id -u)/herdr-core
            else
                __run=$__state
            fi
            __socket=$__run/$__session.sock
            printf 'default %s\\n' "$__socket"
            __lock=
            [ -r "$__state/core.lock" ] && __lock=$(cat "$__state/core.lock" 2>/dev/null)
            if [ -n "$__lock" ]; then
                printf 'lock %s\\n' "$__lock"
                __socket=$__lock
            fi
            if [ -S "$__socket" ]; then printf 'socket-file 1\\n'; else printf 'socket-file 0\\n'; fi
            __user=$(id -un 2>/dev/null)
            __shell=$(getent passwd "$__user" 2>/dev/null | cut -d: -f7)
            if [ -z "$__shell" ] && [ -x /usr/bin/dscl ]; then
                __shell=$(/usr/bin/dscl . -read "/Users/$__user" UserShell 2>/dev/null | sed -n 's/^UserShell: //p')
            fi
            [ -z "$__shell" ] || printf 'shell %s\\n' "$__shell"
            printf '%s end\\n' \(quoted(nonce))
            exit 0
            """.utf8)
    }

    static func parse(stdout: Data, nonce: String) throws -> Location {
        guard let text = String(data: stdout, encoding: .utf8) else { throw MalformedOutput() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2, lines.first == "\(nonce) begin", lines.last == "\(nonce) end" else {
            throw MalformedOutput()
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast() {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard ["kernel", "executable", "version", "default", "lock", "socket-file", "shell"].contains(key),
                fields[key] == nil
            else { throw MalformedOutput() }
            fields[key] = parts.count == 2 ? String(parts[1]) : ""
        }

        guard let defaultPath = fields["default"], !defaultPath.isEmpty, let kernel = fields["kernel"],
            let socketFile = fields["socket-file"], ["0", "1"].contains(socketFile)
        else { throw MalformedOutput() }
        let executable = fields["executable"]
        guard executable?.hasPrefix("/") ?? true, (executable == nil) == (fields["version"] == nil) else {
            throw MalformedOutput()
        }
        return Location(
            executablePath: executable,
            version: fields["version"],
            socketPath: fields["lock"] ?? defaultPath,
            socketSource: fields["lock"] == nil ? .sessionDefault : .lock,
            socketFilePresent: socketFile == "1",
            socketPathLimit: socketPathLimit(kernel: kernel),
            loginShell: fields["shell"])
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
