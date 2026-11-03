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
    /// What a Unix Host's `uname -s` prints as `kernel` on Linux.
    static let linuxKernel = "Linux"
    /// As `linuxKernel`, on macOS.
    static let macOSKernel = "Darwin"
    /// What the Windows probe prints as `kernel`, which no `uname -s` said.
    static let windowsKernel = "Windows"

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

        /// `uname -s` on Unix, `windowsKernel` on native Windows.
        let kernel: String
        /// Absolute. Nil when neither place holds a program that identifies
        /// itself as the core, which reads as not installed.
        let executablePath: String?
        /// Absolute. A native Windows Host's installer path holds a file that did
        /// not say what it is: the core is there, and this read could not ask it.
        var unansweredExecutablePath: String? = nil
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
        /// The user's home folder. Only native Windows reports it here, where
        /// `HostServices.hostHomeDirectory` refuses to answer.
        var home: String?

        var fitsSocketPathLimit: Bool { socketPath.utf8.count <= socketPathLimit }
        var isNativeWindows: Bool { kernel == windowsKernel }
        var isStaleLock: Bool { socketSource == .lock && !socketFilePresent }
        /// Only on Linux can the app start a core: elsewhere one started over
        /// SSH would run outside the user's desktop login session.
        var appMayStartCore: Bool { kernel == linuxKernel }
    }

    /// `sun_path` less its NUL: 107 bytes on Linux, 103 on macOS. A kernel the
    /// app has no record of gets the shorter limit. A Windows pipe name may run to 256.
    static func socketPathLimit(kernel: String) -> Int {
        switch kernel {
        case linuxKernel: 107
        case windowsKernel: 256
        default: 103
        }
    }

    /// Everything from the Host is a quoted word or a variable, so a session
    /// name can never become shell syntax. `nonce` frames the output, whose
    /// begin marker starts its own line after whatever the user's shell printed.
    /// A `core.lock` holding a line break is reported as a field the parser
    /// refuses, so its contents can never read as fields of their own.
    static func script(session: String, nonce: String) throws -> Data {
        guard HerdrCoreSessionName.isValid(session) else { throw SessionRefused(session: session) }
        let name = HerdrCoreSessionName.normalized(session)
        return Data(
            """
            __session=\(quoted(name))
            __nl='
            '
            printf '\\n%s begin\\n' \(quoted(nonce))
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
            case "$__lock" in *"$__nl"*) printf 'lock-unreadable\\n'; __lock= ;; esac
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

    /// Reads only what lies between the markers: the user's shell runs its
    /// startup and logout files around the script, and they may print anything,
    /// in any encoding. A read that lacks either marker was cut short.
    static func parse(stdout: Data, nonce: String) throws -> Location {
        let rawLines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard let begin = rawLines.firstIndex(where: { $0.elementsEqual("\(nonce) begin".utf8) }),
            let end = rawLines.lastIndex(where: { $0.elementsEqual("\(nonce) end".utf8) }), begin < end
        else { throw MalformedOutput() }
        let lines = try rawLines[(begin + 1)..<end].map { line in
            guard let text = String(data: line, encoding: .utf8) else { throw MalformedOutput() }
            return text
        }

        var fields: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard
                ["kernel", "executable", "present", "version", "default", "lock", "socket-file", "shell", "home"]
                    .contains(key),
                fields[key] == nil
            else { throw MalformedOutput() }
            fields[key] = parts.count == 2 ? String(parts[1]) : ""
        }

        guard let defaultPath = fields["default"], !defaultPath.isEmpty, let kernel = fields["kernel"],
            let socketFile = fields["socket-file"], ["0", "1"].contains(socketFile)
        else { throw MalformedOutput() }
        let executable = fields["executable"]
        let present = fields["present"]
        let isAbsolute =
            executable.map {
                kernel == windowsKernel ? RemoteHostPath.isWindowsAbsolute($0) : $0.hasPrefix("/")
            } ?? true
        let presentIsAbsolute = present.map { kernel == windowsKernel && RemoteHostPath.isWindowsAbsolute($0) } ?? true
        guard isAbsolute, presentIsAbsolute, executable == nil || present == nil,
            (executable == nil) == (fields["version"] == nil)
        else {
            throw MalformedOutput()
        }
        return Location(
            kernel: kernel,
            executablePath: executable,
            unansweredExecutablePath: present,
            version: fields["version"],
            socketPath: fields["lock"] ?? defaultPath,
            socketSource: fields["lock"] == nil ? .sessionDefault : .lock,
            socketFilePresent: socketFile == "1",
            socketPathLimit: socketPathLimit(kernel: kernel),
            loginShell: fields["shell"],
            home: fields["home"])
    }

    /// An exec the Host's shutdown or session cleanup ended partway: killed by a
    /// signal, ended from outside on Windows, with nothing printed, or with a begin
    /// marker and no end. That says nothing about this Host's core, as a shell's own
    /// failure or output that is not this script's does. A negative status is a
    /// Windows NTSTATUS read as signed, such as `0xC000013A`; POSIX has none. A plain
    /// 1 stays a failure, since `taskkill /f` and PowerShell's own failure both print it.
    static func wasCutShort(stdout: Data, exitStatus: Int32, nonce: String) -> Bool {
        if exitStatus > 128 || exitStatus < 0 { return true }
        guard exitStatus == 0 else { return false }
        if stdout.isEmpty { return true }
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        return lines.contains { $0.elementsEqual("\(nonce) begin".utf8) }
            && !lines.contains { $0.elementsEqual("\(nonce) end".utf8) }
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
