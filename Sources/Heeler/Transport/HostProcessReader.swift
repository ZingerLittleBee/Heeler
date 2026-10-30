import Foundation

/// Reads a few facts about processes on a Host without leaking their
/// environment: when each started, named environment variables, and the files
/// it holds open. Pure: it builds one bounded script, which a caller runs in
/// one exec, and parses what the script prints (ADR 0034).
enum HostProcessReader {
    struct Request: Equatable, Sendable {
        /// Decimal process ids. Anything else is refused before a script exists.
        var pids: [String]
        var readsStart = false
        var valuesOf: [String] = []
        var namesOf: [String] = []
        var namesWithPrefix: [String] = []
        var readsOpenFiles = false
    }

    /// Which reads the script carries. Production asks the Host's kernel, in
    /// the same exec; a test names one, and points Linux at a fake proc tree.
    enum Platform: Equatable, Sendable {
        case hostKernel
        case linux(procRoot: String)
        case macOS
    }

    enum Refusal: Error, Equatable {
        case pid(String)
        case procRoot(String)
    }

    /// The output was cut short or does not read as this script's.
    struct MalformedOutput: Error, Equatable {}

    enum Reading<Value: Equatable & Sendable>: Equatable, Sendable {
        case value(Value)
        /// Gone, not dumpable, another user's, or not asked for.
        case unavailable
    }

    enum Variable: Equatable, Sendable {
        case value(String)
        /// The environment was read and does not hold this name.
        case unset
        case unavailable
    }

    struct Facts: Equatable, Sendable {
        var start: Reading<String> = .unavailable
        /// Every name in ``Request/valuesOf``.
        var variables: [String: Variable] = [:]
        var nonEmptyNames: Reading<Set<String>> = .unavailable
        var openFiles: Reading<[String]> = .unavailable
    }

    private static let outputCap = 2_097_152

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<12).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    // MARK: Script

    static func script(
        _ request: Request, nonce: String, platform: Platform = .hostKernel
    ) throws -> Data {
        for pid in request.pids where !isProcessID(pid) {
            throw Refusal.pid(pid)
        }
        var lines = [
            "LC_ALL=C",
            "export LC_ALL",
            "exec 2>/dev/null",
            "set -f",
        ]
        switch platform {
        case .linux(let root):
            guard isProcRoot(root) else { throw Refusal.procRoot(root) }
            lines += linuxReads(root: root)
        case .macOS:
            lines += unavailableReads()
        case .hostKernel:
            lines.append("case $(uname -s) in")
            lines.append("Linux)")
            lines += linuxReads(root: "/proc")
            lines.append(";;")
            lines.append("*)")
            lines += unavailableReads()
            lines.append(";;")
            lines.append("esac")
        }
        lines.append("{")
        lines.append("printf '%s\\n' '\(beginMarker(nonce))'")
        for pid in request.pids {
            if request.readsStart { lines.append("s \(pid)") }
        }
        lines.append("printf '\\n%s\\n' '\(endMarker(nonce))'")
        lines.append("} | head -c \(outputCap)")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func linuxReads(root: String) -> [String] {
        [
            "R=\(root)",
            // Field 22 counted past the last `) `, which ends the command
            // name whatever the name holds.
            "s() {",
            "  t=$(cat \"$R/$1/stat\") || t=",
            "  p=$1",
            "  t=${t##*\") \"}",
            "  set -- $t",
            "  v=${20}",
            "  case $v in",
            "  ''|*[!0-9]*) v=- ;;",
            "  esac",
            "  printf 'S %s %s\\n' \"$p\" \"$v\"",
            "}",
        ]
    }

    private static func unavailableReads() -> [String] {
        ["s() { printf 'S %s -\\n' \"$1\"; }"]
    }

    private static func beginMarker(_ nonce: String) -> String { "__HEELER_PROC_BEGIN_\(nonce)" }
    private static func endMarker(_ nonce: String) -> String { "__HEELER_PROC_END_\(nonce)" }

    private static func isProcessID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return !bytes.isEmpty && bytes.count <= 10 && bytes[0] != UInt8(ascii: "0")
            && bytes.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func isProcRoot(_ text: String) -> Bool {
        text.hasPrefix("/")
            && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || "/._-".utf8.contains(byte)
            }
    }

    // MARK: Parse

    /// Facts for each requested pid. Throws ``MalformedOutput`` unless the
    /// output runs from this nonce's begin marker to its end marker and
    /// answers everything the request asked.
    static func parse(
        stdout: Data, nonce: String, request: Request
    ) throws -> [String: Facts] {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let begin = lines.firstIndex(of: beginMarker(nonce)),
            let end = lines.lastIndex(of: endMarker(nonce)), begin < end
        else { throw MalformedOutput() }

        var facts: [String: Facts] = [:]
        var answered: Set<String> = []
        for line in lines[(begin + 1)..<end] where !line.isEmpty {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 3, request.pids.contains(fields[1]) else {
                throw MalformedOutput()
            }
            let pid = fields[1]
            switch fields[0] {
            case "S":
                guard let start = startReading(fields[2]) else { throw MalformedOutput() }
                facts[pid, default: Facts()].start = start
                answered.insert("S \(pid)")
            default:
                throw MalformedOutput()
            }
        }
        for pid in request.pids {
            if facts[pid] == nil { facts[pid] = Facts() }
            if request.readsStart, !answered.contains("S \(pid)") { throw MalformedOutput() }
        }
        return facts
    }

    private static func startReading(_ text: String) -> Reading<String>? {
        if text == "-" { return .unavailable }
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return .value(text)
    }
}
