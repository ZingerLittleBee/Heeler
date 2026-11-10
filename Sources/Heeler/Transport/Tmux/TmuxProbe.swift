import Foundation

/// The one script that reads a tmux Host (ADR 0042): where tmux is, its version,
/// and whether a server answers on a socket. Pure: it builds a script for one
/// bounded exec and reads what the script prints.
///
/// Every tmux command it runs carries `-N` and `-S`, so nothing here starts a
/// server, whatever the user's configuration says. A server "answers" when a
/// client's `display-message` comes back from it: a socket file a killed server
/// left behind does not.
///
/// `scripts/test-tmux-probe.py` runs the script through real shells.
enum TmuxProbe {
    /// The output was cut short or does not read as this script's.
    struct MalformedOutput: Error, Equatable {}

    enum Request: Equatable, Sendable {
        /// Through the login shell: find tmux and list the sockets in the user's
        /// tmux directory that a server answers on.
        case sockets
        /// Through the login shell: find tmux and the socket this name resolves
        /// to, and ask that socket's server.
        case resolve(socketName: String)
        /// With paths resolved earlier and no startup file in between.
        case stored(executable: String, socket: String)
    }

    /// What one run printed, before anyone decides what it means.
    struct Report: Equatable, Sendable {
        /// `uname -s`.
        var kernel: String?
        /// `$SHELL` in the exec that asked, which for a stored-path probe is the
        /// account's shell. Empty when the environment had none.
        var shell: String?
        /// The absolute path of an executable named tmux, if there is one.
        var executable: String?
        /// The first line of `tmux -V`.
        var versionLine: String?
        /// The user's tmux directory, where `-L` sockets live. Not read for
        /// stored paths, which name their socket outright.
        var directory: String?
        /// The sockets in `directory` a server answers on, for `.sockets`.
        var sockets: [String] = []
        /// The server that answered on the asked socket.
        var server: TmuxServerInstance?
    }

    /// The most sockets one detection asks. A directory holds a handful.
    static let socketLimit = 32
    /// How long one server gets to answer before its socket counts as silent.
    static let answerSeconds = 5

    /// A script for `/bin/sh`. Through the login shell, the script itself runs in
    /// a child `/bin/sh` of the user's interactive login shell, with the `PATH`
    /// and `TMUX_TMPDIR` its startup files set: the one line that shell runs
    /// parses under POSIX shells and fish alike. A shell that cannot run it
    /// leaves the exec's own environment to answer.
    static func script(_ request: Request, nonce: String) -> String {
        let body = body(request, nonce: nonce)
        guard request.runsThroughLoginShell else { return body }
        return """
            __heeler_tmux_probe=\(quoted(body))
            export __heeler_tmux_probe
            "${SHELL:-/bin/sh}" -lic 'exec /bin/sh -c "$__heeler_tmux_probe"' </dev/null 2>/dev/null \\
                || /bin/sh -c "$__heeler_tmux_probe" </dev/null 2>/dev/null

            """
    }

    private static func body(_ request: Request, nonce: String) -> String {
        let executable: String
        let socket: String
        let name: String
        switch request {
        case .sockets: (executable, socket, name) = ("", "", "")
        case .resolve(let socketName): (executable, socket, name) = ("", "", socketName)
        case .stored(let path, let socketPath): (executable, socket, name) = (path, socketPath, "")
        }
        return """
            t=\(quoted(executable))
            s=\(quoted(socket))
            n=\(quoted(name))
            printf '\\n%s\\n' \(quoted(beginMarker(nonce)))
            printf 'kernel %s\\n' "$(uname -s 2>/dev/null)"
            printf 'shell %s\\n' "${SHELL:-}"
            [ -n "$t" ] || t=$(command -v tmux 2>/dev/null)
            case $t in
            /*) [ -f "$t" ] && [ -x "$t" ] || t= ;;
            *) t= ;;
            esac
            answer() {
                (
                    "$t" -N -S "$1" display-message -p '#{pid} #{start_time}' 2>/dev/null </dev/null &
                    p=$!
                    ( sleep \(answerSeconds); kill -KILL "$p" ) >/dev/null 2>&1 </dev/null &
                    w=$!
                    wait "$p"
                    c=$?
                    kill "$w" >/dev/null 2>&1
                    exit "$c"
                )
            }
            if [ -n "$t" ]; then
                printf 'executable %s\\n' "$t"
                printf 'version %s\\n' "$("$t" -V 2>/dev/null </dev/null | sed -n 1p)"
            fi
            if [ -z "$s" ]; then
                b=$(cd "${TMUX_TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || b=$(cd /tmp 2>/dev/null && pwd -P) || b=/tmp
                d=${b%/}/tmux-$(id -u)
                r=$(cd "$d" 2>/dev/null && pwd -P) && d=$r
                printf 'directory %s\\n' "$d"
                [ -z "$n" ] || s=$d/$n
            fi
            if [ -n "$t" ] && [ -n "$s" ]; then
                i=$(answer "$s") && printf 'instance %s\\n' "$i"
            elif [ -n "$t" ]; then
                c=0
                for f in "$d"/*; do
                    [ -S "$f" ] || continue
                    c=$((c + 1))
                    [ "$c" -le \(socketLimit) ] || break
                    answer "$f" >/dev/null && printf 'socket %s\\n' "${f##*/}"
                done
            fi
            printf '\\n%s\\n' \(quoted(endMarker(nonce)))
            exit 0

            """
    }

    /// Reads only what lies between the last pair of markers: startup files
    /// never reach it, and a login shell that gave up partway is followed by the
    /// exec's own answer.
    static func parse(stdout: Data, nonce: String) throws -> Report {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let end = lines.lastIndex(of: endMarker(nonce)),
            let begin = lines[..<end].lastIndex(of: beginMarker(nonce))
        else { throw MalformedOutput() }
        var report = Report()
        for line in lines[(begin + 1)..<end] {
            func value(_ key: String) -> String? {
                guard line.hasPrefix(key + " ") else { return nil }
                let value = String(line.dropFirst(key.count + 1))
                return value.isEmpty ? nil : value
            }
            if let kernel = value("kernel") {
                report.kernel = kernel
            } else if let shell = value("shell") {
                report.shell = shell
            } else if let executable = value("executable") {
                report.executable = executable
            } else if let version = value("version") {
                report.versionLine = version
            } else if let directory = value("directory") {
                report.directory = directory
            } else if let socket = value("socket") {
                // A file name Heeler could not name back to tmux is not offered.
                if TmuxSocketName.isValid(socket), !report.sockets.contains(socket) { report.sockets.append(socket) }
            } else if let instance = value("instance") {
                let fields = instance.split(separator: " ")
                if fields.count == 2, let pid = Int(fields[0]), let startTime = Int(fields[1]) {
                    report.server = TmuxServerInstance(pid: pid, startTime: startTime)
                }
            }
        }
        return report
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func beginMarker(_ nonce: String) -> String { "\(nonce) tmux begin" }
    private static func endMarker(_ nonce: String) -> String { "\(nonce) tmux end" }
}

extension TmuxProbe.Request {
    var runsThroughLoginShell: Bool {
        switch self {
        case .sockets, .resolve: true
        case .stored: false
        }
    }
}

/// Whether a Host has a tmux Heeler can use, as a probe read it.
enum TmuxInstallation: Equatable, Sendable {
    /// No executable named tmux, or one that does not say it is tmux.
    case notInstalled
    /// Older than `TmuxVersion.minimum`.
    case updateRequired(version: String)
    case usable(executable: String, version: String)
}

extension TmuxProbe.Report {
    var installation: TmuxInstallation {
        guard let executable, let versionLine, let version = TmuxVersion(versionLine: versionLine) else {
            return .notInstalled
        }
        return version.isSupported
            ? .usable(executable: executable, version: version.text) : .updateRequired(version: version.text)
    }

    /// Where the socket of this name is, for a probe that read the directory.
    func socketPath(named name: String) -> String? {
        directory.map { "\($0)/\(TmuxSocketName.normalized(name))" }
    }
}
