import Foundation

/// Reads a few facts about processes on a Host without leaking their
/// environment: when each started, named environment variables, and the files
/// it holds open. Pure: it builds one bounded script, which a caller runs in
/// one exec, and parses what the script prints (ADR 0034).
///
/// Only pids, variable names and the nonce reach the script, each validated,
/// so nothing from a Terminal becomes a shell word, and it takes no file path.
/// The script filters on the Host: no other variable's name or value leaves it.
enum HostProcessReader {
    struct Request: Equatable, Sendable {
        /// Decimal process ids. Anything else is refused before a script exists.
        var pids: [String]
        var readsStart = false
        /// Exact names whose values are read.
        var valuesOf: [String] = []
        /// Names reported only when non-empty, never with a value or `=`.
        var namesOf: [String] = []
        /// As ``namesOf``, for any name starting with one of these.
        var namesWithPrefix: [String] = []
        var readsOpenFiles = false

        var readsEnvironment: Bool {
            !valuesOf.isEmpty || !namesOf.isEmpty || !namesWithPrefix.isEmpty
        }
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
        case tooManyProcesses(Int)
        case variableName(String)
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

    /// The script's output past this is cut, with its end marker, so the read
    /// fails rather than answering in part. The exec's watchdog bounds its time.
    private static let outputCap = 2_097_152
    private static let processCap = 64
    /// More open descriptors than this read as unavailable.
    private static let openFileCap = 1024

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
        guard request.pids.count <= processCap else {
            throw Refusal.tooManyProcesses(request.pids.count)
        }
        for name in request.valuesOf + request.namesOf + request.namesWithPrefix
        where !isVariableName(name) {
            throw Refusal.variableName(name)
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
            lines += linuxReads(request, root: root)
        case .macOS:
            lines += macOSReads(request)
        case .hostKernel:
            lines.append("case $(uname -s) in")
            lines.append("Linux)")
            lines += linuxReads(request, root: "/proc")
            lines.append(";;")
            lines.append("Darwin)")
            lines += macOSReads(request)
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
            if request.readsEnvironment { lines.append("e \(pid)") }
            if request.readsOpenFiles { lines.append("f \(pid)") }
        }
        lines.append("printf '\\n%s\\n' '\(endMarker(nonce))'")
        lines.append("} | head -c \(outputCap)")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func linuxReads(_ request: Request, root: String) -> [String] {
        [
            "R=\(root)",
            // `od` keeps the environment's NUL framing exact whatever a value
            // holds, and awk keeps a value only for an exact name asked for.
            // `ok` follows only a whole read, and an empty read (a zombie, a
            // kernel thread) says nothing about any name.
            "e() {",
            "  { od -An -v -tx1 <\"$R/$1/environ\" && echo ok; } | awk -v p=\"$1\" '",
            "function d(x,i,s,c){for(i=1;i<length(x);i+=2){c=T[substr(x,i,2)];"
                + "if(c==\"\")return \"\";s=s c}return s}",
            "function f(){if(m!=\"\"&&!(m in G)){G[m]=1;"
                + "if(m in W)o=o \"V \" p \" \" m \" \" (v==\"\"?\"-\":v) \"\\n\";"
                + "if(z&&((m in N)||\(prefixTest(request))))o=o \"N \" p \" \" m \"\\n\"}"
                + "c++;n=\"\";v=\"\";e=0;z=0;m=\"\"}",
            "BEGIN{x=\"\(nameBytesHex)\";y=\"\(nameBytes)\";"
                + "for(i=1;i<=length(y);i++)T[substr(x,2*i-1,2)]=substr(y,i,1)",
            (request.valuesOf.map { "W[\"\($0)\"]=1" } + request.namesOf.map { "N[\"\($0)\"]=1" })
                .joined(separator: ";"),
            "}",
            "$1==\"ok\"{k=1;next}",
            "{for(i=1;i<=NF;i++){b=$i",
            "if(b==\"00\")f()",
            "else if(e){z=1;if(m in W)v=v b}",
            "else if(b==\"3d\"){e=1;m=d(n)}",
            "else n=n b}}",
            "END{if(n!=\"\"||e)f();if(k&&c>0){printf \"%s\",o;print \"E\",p,\"ok\"}"
                + "else print \"E\",p,\"-\"}",
            "'",
            "}",
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
            // Only targets that are paths. A process that ends during the
            // loop must not read as one that closed everything, and past the
            // cap a partial list could hide the one file a caller looks for.
            "f() {",
            "  p=$1",
            "  d=$R/$p/fd",
            "  if [ ! -r \"$d\" ] || [ ! -x \"$d\" ] || ! command -v readlink >/dev/null; then",
            "    printf 'O %s -\\n' \"$p\"",
            "    return",
            "  fi",
            "  set +f",
            "  set -- \"$d\"/*",
            "  set -f",
            "  if [ \"$#\" -gt \(openFileCap) ]; then",
            "    printf 'O %s -\\n' \"$p\"",
            "    return",
            "  fi",
            "  {",
            "    for l in \"$@\"; do",
            "      t=$(readlink \"$l\") || continue",
            "      case $t in /*) printf '%s\\000' \"$t\" ;; esac",
            "    done | od -An -v -tx1",
            "    [ -r \"$d\" ] && echo ok",
            "  } | awk -v p=\"$p\" '",
            "$1==\"ok\"{k=1;next}",
            "{for(i=1;i<=NF;i++){if($i==\"00\"){o=o \"F \" p \" \" v \"\\n\";v=\"\"}else v=v $i}}",
            "END{if(k){printf \"%s\",o;print \"O\",p,\"ok\"}else print \"O\",p,\"-\"}",
            "'",
            "}",
        ]
    }

    /// Only the methods the macOS spike confirmed; herdr compatibility records
    /// each one with its macOS version. `ps -o lstart=` for the start,
    /// `KERN_PROCARGS2` through `/usr/bin/perl` for variables (`ps -E` cannot
    /// frame a value holding a space), `lsof -F` for descriptors. macOS
    /// withholds a platform binary's environment and ends the buffer there, so
    /// no entries read as unavailable, as an empty read does on Linux. Anywhere
    /// else dyld's own `apple` strings follow the environment, so an empty
    /// environment still has entries past its NULs and holds no asked name.
    ///
    /// `argc` frames an argv the process left alone. One that took a title
    /// (Node's `process.title`) has the title and NULs in the same bytes, so
    /// the NULs past `argc` strings are skipped to find the environment. A title
    /// that fills the area leaves fewer strings than `argc`, and entries sit
    /// where arguments should. The bytes cannot tell `NAME=x` the argument from
    /// `NAME=x` the entry, so an asked name among those strings makes the read
    /// unavailable, and neither `unset` nor the wrong value can come of it.
    private static func macOSReads(_ request: Request) -> [String] {
        [
            "s() {",
            "  t=$(/bin/ps -o lstart= -p \"$1\" </dev/null) || t=",
            "  printf 'S %s %s\\n' \"$1\" \"${t:--}\"",
            "}",
            "e() {",
            "  /usr/bin/perl -e '",
            "use strict;my $p=shift;",
            "my %W=map{($_,1)}qw(\(request.valuesOf.joined(separator: " ")));",
            "my %N=map{($_,1)}qw(\(request.namesOf.joined(separator: " ")));",
            "my @P=qw(\(request.namesWithPrefix.joined(separator: " ")));",
            "sub l{my $k=shift;$N{$k}||grep{index($k,$_)==0}@P}",
            "my $m=pack(\"i3\",1,49,$p);my $b=\"\\0\"x1048576;my $l=pack(\"Q\",1048576);",
            "syscall(202,$m,3,$b,$l,0,0)==0 or exit 1;",
            "my $d=substr($b,0,unpack(\"Q\",$l));my $c=unpack(\"i\",$d);",
            "my $r=substr($d,4);$r=~s/^[^\\0]*\\0+//;",
            "my @a=split(/\\0/,$r,-1);$c++ while $c<@a&&$a[$c] eq \"\";",
            "for my $x(splice(@a,0,$c)){my($k,$v)=split(/=/,$x,2);"
                + "exit 1 if defined $v&&($W{$k}||l($k));}",
            "my $o=\"\";my $n=0;my %G;",
            "for my $x(@a){last if $x eq \"\";$n++;my($k,$v)=split(/=/,$x,2);",
            "next if !defined $v||$G{$k}++;",
            "$o.=\"V $p $k \".(length $v?unpack(\"H*\",$v):\"-\").\"\\n\" if $W{$k};",
            "$o.=\"N $p $k\\n\" if length $v&&$k=~/\\A[A-Za-z0-9_]+\\z/&&l($k);}",
            "exit 1 if !$n;print $o,\"E $p ok\\n\";",
            "' \"$1\" </dev/null || printf 'E %s -\\n' \"$1\"",
            "}",
            "f() {",
            "  /usr/sbin/lsof -nP -a -d 0-65535 -Fn -p \"$1\" </dev/null | awk -v p=\"$1\" '",
            "substr($0,1,2)==\"n/\"{c++;if(c<=\(openFileCap))o=o \"G \" p \" \" substr($0,2) \"\\n\"}",
            "END{if(c>0&&c<=\(openFileCap)){printf \"%s\",o;print \"O\",p,\"ok\"}"
                + "else print \"O\",p,\"-\"}",
            "'",
            "}",
        ]
    }

    private static func prefixTest(_ request: Request) -> String {
        guard !request.namesWithPrefix.isEmpty else { return "0" }
        return request.namesWithPrefix.map { "index(m,\"\($0)\")==1" }.joined(separator: "||")
    }

    private static func unavailableReads() -> [String] {
        [
            "s() { printf 'S %s -\\n' \"$1\"; }",
            "e() { printf 'E %s -\\n' \"$1\"; }",
            "f() { printf 'O %s -\\n' \"$1\"; }",
        ]
    }

    /// The bytes a variable name the script reports may hold, and their hex.
    private static let nameBytes =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    private static let nameBytesHex = nameBytes.utf8.map { String(format: "%02x", $0) }.joined()

    private static func beginMarker(_ nonce: String) -> String { "__HEELER_PROC_BEGIN_\(nonce)" }
    private static func endMarker(_ nonce: String) -> String { "__HEELER_PROC_END_\(nonce)" }

    private static func isProcessID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return !bytes.isEmpty && bytes.count <= 10 && bytes[0] != UInt8(ascii: "0")
            && bytes.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func isVariableName(_ text: String) -> Bool {
        guard let first = text.utf8.first, !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first)
        else { return false }
        return text.utf8.allSatisfy { nameBytes.utf8.contains($0) }
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
        var readable: Set<String> = []
        var values: [String: [String: Variable]] = [:]
        var names: [String: Set<String>] = [:]
        var listed: Set<String> = []
        var files: [String: [String]] = [:]
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
            case "V":
                let parts = fields[2].split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count == 2, request.valuesOf.contains(String(parts[0])),
                    let bytes = bytes(fromHex: parts[1])
                else { throw MalformedOutput() }
                values[pid, default: [:]][String(parts[0])] =
                    String(data: bytes, encoding: .utf8).map(Variable.value) ?? .unavailable
            case "N":
                guard request.namesOf.contains(fields[2])
                    || request.namesWithPrefix.contains(where: fields[2].hasPrefix)
                else { throw MalformedOutput() }
                names[pid, default: []].insert(fields[2])
            case "E":
                guard fields[2] == "ok" || fields[2] == "-" else { throw MalformedOutput() }
                if fields[2] == "ok" { readable.insert(pid) }
                answered.insert("E \(pid)")
            case "F":
                guard let bytes = bytes(fromHex: Substring(fields[2])) else {
                    throw MalformedOutput()
                }
                // A path that is not UTF-8 is no path a caller could name.
                if let path = String(data: bytes, encoding: .utf8) {
                    files[pid, default: []].append(path)
                }
            case "G":
                if let path = String(data: lsofName(fields[2]), encoding: .utf8) {
                    files[pid, default: []].append(path)
                }
            case "O":
                guard fields[2] == "ok" || fields[2] == "-" else { throw MalformedOutput() }
                if fields[2] == "ok" { listed.insert(pid) }
                answered.insert("O \(pid)")
            default:
                throw MalformedOutput()
            }
        }
        for pid in request.pids {
            if request.readsStart, !answered.contains("S \(pid)") { throw MalformedOutput() }
            if request.readsEnvironment, !answered.contains("E \(pid)") { throw MalformedOutput() }
            if request.readsOpenFiles, !answered.contains("O \(pid)") { throw MalformedOutput() }
            var fact = facts[pid] ?? Facts()
            if listed.contains(pid) { fact.openFiles = .value(files[pid] ?? []) }
            let isReadable = readable.contains(pid)
            for name in request.valuesOf {
                fact.variables[name] = isReadable ? values[pid]?[name] ?? .unset : .unavailable
            }
            if isReadable, !request.namesOf.isEmpty || !request.namesWithPrefix.isEmpty {
                fact.nonEmptyNames = .value(names[pid] ?? [])
            }
            facts[pid] = fact
        }
        return facts
    }

    /// `-` is an empty value.
    private static func bytes(fromHex text: Substring) -> Data? {
        if text == "-" { return Data() }
        let digits = Array(text.utf8)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexDigit(digits[index]), let low = hexDigit(digits[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    /// Clock ticks from Linux's stat, or `ps -o lstart=` from macOS with the
    /// padding it ends in removed.
    private static func startReading(_ text: String) -> Reading<String>? {
        if text == "-" { return .unavailable }
        var trimmed = Substring(text)
        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
        if isDigits(trimmed) { return .value(String(trimmed)) }
        let parts = trimmed.split(separator: " ")
        let time = parts.count == 5 ? parts[3].split(separator: ":") : []
        guard parts.count == 5, parts[0].count == 3, parts[1].count == 3,
            parts[2].count <= 2, isDigits(parts[2]), parts[4].count == 4, isDigits(parts[4]),
            time.count == 3, time.allSatisfy({ $0.count == 2 && isDigits($0) })
        else { return nil }
        return .value(String(trimmed))
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// Undoes what `lsof -F` does to a name under `LC_ALL=C`: `\\`, `\n`,
    /// `\t`, `\r`, `\b`, `\f` and `\xHH`. It leaves a literal `^` alone, so a
    /// control byte it writes as `^A` cannot be told from those two characters
    /// and stays as written.
    private static func lsofName(_ text: String) -> Data {
        let input = Array(text.utf8)
        var output = Data(capacity: input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < input.count else {
                output.append(byte)
                index += 1
                continue
            }
            let next = input[index + 1]
            if let plain = lsofEscapes[next] {
                output.append(plain)
                index += 2
            } else if next == UInt8(ascii: "x"), index + 3 < input.count,
                let high = hexDigit(input[index + 2]), let low = hexDigit(input[index + 3])
            {
                output.append(high << 4 | low)
                index += 4
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static let lsofEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "\\"): UInt8(ascii: "\\"),
        UInt8(ascii: "n"): 0x0A,
        UInt8(ascii: "t"): 0x09,
        UInt8(ascii: "r"): 0x0D,
        UInt8(ascii: "b"): 0x08,
        UInt8(ascii: "f"): 0x0C,
    ]
}
