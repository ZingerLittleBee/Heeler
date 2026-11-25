import Foundation

/// The read that finds a Rex server on a macOS or Linux Host by its socket,
/// and on a native Windows Host by its named pipe (ADR 0049). Pure: it builds a script for one bounded exec and reads what
/// the script prints.
///
/// It never runs `rex`: the command-line tool is often missing from the PATH
/// of a non-interactive shell, and some of its commands start a server. It
/// only tests files: whether each place a server listens holds a socket,
/// whether the account owns it and may read and write it, and whether Rex
/// looks installed. A socket file says a server listened there; only a hello
/// over it can prove one still does.
///
/// `scripts/test-server-kind-detection.py` runs the script through real shells.
enum RexProbe {
    /// The output was cut short or does not read as this script's.
    struct MalformedOutput: Error, Equatable {}

    struct Socket: Equatable, Sendable {
        let path: String
        /// Owned by the account that asked, as a personal server's is.
        let isOwn: Bool
        /// The account may read and write it, which connecting takes.
        let isUsable: Bool
    }

    /// What one run printed, before anyone decides what it means.
    struct Report: Equatable, Sendable {
        /// `uname -s`.
        var kernel: String?
        /// A Rex app, named in its bundle, or Rex's own data folder is
        /// there (on Windows, `%LOCALAPPDATA%\rex`). A `rex` on the exec's PATH is not enough: other software
        /// has a command of that name.
        var isInstalled = false
        /// The sockets found, in the order the script looks: the account's own
        /// server before a shared one.
        var sockets: [Socket] = []

        /// The socket a Host would connect to: the first the account may use,
        /// preferring one it owns, among the paths `isNamed` accepts.
        func preferredSocket(where isNamed: (String) -> Bool = { _ in true }) -> Socket? {
            let usable = sockets.filter { $0.isUsable && isNamed($0.path) }
            return usable.first(where: \.isOwn) ?? usable.first
        }
    }

    /// A script for `/bin/sh`, run in the exec's own environment. Rex keeps a
    /// personal server's socket in the account's Application Support on macOS
    /// and under its runtime directory on Linux, where a shared server listens
    /// in `/run/rex`. The root-only login server is never one of them.
    ///
    /// It is one subshell with nothing on standard input, so it may follow
    /// other parts of a script the shell is still reading there.
    static func script(nonce: String) -> String {
        """
        (
        printf '\\n%s\\n' \(quoted(beginMarker(nonce)))
        k=$(uname -s 2>/dev/null)
        printf 'kernel %s\\n' "$k"
        u=$(id -u 2>/dev/null)
        look() {
            case $1 in
            /*) ;;
            *) return 0 ;;
            esac
            case $1 in
            *'
        '*) return 0 ;;
            esac
            [ -S "$1" ] || return 0
            o=0
            [ -n "$u" ] && [ "$(ls -ln "$1" 2>/dev/null | awk 'NR == 1 { print $3 }')" = "$u" ] && o=1
            w=0
            [ -r "$1" ] && [ -w "$1" ] && w=1
            printf 'socket %s %s %s\\n' "$o" "$w" "$1"
        }
        case $k in
        Darwin)
            look "$HOME/Library/Application Support/rex/server.sock"
            # The data folder by its exact name, which a case-insensitive
            # volume would also match in another app's capitalized one.
            for d in "$HOME/Library/Application Support"/[r]ex; do
                [ -d "$d" ] && printf 'installed\\n'
            done
            for a in /Applications/Rex*.app "$HOME"/Applications/Rex*.app; do
                grep -q 'com\\.superlogical\\.rex' "$a/Contents/Info.plist" 2>/dev/null && printf 'installed\\n'
            done
            ;;
        Linux)
            [ -z "${REX_RUNTIME_DIR:-}" ] || look "$REX_RUNTIME_DIR/server.sock"
            [ -z "${XDG_RUNTIME_DIR:-}" ] || look "$XDG_RUNTIME_DIR/rex/server.sock"
            look "/run/user/$u/rex/server.sock"
            look "$HOME/.local/state/rex/run/server.sock"
            look /run/rex/server.sock
            look /var/run/rex/server.sock
            [ -d "$HOME/.local/state/rex" ] && printf 'installed\\n'
            ;;
        esac
        printf '\\n%s\\n' \(quoted(endMarker(nonce)))
        ) </dev/null 2>/dev/null

        """
    }

    /// The Windows read, for PowerShell after `HerdrCoreLocator.windowsPrelude`.
    /// Rex names a personal server's pipe `rex-` and the account's SID. The
    /// read lists the pipe namespace by name, which opens no pipe, so the
    /// server sees no client and a busy pipe still counts. Rex looks installed
    /// when its data folder, `%LOCALAPPDATA%\rex`, is there, as on the Unix
    /// side; `rex.exe` on the exec's PATH, which the bridge needs
    /// (`RexWindowsDial`), is what makes a found pipe usable. It never runs
    /// `rex`. Everything from outside is a single-quoted literal.
    static func windowsBody(nonce: String) -> String {
        #"""
        say ''
        say \#(PowerShellCommand.literal(beginMarker(nonce)))
        say 'kernel \#(HerdrCoreLocator.windowsKernel)'
        if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'rex') -PathType Container)) { say 'installed' }
        $rexOk = 0; if (Get-Command rex.exe -CommandType Application) { $rexOk = 1 }
        $rexSid = $null; try { $rexSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
        if ($rexSid -match '^S-[0-9-]+$') {
            $rexPipe = 'rex-' + $rexSid
            $rexPipes = $null; try { $rexPipes = [IO.Directory]::GetFiles('\\.\pipe\') } catch { }
            if ($null -eq $rexPipes) { $rexPipes = Get-ChildItem -LiteralPath '\\.\pipe\' -Name }
            if ($rexPipes | Where-Object { ($_ -replace '^\\\\\.\\pipe\\', '') -ceq $rexPipe }) { say ('socket 1 ' + $rexOk + ' \#(windowsPipePrefix)' + $rexPipe) }
        }
        say ''
        say \#(PowerShellCommand.literal(endMarker(nonce)))
        """#
    }

    /// The prefix Rex gives a named pipe's address.
    static let windowsPipePrefix = "npipe:////./pipe/"

    /// Only the name Rex gives a personal server's pipe, `rex-` and the
    /// account's SID, so the address goes on a command line unquoted.
    static func isWindowsPipeAddress(_ path: String) -> Bool {
        guard path.hasPrefix(windowsPipePrefix) else { return false }
        let name = path.dropFirst(windowsPipePrefix.count)
        guard name.hasPrefix("rex-"), name.count > 4, name.count <= 200 else { return false }
        return name.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Reads only what lies between the last pair of markers. A path is taken
    /// once, where the script first found it.
    static func parse(stdout: Data, nonce: String) throws -> Report {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let end = lines.lastIndex(of: endMarker(nonce)),
            let begin = lines[..<end].lastIndex(of: beginMarker(nonce))
        else { throw MalformedOutput() }
        var report = Report()
        for line in lines[(begin + 1)..<end] {
            if line == "installed" {
                report.isInstalled = true
            } else if line.hasPrefix("kernel ") {
                let kernel = String(line.dropFirst("kernel ".count))
                report.kernel = kernel.isEmpty ? nil : kernel
            } else if line.hasPrefix("socket ") {
                let fields = line.dropFirst("socket ".count).split(
                    separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let own = flag(fields[0]), let usable = flag(fields[1]) else { continue }
                let path = String(fields[2])
                guard path.hasPrefix("/") || isWindowsPipeAddress(path),
                    !report.sockets.contains(where: { $0.path == path }) else { continue }
                report.sockets.append(Socket(path: path, isOwn: own, isUsable: usable))
            }
        }
        return report
    }

    private static func flag(_ field: Substring) -> Bool? {
        switch field {
        case "1": true
        case "0": false
        default: nil
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func beginMarker(_ nonce: String) -> String { "\(nonce) rex begin" }
    private static func endMarker(_ nonce: String) -> String { "\(nonce) rex end" }
}
