import Foundation

/// The read that explains why SSH would not open a Rex server's socket
/// (ADR 0049). SSH, through libssh2, reports a missing socket, one nothing
/// listens on, and an SSH server that forbids socket forwarding with the same
/// error, and only the last needs the user to change the SSH server. Pure: it
/// builds a script for one bounded exec and reads what it prints.
///
/// The script only tests the file and lists the Host's Unix sockets: Linux's
/// `/proc/net/unix` and macOS's `netstat` report listening stream sockets.
/// Darwin keeps the bind spelling and exposes SO_ACCEPTCONN as bit 0x0002.
/// Darwin leaves an unlinked listener in its table. A local datagram lookup
/// checks which endpoint the pathname reaches without queueing a stream
/// connection or sending data. Neither probe runs Rex.
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
                    case "$p" in
                        /private/*) other=${p#/private} ;;
                        *) other=/private$p ;;
                    esac
                    [ "$p" -ef "$other" ] || other=$p
                    state=$({ LC_ALL=C netstat -anv -f unix && echo complete; } | LC_ALL=C awk -v path="$p" -v other="$other" '
                        $1 == "Address" && $NF == "Addr" {
                            for (i = 1; i < NF; i++) if ($i == "options") options = i
                            after = NF - options - 1
                            next
                        }
                        $0 == "complete" { complete = 1 }
                        $2 == "stream" && $6 == "0" && options && match($0, "[[:space:]]/") {
                            name = substr($0, RSTART + 1)
                            if (name != path && name != other) next
                            $0 = substr($0, 1, RSTART - 1)
                            # Count back from the address because a process name may contain spaces.
                            flags = $(NF - after)
                            if (flags !~ /^[[:xdigit:]]+$/) next
                            if (flags ~ /[2367abefABEF]$/) listening = 1
                            else bound = 1
                        }
                        END {
                            # An unconnected bound stream can coexist with an unlinked listener at the same address.
                            if (options && complete) print listening ? (bound ? "ambiguous" : "candidate") : "idle"
                        }
                    ')
                    case "$state" in
                        idle) echo idle ;;
                        candidate|ambiguous)
                            # A listener can keep its old address after unlink. Check the vnode at the requested path.
                            /usr/bin/perl -MSocket -MErrno=EPROTOTYPE,ECONNREFUSED,ENOENT,ENOTSOCK -e '
                                socket(my $probe, AF_UNIX, SOCK_DGRAM, 0) or exit;
                                if (connect($probe, sockaddr_un($ARGV[0]))) { print "idle" }
                                elsif ($! == EPROTOTYPE) { print "listening" if $ARGV[1] eq "candidate" }
                                elsif ($! == ENOENT) { print "missing" }
                                elsif ($! == ECONNREFUSED || $! == ENOTSOCK) { print "idle" }
                            ' "$p" "$state"
                            ;;
                    esac
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
