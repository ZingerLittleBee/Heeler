import Foundation

/// A TCP port a program on the Host listens on, where a connection to the
/// Host's loopback interface reaches it.
struct HostListeningPort: Identifiable, Hashable, Sendable {
    let port: Int
    /// The listening program's name, when the Host tells this account.
    let command: String?
    /// That program's working directory, when the Host tells this account.
    let directory: String?

    var id: Int { port }

    /// Whether the program runs in `directory` or below it: the ports an
    /// Agent's own work most likely opened.
    func isInside(_ directory: String?) -> Bool {
        guard let directory, !directory.isEmpty, let own = self.directory else { return false }
        let root = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return own == root || own.hasPrefix(root + "/")
    }
}

/// Reads what listens on a macOS or Linux Host with the tool it has: `ss` or
/// `lsof`. The script only prints those tools' output between markers; what
/// it means is decided here, where a test can hold the text.
enum HostListeningPorts {
    struct MalformedOutput: Error, Equatable {}

    /// How many ports a list keeps. A Host with more is not one a list helps.
    static let portCap = 200
    private static let outputCap = 262_144

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<12).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    static func beginMarker(_ nonce: String) -> String { "__HEELER_PORTS_BEGIN_\(nonce)" }
    static func directoriesMarker(_ nonce: String) -> String { "__HEELER_PORTS_CWD_\(nonce)" }
    static func endMarker(_ nonce: String) -> String { "__HEELER_PORTS_END_\(nonce)" }

    /// The script. It takes nothing from the caller but the nonce, which is
    /// hexadecimal, so nothing in it needs quoting.
    static func script(nonce: String) -> Data {
        let lines = [
            "LC_ALL=C",
            "PATH=$PATH:/usr/sbin:/sbin",
            "export LC_ALL PATH",
            "exec 2>/dev/null",
            "{",
            "printf '%s\\n' '\(beginMarker(nonce))'",
            "p=",
            "if [ \"$(uname -s)\" = Linux ] && command -v ss >/dev/null; then",
            "printf 'tool ss\\n'",
            "o=$(ss -ltnp)",
            "printf '%s\\n' \"$o\"",
            "p=$(printf '%s\\n' \"$o\" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)",
            "elif command -v lsof >/dev/null; then",
            "printf 'tool lsof\\n'",
            "o=$(lsof +c0 -nP -iTCP -sTCP:LISTEN -Fpcn)",
            "printf '%s\\n' \"$o\"",
            "p=$(printf '%s\\n' \"$o\" | sed -n 's/^p\\([0-9][0-9]*\\)$/\\1/p' | sort -u)",
            "else",
            "printf 'tool none\\n'",
            "fi",
            "printf '%s\\n' '\(directoriesMarker(nonce))'",
            "if [ -n \"$p\" ]; then",
            "if [ -d /proc/self ]; then",
            "for x in $p; do",
            "d=$(readlink \"/proc/$x/cwd\") && printf 'p%s\\nn%s\\n' \"$x\" \"$d\"",
            "done",
            "else",
            "lsof -a -d cwd -p \"$(printf '%s' \"$p\" | tr '\\n' ',')\" -Fpn",
            "fi",
            "fi",
            "printf '\\n%s\\n' '\(endMarker(nonce))'",
            "} | head -c \(outputCap)",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The ports a connection to the Host's loopback interface reaches, by
    /// number. Throws when the markers are missing, which is output cut
    /// short or not this script's.
    static func parse(stdout: Data, nonce: String) throws -> [HostListeningPort] {
        let lines = String(decoding: stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let begin = lines.firstIndex(of: beginMarker(nonce)),
              let middle = lines[begin...].firstIndex(of: directoriesMarker(nonce)),
              let end = lines[middle...].firstIndex(of: endMarker(nonce))
        else { throw MalformedOutput() }
        let listing = Array(lines[(begin + 1)..<middle])
        let directories = Self.directories(in: lines[(middle + 1)..<end])
        let listeners: [Listener]
        switch listing.first {
        case "tool ss": listeners = Self.socketStatisticsListeners(in: listing.dropFirst())
        case "tool lsof": listeners = Self.openFilesListeners(in: listing.dropFirst())
        default: listeners = []
        }

        var ports: [Int: HostListeningPort] = [:]
        for listener in listeners where listener.reachesLoopback {
            let process = listener.processes.first { directories[$0.pid] != nil } ?? listener.processes.first
            let found = HostListeningPort(
                port: listener.port, command: process?.command,
                directory: process.flatMap { directories[$0.pid] })
            // One port often has an IPv4 and an IPv6 listener: keep whichever
            // names its program.
            if let kept = ports[listener.port], kept.command != nil, kept.directory != nil || found.directory == nil {
                continue
            }
            ports[listener.port] = found
        }
        return Array(ports.values.sorted { $0.port < $1.port }.prefix(portCap))
    }

    private struct Listener {
        var address: String
        var port: Int
        var processes: [(pid: Int, command: String)]

        /// Whether a connection to `localhost` on the Host arrives here: a
        /// listener on every interface, or on the loopback address itself.
        /// One bound to another address, a LAN address or `127.0.0.53`, is
        /// not reached that way.
        var reachesLoopback: Bool {
            var name = address
            if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
            return ["*", "0.0.0.0", "::", "127.0.0.1", "::1", "localhost"].contains(name)
        }
    }

    /// `address:port`, split at the last colon: an IPv6 address has its own.
    private static func endpoint(_ text: Substring) -> (address: String, port: Int)? {
        guard let colon = text.lastIndex(of: ":"),
              let port = Int(text[text.index(after: colon)...]),
              (1...65535).contains(port)
        else { return nil }
        return (String(text[..<colon]), port)
    }

    /// `ss -ltnp`: `LISTEN 0 511 *:4100 *:* users:(("node",pid=1234,fd=23))`.
    /// The last field is absent for a program another account runs.
    private static func socketStatisticsListeners(in lines: ArraySlice<String>) -> [Listener] {
        lines.compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5, fields[0] == "LISTEN", let local = endpoint(fields[3]) else { return nil }
            var processes: [(pid: Int, command: String)] = []
            if let users = line.range(of: "users:(") {
                for entry in line[users.upperBound...].components(separatedBy: "(\"").dropFirst() {
                    guard let quote = entry.firstIndex(of: "\""),
                          let marker = entry.range(of: "pid=")
                    else { continue }
                    let digits = entry[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
                    guard let pid = Int(digits) else { continue }
                    processes.append((pid, String(entry[..<quote])))
                }
            }
            return Listener(address: local.address, port: local.port, processes: processes)
        }
    }

    /// `lsof -Fpcn`: a `p` line starts a process, `c` names it, and each `n`
    /// line after is one of its listening sockets.
    private static func openFilesListeners(in lines: ArraySlice<String>) -> [Listener] {
        var listeners: [Listener] = []
        var pid: Int?
        var command = ""
        for line in lines {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                pid = Int(value)
                command = ""
            case "c":
                command = String(value)
            case "n":
                guard let pid, let local = endpoint(value) else { continue }
                listeners.append(Listener(address: local.address, port: local.port, processes: [(pid, command)]))
            default:
                continue
            }
        }
        return listeners
    }

    /// Working directories by process id, from `p` and `n` line pairs.
    private static func directories(in lines: ArraySlice<String>) -> [Int: String] {
        var directories: [Int: String] = [:]
        var pid: Int?
        for line in lines {
            guard let field = line.first else { continue }
            if field == "p" {
                pid = Int(line.dropFirst())
            } else if field == "n", let pid, line.count > 1 {
                directories[pid] = String(line.dropFirst())
            }
        }
        return directories
    }
}
