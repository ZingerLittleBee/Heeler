import Foundation

/// The loop that follows a tmux server's inventory (ADR 0043). Pure: it builds
/// one script for one long exec and reads what the script keeps printing.
///
/// Once a second the script asks `list-panes -a` and prints the answer only
/// when it changed, between two marker lines, plus a line every few seconds
/// that says it is alive. With a snapshot it prints the arguments of the
/// process leading a pane's foreground process group, but only for a pane that
/// is new, or whose foreground command or the program its `@heeler-status`
/// names changed since the script last looked. It stops when the server stops
/// answering, and when its standard input closes, as it does when the app
/// closes the exec. Every tmux command carries `-N` and `-S`, so it never
/// starts a server.
///
/// A row is a line of ids, numbers and byte lengths, then the names and other
/// free text those lengths measure, since a directory or an option can hold a
/// tab or a newline. The format holds only what changes when something
/// happens: no title, cursor position or activity time, which would print a
/// snapshot every second.
///
/// `scripts/test-tmux-inventory-loop.py` runs the script through real shells
/// against a real tmux.
enum TmuxInventoryLoop {
    enum Event: Equatable, Sendable {
        case inventory(TmuxInventory)
        /// The loop is running and nothing changed.
        case alive
        /// The server stopped answering, and the loop with it.
        case gone
    }

    /// How many asks pass between two `alive` lines while nothing changes.
    static let heartbeatTicks = 5
    /// A loop silent this long is taken for lost.
    static let silenceLimit = Duration.seconds(20)
    /// The most of one process's arguments that leaves the Host.
    static let argumentBytes = 4096

    // MARK: Format

    /// The row's first line, tab-separated: what cannot hold a tab or a newline.
    private static let fixedFields = [
        "#{pid}", "#{start_time}", "#{session_id}", "#{window_id}", "#{window_index}",
        "#{pane_id}", "#{pane_index}", "#{pane_pid}", "#{pane_width}", "#{pane_height}",
        "#{pane_dead}", "#{pane_pipe}",
    ]
    /// What follows it, each measured in bytes on that first line.
    private static let textFields = [
        "session_name", "window_name", "pane_current_command", "pane_current_path",
        "@heeler-status", "@heeler-session", "@heeler-pipe", "@heeler-attach", "@heeler-worktree",
    ]
    fileprivate static var fieldCount: Int { fixedFields.count + textFields.count }
    fileprivate static var lengthFieldStart: Int { fixedFields.count + 1 }
    /// A row whose text is longer than this is not one.
    private static let rowTextLimit = 1 << 20

    /// What `list-panes -a -F` is given. A `.` ends each row, so text that ends
    /// in newlines survives the shell's command substitution. A `;` would not
    /// do: tmux takes one that ends an argument for the end of the command.
    static let format: String =
        (fixedFields + textFields.map { "#{n:\($0)}" }).joined(separator: "\t")
        + "\n" + textFields.map { "#{\($0)}" }.joined() + "."

    // MARK: Script

    /// A script for `/bin/sh -s`, which must be its whole standard input until
    /// the exec is closed: it is one group, so the shell has read all of it
    /// before the loop starts and before anything waits for that input to end.
    static func script(executable: String, socket: String, nonce: String) -> String {
        ([
            "{",
            "LC_ALL=C",
            "export LC_ALL",
            "set -f",
            "t=\(quoted(executable))",
            "s=\(quoted(socket))",
            "n=\(quoted(nonce))",
            "F=\(quoted(format))",
            "P=/usr/bin/perl",
        ] + argumentReader + watcher + [
            // The shell that reads this waits on its input, which only ends, and
            // the loop tells it when the server is gone.
            #"{ w; kill "$$"; } </dev/null 2>/dev/null &"#,
            "p=$!",
            "read -r x",
            #"kill "$p" 2>/dev/null"#,
            "exit 0",
            "}",
        ]).joined(separator: "\n") + "\n"
    }

    /// `w`: the loop. `g` holds what each pane ran when its arguments were last
    /// read, one `pane signature` line each, and awk walks the rows by their
    /// lengths as `Reader` does, in bytes under the C locale.
    private static var watcher: [String] {
        let count = fieldCount
        let lengths = fixedFields.count + 1
        // session_name, window_name, pane_current_command, pane_current_path, @heeler-status.
        let command = "f[\(lengths)]+f[\(lengths + 1)]"
        let status = "\(command)+f[\(lengths + 2)]+f[\(lengths + 3)]"
        return [
            "w() {",
            "o=",
            "g=",
            "f=1",
            "i=0",
            "k=$(uname -s 2>/dev/null)",
            "while :; do",
            #"c=$("$t" -N -u -S "$s" list-panes -a -F "$F" 2>/dev/null </dev/null) || break"#,
            #"if [ -n "$f" ] || [ "$c" != "$o" ]; then"#,
            #"r=$({ printf '%s\n' "$g"; printf '%s body\n' "$n"; printf '%s\n' "$c"; } | awk -v n="$n" '"#,
            #"!b{if($0==n" body")b=1;else if(NF==2)G[$1]=$2;next}"#,
            #"{s=s $0 "\n"}"#,
            "END{p=1;e=length(s)",
            #"while(p<=e){j=index(substr(s,p,512),"\n");if(!j)break"#,
            "h=substr(s,p,j-1);p+=j",
            #"if(split(h,f,"\t")!=\#(count))continue"#,
            #"k=1;for(q=1;q<=\#(count);q++)if(q!=3&&q!=4&&q!=6&&f[q]!~/^[0-9]+$/)k=0"#,
            #"if(!k||f[3]!~/^\$[0-9]+$/||f[4]!~/^@[0-9]+$/||f[6]!~/^%[0-9]+$/)continue"#,
            "u=0;for(q=\(lengths);q<=\(count);q++)u+=f[q]",
            #"if(substr(s,p+u,2)!=".\n")continue"#,
            "c=substr(s,p+\(command),f[\(lengths + 2)]);a=substr(s,p+\(status),f[\(lengths + 4)]);p+=u+2",
            "if(f[6] in D)continue",
            #"D[f[6]]=1;x="";m=split(a,w,/[ :;,\t\n]/);for(q=1;q<=m;q++)if(substr(w[q],1,4)=="app=")x=substr(w[q],5)"#,
            #"gsub(/[^!-~]/,"?",c);gsub(/[^!-~]/,"?",x)"#,
            #"g=f[8]":"f[11]":"c":"x"#,
            #"print "S",f[6],g"#,
            #"if(f[11]=="0"&&G[f[6]]!=g)print "R",f[6],f[8]}}"#,
            "')",
            #"g=$(printf '%s\n' "$r" | sed -n 's/^S //p')"#,
            #"printf '%s begin\n%s\n%s argv\n' "$n" "$c" "$n" || return 0"#,
            #"printf '%s\n' "$r" | sed -n 's/^R //p' | a || return 0"#,
            #"printf '%s end\n' "$n" || return 0"#,
            "o=$c",
            "f=",
            "i=0",
            "fi",
            "i=$((i + 1))",
            #"if [ "$i" -ge \#(heartbeatTicks) ]; then"#,
            #"printf '%s alive\n' "$n" || return 0"#,
            "i=0",
            "fi",
            "sleep 1",
            "done",
            #"printf '%s gone\n' "$n""#,
            "}",
        ]
    }

    /// `a`: for each `pane pid` line, the arguments of the process leading the
    /// foreground process group of that pane's terminal, in hex with a NUL
    /// between two, as `A pane hex`. `A pane -` says they could not be read.
    /// Given an argument (`a 1`), each line ends with that leader's pid, or `-`
    /// when no live leader answered. Linux reads `/proc`. macOS asks `ps` for
    /// the group and `KERN_PROCARGS2` through perl for the arguments, as
    /// `HostProcessReader` does; where that gives nothing, as for a process
    /// that took a title, `ps` gives its words in one line, printed as
    /// `a pane hex`.
    fileprivate static var argumentReader: [String] {
        [
            "a() {",
            "w=${1:-}",
            "case $k in",
            "Linux)",
            "while read -r q p; do",
            "x=-",
            "g=-",
            "l=",
            #"{ read -r l <"/proc/$p/stat"; } 2>/dev/null"#,
            // The foreground group is the sixth field past the last `) `, which
            // ends the command name whatever the name holds.
            #"l=${l##*") "}"#,
            "set -- $l",
            "case ${6:-} in",
            "''|0|*[!0-9]*) ;;",
            "*)",
            #"if [ -r "/proc/$6/stat" ]; then"#,
            "g=$6",
            #"h=$(head -c \#(argumentBytes) "/proc/$6/cmdline" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"#,
            #"[ -z "$h" ] || x=$h"#,
            "fi",
            ";;",
            "esac",
            #"if [ -n "$w" ]; then printf 'A %s %s %s\n' "$q" "$x" "$g" || return 1; else printf 'A %s %s\n' "$q" "$x" || return 1; fi"#,
            "done",
            ";;",
            "Darwin)",
            "r=$(cat)",
            #"[ -n "$r" ] || return 0"#,
            #"l=$(printf '%s\n' "$r" | awk '{printf "%s%s",(NR>1?",":""),$2}')"#,
            #"m=$(/bin/ps -o pid=,tpgid= -p "$l" 2>/dev/null </dev/null)"#,
            #"r=$({ printf '%s\n' "$m"; echo =; printf '%s\n' "$r"; } | awk '"#,
            #"!b{if($0=="=")b=1;else if(NF==2)G[$1]=$2;next}"#,
            #"{print $1,(G[$2]+0>0?G[$2]:"-")}"#,
            "')",
            #"if [ -x "$P" ]; then"#,
            #"printf '%s\n' "$r" | "$P" -e '"#,
            "use strict;",
            "my $w=shift @ARGV;",
            "while(my $l=<STDIN>){chomp $l;my($q,$g)=split(\" \",$l);next unless defined $g;my $x=\"-\";my $k=\"A\";",
            "if($g=~/\\A[0-9]+\\z/&&$g>0){",
            "my $m=pack(\"i3\",1,49,$g);my $b=\"\\0\"x1048576;my $n=pack(\"Q\",1048576);",
            "if(syscall(202,$m,3,$b,$n,0,0)==0){",
            "my $d=substr($b,0,unpack(\"Q\",$n));my $c=unpack(\"i\",$d);",
            "my $r=substr($d,4);$r=~s/^[^\\0]*\\0+//;my @a=split(/\\0/,$r,-1);",
            "if($c>=1&&$c<=@a){my $v=substr(join(\"\\0\",splice(@a,0,$c)),0,\(argumentBytes));"
                + "$x=unpack(\"H*\",$v) if length $v;}}",
            "if($x eq \"-\"){my $t=`/bin/ps -ww -o args= -p $g 2>/dev/null </dev/null`;",
            "if($?!=0){$g=\"-\";}else{chomp $t;$t=substr($t,0,\(argumentBytes));"
                + "if(length $t){$x=unpack(\"H*\",$t);$k=\"a\";}}}}else{$g=\"-\";}",
            "print($w ? \"$k $q $x $g\\n\" : \"$k $q $x\\n\") or exit 1;}",
            #"' -- "$w" || return 1"#,
            "else",
            #"printf '%s\n' "$r" | while read -r q p; do"#,
            "h=",
            "case $p in",
            "-) ;;",
            "*)",
            #"if o=$(/bin/ps -ww -o args= -p "$p" 2>/dev/null </dev/null); then"#,
            #"h=$(printf '%s\n' "$o" | head -c \#(argumentBytes) | od -An -v -tx1 | tr -d ' \n')"#,
            "else",
            "p=-",
            "fi",
            ";;",
            "esac",
            "h=${h%0a}",
            #"if [ -n "$h" ]; then k=a; x=$h; else k=A; x=-; fi"#,
            #"if [ -n "$w" ]; then printf '%s %s %s %s\n' "$k" "$q" "$x" "$p" || exit 1; else printf '%s %s %s\n' "$k" "$q" "$x" || exit 1; fi"#,
            "done || return 1",
            "fi",
            ";;",
            "*)",
            #"while read -r q p; do if [ -n "$w" ]; then printf 'A %s - -\n' "$q" || return 1; else printf 'A %s -\n' "$q" || return 1; fi; done"#,
            ";;",
            "esac",
            "}",
        ]
    }

    fileprivate static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Reading

    /// Reads the loop's output as it arrives, in whatever pieces. It keeps each
    /// pane's arguments between snapshots, since the loop prints them only when
    /// they may have changed, and forgets those of a pane no longer listed and
    /// of another server.
    ///
    /// Nothing a row holds can end a snapshot early or pass for another row: the
    /// first line holds only ids and numbers, and the text after it is taken by
    /// its length. A row that does not read as one is dropped alone.
    struct Reader: Sendable {
        private enum State {
            case idle
            case rows
            case arguments
        }

        private let begin: Data
        private let argumentsMark: Data
        private let end: Data
        private let alive: Data
        private let gone: Data
        private var buffer = Data()
        private var state = State.idle
        private var pending = TmuxInventory()
        private var pendingArguments: [String: [String]?] = [:]
        private var instance: TmuxServerInstance?
        private var argumentsByPane: [String: [String]] = [:]

        init(nonce: String) {
            begin = Data("\(nonce) begin".utf8)
            argumentsMark = Data("\(nonce) argv".utf8)
            end = Data("\(nonce) end".utf8)
            alive = Data("\(nonce) alive".utf8)
            gone = Data("\(nonce) gone".utf8)
        }

        mutating func read(_ bytes: Data) -> [Event] {
            buffer.append(bytes)
            var events: [Event] = []
            var offset = buffer.startIndex
            while let newline = buffer[offset...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[offset..<newline]
                let next = buffer.index(after: newline)
                if line == begin {
                    state = .rows
                    pending = TmuxInventory()
                    pendingArguments = [:]
                    offset = next
                    continue
                }
                switch state {
                case .idle:
                    if line == alive { events.append(.alive) }
                    if line == gone { events.append(.gone) }
                    offset = next
                case .rows:
                    if line == argumentsMark {
                        state = .arguments
                        offset = next
                        continue
                    }
                    guard let row = Row(line: line) else {
                        offset = next
                        continue
                    }
                    // The text and the two bytes that end the row.
                    let rowEnd = next + row.textLength + 2
                    guard rowEnd <= buffer.endIndex else {
                        // More is on its way, or the line only looked like a row.
                        buffer.removeSubrange(buffer.startIndex..<offset)
                        return events
                    }
                    guard buffer[(rowEnd - 2)..<rowEnd] == Data(".\n".utf8) else {
                        offset = next
                        continue
                    }
                    append(row, text: buffer[next..<(rowEnd - 2)])
                    offset = rowEnd
                case .arguments:
                    if line == end {
                        state = .idle
                        events.append(.inventory(finish()))
                    } else {
                        noteArguments(line)
                    }
                    offset = next
                }
            }
            buffer.removeSubrange(buffer.startIndex..<offset)
            return events
        }

        private mutating func append(_ row: Row, text: Data) {
            // One answer comes from one server.
            if pending.instance == nil { pending.instance = row.instance }
            guard pending.instance == row.instance else { return }
            pending.panes.append(row.pane(text: text))
        }

        /// `A %1 6869006f` holds the arguments with a NUL between two, `a %1 …`
        /// the words of a process's title in one line, and `A %1 -` nothing.
        private mutating func noteArguments(_ line: Data) {
            guard let parsed = parseArguments(line, withProcessID: false) else { return }
            pendingArguments[parsed.pane] = .some(parsed.arguments)
        }

        private mutating func finish() -> TmuxInventory {
            if pending.instance != instance {
                instance = pending.instance
                argumentsByPane = [:]
            }
            let listed = Set(pending.panes.map(\.paneID))
            argumentsByPane = argumentsByPane.filter { listed.contains($0.key) }
            for (pane, arguments) in pendingArguments where listed.contains(pane) {
                argumentsByPane[pane] = arguments
            }
            for index in pending.panes.indices where !pending.panes[index].isDead {
                pending.panes[index].foregroundArguments = argumentsByPane[pending.panes[index].paneID]
            }
            let inventory = pending
            pending = TmuxInventory()
            pendingArguments = [:]
            return inventory
        }

        private static func bytes(hex: Data.SubSequence) -> Data? {
            TmuxInventoryLoop.bytes(hex: hex)
        }
    }

    fileprivate static func parseArguments(
        _ line: Data.SubSequence, withProcessID: Bool
    ) -> (pane: String, arguments: [String]?, pid: Int?)? {
        let words = line.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard words.count == (withProcessID ? 4 : 3), words[0].count == 1, let kind = words[0].first,
            kind == UInt8(ascii: "A") || kind == UInt8(ascii: "a"),
            let pane = Row.id(words[1], sigil: "%")
        else { return nil }
        let pid: Int?
        if withProcessID {
            if words[3] == Data("-".utf8) {
                pid = nil
            } else if let parsed = Row.positiveNumber(words[3]) {
                pid = parsed
            } else {
                return nil
            }
        } else {
            pid = nil
        }
        guard let bytes = bytes(hex: words[2]) else {
            return (pane, nil, pid)
        }
        let separator: UInt8 = kind == UInt8(ascii: "A") ? 0 : UInt8(ascii: " ")
        var arguments = bytes.split(separator: separator, omittingEmptySubsequences: kind != UInt8(ascii: "A"))
            .map { String(decoding: $0, as: UTF8.self) }
        // What Linux keeps of an argument list ends in a NUL.
        if bytes.last == 0, arguments.last == "" { arguments.removeLast() }
        return (pane, arguments.isEmpty ? nil : arguments, pid)
    }

    private static func bytes(hex: Data.SubSequence) -> Data? {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var high: UInt8?
        for digit in hex {
            let value: UInt8
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = digit - UInt8(ascii: "a") + 10
            default: return nil
            }
            if let first = high {
                bytes.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return bytes
    }

    /// A row's first line.
    fileprivate struct Row {
        let instance: TmuxServerInstance
        let sessionID: String
        let windowID: String
        let windowIndex: Int
        let paneID: String
        let paneIndex: Int
        let processID: Int
        let width: Int
        let height: Int
        let isDead: Bool
        let hasPipe: Bool
        let lengths: [Int]
        var textLength: Int { lengths.reduce(0, +) }

        init?(line: Data.SubSequence) {
            let fields = line.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false)
            guard fields.count == fieldCount else { return nil }
            func number(_ index: Int) -> Int? {
                let field = fields[index]
                guard !field.isEmpty, field.count <= 18,
                    field.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
                else { return nil }
                return Int(String(decoding: field, as: UTF8.self))
            }
            guard let pid = number(0), let startTime = number(1), let sessionID = Self.id(fields[2], sigil: "$"),
                let windowID = Self.id(fields[3], sigil: "@"), let windowIndex = number(4),
                let paneID = Self.id(fields[5], sigil: "%"), let paneIndex = number(6), let processID = number(7),
                let width = number(8), let height = number(9), let dead = number(10), let pipe = number(11)
            else { return nil }
            var lengths: [Int] = []
            for index in fixedFields.count..<fieldCount {
                guard let length = number(index), length <= rowTextLimit else { return nil }
                lengths.append(length)
            }
            guard lengths.reduce(0, +) <= rowTextLimit else { return nil }
            instance = TmuxServerInstance(pid: pid, startTime: startTime)
            self.sessionID = sessionID
            self.windowID = windowID
            self.windowIndex = windowIndex
            self.paneID = paneID
            self.paneIndex = paneIndex
            self.processID = processID
            self.width = width
            self.height = height
            isDead = dead != 0
            hasPipe = pipe != 0
            self.lengths = lengths
        }

        func pane(text: Data) -> TmuxInventory.Pane {
            var fields: [String] = []
            var start = text.startIndex
            for length in lengths {
                fields.append(String(decoding: text[start..<(start + length)], as: UTF8.self))
                start += length
            }
            return TmuxInventory.Pane(
                sessionID: sessionID, sessionName: fields[0], windowID: windowID,
                windowIndex: windowIndex, windowName: fields[1], paneID: paneID,
                paneIndex: paneIndex, processID: processID, command: fields[2], path: fields[3],
                width: width, height: height, isDead: isDead, hasPipe: hasPipe,
                status: fields[4], agentSession: fields[5], pipeMark: fields[6], attachMark: fields[7],
                worktree: fields[8])
        }

        static func positiveNumber(_ field: Data.SubSequence) -> Int? {
            guard !field.isEmpty, field.count <= 18,
                field.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                let value = Int(String(decoding: field, as: UTF8.self)), value > 0
            else { return nil }
            return value
        }

        static func wholeNumber(_ field: Data.SubSequence) -> Int? {
            guard !field.isEmpty, field.count <= 18,
                field.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
            else { return nil }
            return Int(String(decoding: field, as: UTF8.self))
        }

        /// `$3`, `@12` or `%7`: tmux's sigil and a number.
        static func id(_ field: Data.SubSequence, sigil: Character) -> String? {
            guard field.count > 1, field.count <= 19, field.first == sigil.asciiValue,
                field.dropFirst().allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
            else { return nil }
            return String(decoding: field, as: UTF8.self)
        }
    }
}

/// What a one-shot foreground look finds for one tmux Pane (ADR 0043), sharing
/// `TmuxInventoryLoop`'s row format and foreground process-group reader.
enum TmuxPaneForeground: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        var instance: TmuxServerInstance
        var pane: TmuxInventory.Pane
        /// The leader of the Pane's foreground process group (`tpgid`), nil
        /// when the Host could not name a live leader.
        var foregroundPID: Int?
    }

    case serverNotRunning
    case paneGone(instance: TmuxServerInstance)
    case dead(instance: TmuxServerInstance)
    case live(Sample)

    static func script(executable: String, socket: String, pane: String, nonce: String) -> String? {
        guard TmuxInventoryLoop.Row.id(Data(pane.utf8)[...], sigil: "%") == pane else { return nil }
        let count = TmuxInventoryLoop.fieldCount
        let lengths = TmuxInventoryLoop.lengthFieldStart
        let header: [String] = [
            "LC_ALL=C",
            "export LC_ALL",
            "set -f",
            "t=\(TmuxInventoryLoop.quoted(executable))",
            "s=\(TmuxInventoryLoop.quoted(socket))",
            "n=\(TmuxInventoryLoop.quoted(nonce))",
            "q=\(TmuxInventoryLoop.quoted(pane))",
            "F=\(TmuxInventoryLoop.quoted(TmuxInventoryLoop.format))",
            "P=/usr/bin/perl",
            "k=$(uname -s 2>/dev/null)",
        ]
        let lookup: [String] = [
            #"i=$("$t" -N -u -S "$s" display-message -p '#{pid} #{start_time}' 2>/dev/null </dev/null) || {"#,
            #"printf '%s gone\n' "$n""#,
            "exit 0",
            "}",
            "c=$(\"$t\" -N -u -S \"$s\" list-panes -a -f \"#{==:#{pane_id},$q}\" -F \"$F\" 2>/dev/null </dev/null) || {",
            #"printf '%s gone\n' "$n""#,
            "exit 0",
            "}",
            #"r=$(printf '%s\n' "$c" | awk '"#,
            #"{s=s $0 "\n"}"#,
            "END{p=1;e=length(s)",
            #"while(p<=e){j=index(substr(s,p,512),"\n");if(!j)break"#,
            "h=substr(s,p,j-1);p+=j",
            #"if(split(h,f,"\t")!=\#(count))continue"#,
            #"k=1;for(q=1;q<=\#(count);q++)if(q!=3&&q!=4&&q!=6&&f[q]!~/^[0-9]+$/)k=0"#,
            #"if(!k||f[3]!~/^\$[0-9]+$/||f[4]!~/^@[0-9]+$/||f[6]!~/^%[0-9]+$/)continue"#,
            "u=0;for(q=\(lengths);q<=\(count);q++)u+=f[q]",
            #"if(substr(s,p+u,2)!=".\n")continue"#,
            #"if(f[11]=="0")print f[6],f[8]"#,
            "break}}",
            "')",
            #"printf '%s server %s\n%s begin\n%s\n%s argv\n' "$n" "$i" "$n" "$c" "$n""#,
            #"if [ -n "$r" ]; then printf '%s\n' "$r" | a 1 || exit 1; fi"#,
            #"printf '%s end\n' "$n""#,
        ]
        return (header + TmuxInventoryLoop.argumentReader + lookup).joined(separator: "\n") + "\n"
    }

    static func parse(stdout: Data, pane: String, nonce: String) -> Self? {
        guard TmuxInventoryLoop.Row.id(Data(pane.utf8)[...], sigil: "%") == pane else { return nil }
        let serverPrefix = Data("\(nonce) server ".utf8)
        let begin = Data("\(nonce) begin".utf8)
        let argumentsMark = Data("\(nonce) argv".utf8)
        let end = Data("\(nonce) end".utf8)
        let gone = Data("\(nonce) gone".utf8)

        enum State {
            case idle, rows, arguments
        }

        var state = State.idle
        var serverInstance: TmuxServerInstance?
        var foundRow: (instance: TmuxServerInstance, pane: TmuxInventory.Pane)?
        var foreground: (arguments: [String]?, pid: Int?)?
        var offset = stdout.startIndex

        while let newline = stdout[offset...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = stdout[offset..<newline]
            let next = stdout.index(after: newline)
            switch state {
            case .idle:
                if line == gone { return .serverNotRunning }
                if line.starts(with: serverPrefix) {
                    let rest = line[(line.startIndex + serverPrefix.count)...]
                    let parts = rest.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
                    guard parts.count == 2,
                        let pid = TmuxInventoryLoop.Row.wholeNumber(parts[0]),
                        let startTime = TmuxInventoryLoop.Row.wholeNumber(parts[1])
                    else { return nil }
                    serverInstance = TmuxServerInstance(pid: pid, startTime: startTime)
                } else if line == begin, serverInstance != nil {
                    state = .rows
                }
                offset = next
            case .rows:
                if line == argumentsMark {
                    state = .arguments
                    offset = next
                    continue
                }
                guard let row = TmuxInventoryLoop.Row(line: line) else {
                    offset = next
                    continue
                }
                let rowEnd = next + row.textLength + 2
                guard rowEnd <= stdout.endIndex, stdout[(rowEnd - 2)..<rowEnd] == Data(".\n".utf8) else {
                    offset = next
                    continue
                }
                if foundRow == nil, row.paneID == pane {
                    foundRow = (row.instance, row.pane(text: Data(stdout[next..<(rowEnd - 2)])))
                }
                offset = rowEnd
            case .arguments:
                if line == end {
                    guard let serverInstance else { return nil }
                    guard var found = foundRow else { return .paneGone(instance: serverInstance) }
                    guard found.instance == serverInstance else { return nil }
                    if found.pane.isDead { return .dead(instance: serverInstance) }
                    found.pane.foregroundArguments = foreground?.arguments
                    return .live(
                        Sample(instance: serverInstance, pane: found.pane, foregroundPID: foreground?.pid))
                }
                if let parsed = TmuxInventoryLoop.parseArguments(line, withProcessID: true), parsed.pane == pane {
                    foreground = (parsed.arguments, parsed.pid)
                }
                offset = next
            }
        }
        return nil
    }
}
