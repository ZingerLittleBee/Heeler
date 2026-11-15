import Foundation

/// The read that explains why SSH would not open a Rex server's socket
/// (ADR 0049). SSH, through libssh2, reports a missing socket, one nothing
/// listens on, and an SSH server that forbids socket forwarding with the same
/// error, and only the last needs the user to change the SSH server. Pure: it
/// builds a script for one bounded exec and reads what it prints.
///
/// The script only tests the file and lists the Host's Unix sockets: Linux's
/// `/proc/net/unix` shows which are listening, and on macOS `lsof` shows the
/// account's own processes holding one at that path. It runs nothing of Rex's.
enum RexSocketCheck {
    enum Answer: Equatable, Sendable {
        /// No socket file at the path.
        case missing
        /// The file is there and nothing listens on it: a server stopped or crashed.
        case notListening
        /// A server listens on it.
        case listening
        /// The Host could not say.
        case unknown
    }

    /// A script for `/bin/sh`, or nil for a path this build cannot quote.
    static func script(socketPath: String, nonce: String) -> String? {
        guard let path = RemoteShellPath.quotedAbsolute(socketPath) else { return nil }
        return """
            (
            p=\(path)
            printf '\\n%s\\n' '\(beginMarker(nonce))'
            if [ ! -S "$p" ]; then
                printf 'missing\\n'
            else
                case $(uname -s 2>/dev/null) in
                Linux)
                    if [ -r /proc/net/unix ]; then
                        if awk -v p="$p" '$4 == "00010000" && substr($0, length($0) - length(p)) == " " p { f = 1 } END { exit !f }' /proc/net/unix; then
                            printf 'listening\\n'
                        else
                            printf 'idle\\n'
                        fi
                    fi
                    ;;
                Darwin)
                    if command -v lsof >/dev/null 2>&1; then
                        if lsof -nP -U -F n 2>/dev/null | grep -Fqx "n$p"; then
                            printf 'listening\\n'
                        else
                            printf 'idle\\n'
                        fi
                    fi
                    ;;
                esac
            fi
            printf '\\n%s\\n' '\(endMarker(nonce))'
            ) </dev/null 2>/dev/null

            """
    }

    /// Reads only what lies between the last pair of markers.
    static func parse(stdout: Data, nonce: String) -> Answer {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let end = lines.lastIndex(of: endMarker(nonce)),
            let begin = lines[..<end].lastIndex(of: beginMarker(nonce))
        else { return .unknown }
        for line in lines[(begin + 1)..<end] {
            switch line {
            case "missing": return .missing
            case "idle": return .notListening
            case "listening": return .listening
            default: continue
            }
        }
        return .unknown
    }

    private static func beginMarker(_ nonce: String) -> String { "\(nonce) rex-socket begin" }
    private static func endMarker(_ nonce: String) -> String { "\(nonce) rex-socket end" }
}
