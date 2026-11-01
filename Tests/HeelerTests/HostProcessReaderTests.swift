import Foundation
import Testing

@testable import Heeler

/// What the reader's script may carry, and how recorded output parses.
/// `scripts/test-host-process-reader.py` runs the script itself.
@Suite("Host process reader")
struct HostProcessReaderTests {
    private static let nonce = "0123456789abcdef01234567"

    private static let everything = HostProcessReader.Request(
        pids: ["13"],
        readsStart: true,
        valuesOf: ["NAMED", "BLANK", "LINES", "UNICODE", "FORGED", "ABSENT"],
        namesOf: ["TMUX", "STY"],
        namesWithPrefix: ["HERDR_"],
        readsOpenFiles: true)

    /// Recorded from the script on a real `/proc`: Debian 13 in a container,
    /// `/bin/sh` is dash, running as an unprivileged user. Made-up variables
    /// on a process started for the recording; 14 is one that set itself not
    /// dumpable, 17 a zombie, 1 another user's, 99999 gone.
    private static let linuxOutput = """
        __HEELER_PROC_BEGIN_0123456789abcdef01234567
        S 13 14781334
        N 13 TMUX
        V 13 NAMED 7769746820737061636573204f544845523d78
        V 13 UNICODE e8b7afe5be84
        V 13 BLANK -
        N 13 HERDR_SOCKET_PATH
        V 13 LINES 6f6e650a464f524745443d62792d612d6e65776c696e65
        E 13 ok
        F 13 2f6465762f6e756c6c
        F 13 2f746d702f6d7920726f6c6c6f75742e6a736f6e6c
        O 13 ok
        S 14 14781334
        E 14 -
        O 14 -
        S 17 14781334
        E 17 -
        O 17 ok
        S 1 14781277
        E 1 -
        O 1 -
        S 99999 -
        E 99999 -
        O 99999 -

        __HEELER_PROC_END_0123456789abcdef01234567

        """

    /// Recorded from the script on macOS 27.0.1 (arm64). 94113 is a re-signed
    /// copy of `/bin/sleep` started for the recording, 94114 `/bin/sleep`
    /// itself, whose environment macOS withholds, and 94115 gone.
    private static let macOSOutput = """
        __HEELER_PROC_BEGIN_0123456789abcdef01234567
        S 94113 Sat Oct 31 02:11:15 2026
        V 94113 NAMED 7769746820737061636573204f544845523d78
        V 94113 BLANK -
        V 94113 LINES 6f6e650a464f524745443d62792d612d6e65776c696e65
        V 94113 UNICODE e8b7afe5be84
        N 94113 TMUX
        N 94113 HERDR_SOCKET_PATH
        E 94113 ok
        G 94113 /dev/null
        G 94113 /private/tmp/tmp7y97ywik/my \\xe8\\xb7\\xaf\\xe5\\xbe\\x84.jsonl
        G 94113 /dev/null
        O 94113 ok
        S 94114 Sat Oct 31 02:11:15 2026
        E 94114 -
        G 94114 /dev/null
        G 94114 /dev/null
        G 94114 /dev/null
        O 94114 ok
        S 94115 -
        E 94115 -
        O 94115 -

        __HEELER_PROC_END_0123456789abcdef01234567

        """

    private static func linuxRequest() -> HostProcessReader.Request {
        var request = everything
        request.pids = ["13", "14", "17", "1", "99999"]
        return request
    }

    private static func macOSRequest() -> HostProcessReader.Request {
        var request = everything
        request.pids = ["94113", "94114", "94115"]
        return request
    }

    private static func parse(
        _ text: String, request: HostProcessReader.Request = everything
    ) throws -> [String: HostProcessReader.Facts] {
        try HostProcessReader.parse(stdout: Data(text.utf8), nonce: nonce, request: request)
    }

    private static func framed(_ lines: String...) -> String {
        (["__HEELER_PROC_BEGIN_\(nonce)"] + lines + ["__HEELER_PROC_END_\(nonce)", ""])
            .joined(separator: "\n")
    }

    // MARK: Builder

    @Test(arguments: ["", "abc", "12; rm -rf /", "$(id)", "`id`", "12 13", "-1", "0", "012", "٣", "12345678901"])
    func aPidThatIsNotADecimalNumberIsRefused(pid: String) {
        let request = HostProcessReader.Request(pids: ["77", pid], readsStart: true)
        #expect(throws: HostProcessReader.Refusal.pid(pid)) {
            _ = try HostProcessReader.script(request, nonce: Self.nonce)
        }
    }

    @Test func tooManyProcessesAreRefused() throws {
        let allowed = (1...64).map(String.init)
        let request = HostProcessReader.Request(pids: allowed, readsStart: true)
        _ = try HostProcessReader.script(request, nonce: Self.nonce)
        #expect(throws: HostProcessReader.Refusal.tooManyProcesses(65)) {
            _ = try HostProcessReader.script(
                HostProcessReader.Request(pids: allowed + ["65"], readsStart: true), nonce: Self.nonce)
        }
    }

    @Test(arguments: ["", "A B", "A=B", "1A", "A;B", "$(id)", "A'B", "A\"B", "A\nB", "路径"])
    func aVariableNameThatIsNotAnIdentifierIsRefused(name: String) {
        for request in [
            HostProcessReader.Request(pids: ["77"], valuesOf: [name]),
            HostProcessReader.Request(pids: ["77"], namesOf: [name]),
            HostProcessReader.Request(pids: ["77"], namesWithPrefix: [name]),
        ] {
            #expect(throws: HostProcessReader.Refusal.variableName(name)) {
                _ = try HostProcessReader.script(request, nonce: Self.nonce)
            }
        }
    }

    @Test(arguments: ["", "proc", "/a b", "/a'b", "/$(id)", "/a;b"])
    func aProcRootThatNeedsQuotingIsRefused(root: String) {
        #expect(throws: HostProcessReader.Refusal.procRoot(root)) {
            _ = try HostProcessReader.script(
                Self.everything, nonce: Self.nonce, platform: .linux(procRoot: root))
        }
    }

    @Test func noScriptMentionsTheCoreCommandOrAKeyFile() throws {
        for platform in [
            HostProcessReader.Platform.hostKernel, .macOS, .linux(procRoot: "/proc"),
        ] {
            let script = String(
                decoding: try HostProcessReader.script(
                    Self.everything, nonce: Self.nonce, platform: platform),
                as: UTF8.self)
            #expect(!script.contains("hc"))
            #expect(!script.contains("herdr-core"))
            #expect(!script.contains(".key"))
        }
    }

    @Test func theHostKernelFormReadsNothingOnAKernelItDoesNotKnow() throws {
        let script = String(
            decoding: try HostProcessReader.script(Self.everything, nonce: Self.nonce),
            as: UTF8.self)
        #expect(script.contains("case $(uname -s) in\nLinux)\n"))
        #expect(script.contains("\nDarwin)\n"))
        #expect(script.contains("\n*)\ns() { printf 'S %s -\\n' \"$1\"; }\n"))
    }

    /// Against `calendar.timegm`.
    @Test(arguments: [
        ("Sun Nov  1 22:42:20 2026", Int64(1_793_572_940)),
        ("Tue Feb 29 00:00:00 2028", 1_835_395_200),
        ("Sun Jan 31 23:59:59 2027", 1_801_439_999),
    ])
    func aMacOSStartReadsAsTheSecondsItSays(_ start: String, _ seconds: Int64) {
        #expect(HostProcessReader.macOSStartSeconds(start) == seconds)
    }

    @Test(arguments: ["145585", "", "Sun Xxx  1 22:42:20 2026", "Sun Nov  1 22:42 2026", "Sun Feb 31 22:42:20 2026"])
    func anythingElseReadsAsNoStart(_ start: String) {
        #expect(HostProcessReader.macOSStartSeconds(start) == nil)
    }

    @Test func theMacOSFormUsesOnlyTheRecordedMethods() throws {
        let script = String(
            decoding: try HostProcessReader.script(
                Self.everything, nonce: Self.nonce, platform: .macOS),
            as: UTF8.self)
        #expect(script.contains("TZ=UTC /bin/ps -o lstart= -p"))
        #expect(script.contains("/bin/ps -ax -o pid=,ppid="))
        #expect(script.contains("/bin/ps -ww -o comm= -p"))
        #expect(script.contains("/usr/bin/perl -e"))
        #expect(script.contains("/usr/sbin/lsof -nP -a -d 0-65535 -Fn -p"))
        #expect(!script.contains("ps -E"))
        #expect(!script.contains("sysctl"))
        #expect(!script.contains("/proc"))
    }

    @Test func theNonceIsTwentyFourHexDigits() {
        let nonce = HostProcessReader.makeNonce()
        #expect(nonce.count == 24)
        #expect(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: Parser over recorded output

    @Test func recordedLinuxOutputTellsValuesUnsetAndUnavailableApart() throws {
        let facts = try Self.parse(Self.linuxOutput, request: Self.linuxRequest())

        let target = try #require(facts["13"])
        #expect(target.start == .value("14781334"))
        #expect(target.variables == [
            "NAMED": .value("with spaces OTHER=x"),
            "BLANK": .value(""),
            "LINES": .value("one\nFORGED=by-a-newline"),
            "UNICODE": .value("路径"),
            "FORGED": .unset,
            "ABSENT": .unset,
        ])
        #expect(target.nonEmptyNames == .value(["TMUX", "HERDR_SOCKET_PATH"]))
        #expect(target.openFiles == .value(["/dev/null", "/tmp/my rollout.jsonl"]))

        for pid in ["14", "17", "1"] {
            let fact = try #require(facts[pid])
            #expect(fact.start != .unavailable, "\(pid)")
            #expect(fact.nonEmptyNames == .unavailable, "\(pid)")
            #expect(fact.variables["NAMED"] == .unavailable, "\(pid)")
            #expect(fact.variables["ABSENT"] == .unavailable, "\(pid)")
        }
        #expect(facts["14"]?.openFiles == .unavailable)
        #expect(facts["1"]?.openFiles == .unavailable)
        // A zombie's descriptors are readable and empty.
        #expect(facts["17"]?.openFiles == .value([]))

        let gone = try #require(facts["99999"])
        #expect(gone.start == .unavailable)
        #expect(gone.openFiles == .unavailable)
    }

    @Test func recordedMacOSOutputTellsValuesUnsetAndUnavailableApart() throws {
        let facts = try Self.parse(Self.macOSOutput, request: Self.macOSRequest())

        let target = try #require(facts["94113"])
        #expect(target.start == .value("Sat Oct 31 02:11:15 2026"))
        #expect(target.variables == [
            "NAMED": .value("with spaces OTHER=x"),
            "BLANK": .value(""),
            "LINES": .value("one\nFORGED=by-a-newline"),
            "UNICODE": .value("路径"),
            "FORGED": .unset,
            "ABSENT": .unset,
        ])
        #expect(target.nonEmptyNames == .value(["TMUX", "HERDR_SOCKET_PATH"]))
        #expect(target.openFiles == .value(["/dev/null", "/private/tmp/tmp7y97ywik/my 路径.jsonl", "/dev/null"]))

        let platform = try #require(facts["94114"])
        #expect(platform.start == .value("Sat Oct 31 02:11:15 2026"))
        #expect(platform.variables["NAMED"] == .unavailable)
        #expect(platform.nonEmptyNames == .unavailable)
        #expect(platform.openFiles == .value(["/dev/null", "/dev/null", "/dev/null"]))

        let gone = try #require(facts["94115"])
        #expect(gone.start == .unavailable)
        #expect(gone.variables["ABSENT"] == .unavailable)
        #expect(gone.openFiles == .unavailable)
    }

    @Test func lsofEscapesAreUndone() throws {
        let request = HostProcessReader.Request(pids: ["7"], readsOpenFiles: true)
        let facts = try Self.parse(
            Self.framed(
                #"G 7 /a\nb"#, #"G 7 /a\tb"#, #"G 7 /a\\nb"#, #"G 7 /\xe8\xb7\xaf"#, #"G 7 /caret^J"#,
                #"G 7 /odd\q"#, #"G 7 /end\"#, #"G 7 /\xff.bin"#, "O 7 ok"),
            request: request)
        #expect(facts["7"]?.openFiles == .value([
            "/a\nb", "/a\tb", "/a\\nb", "/路", "/caret^J", "/odd\\q", "/end\\",
        ]))
    }

    @Test func aStartOfEitherFormParsesAndAPaddedDayKeepsItsSpacing() throws {
        let request = HostProcessReader.Request(pids: ["7"], readsStart: true)
        #expect(try Self.parse(Self.framed("S 7 Sat Oct  3 02:11:15 2026  "), request: request)["7"]?.start
            == .value("Sat Oct  3 02:11:15 2026"))
        #expect(try Self.parse(Self.framed("S 7 12345"), request: request)["7"]?.start == .value("12345"))
    }

    @Test func aValueThatIsNotUTF8ReadsAsUnavailableAndAPathIsLeftOut() throws {
        let request = HostProcessReader.Request(pids: ["7"], valuesOf: ["A"], readsOpenFiles: true)
        let facts = try Self.parse(
            Self.framed("V 7 A ff", "E 7 ok", "F 7 ff", "F 7 2f61", "O 7 ok"), request: request)
        #expect(facts["7"]?.variables == ["A": .unavailable])
        #expect(facts["7"]?.openFiles == .value(["/a"]))
    }

    @Test func aReadNotAskedForIsUnavailableAndShellNoiseIsIgnored() throws {
        let request = HostProcessReader.Request(pids: ["7"], readsStart: true)
        let facts = try Self.parse("rc file noise\n" + Self.framed("S 7 9") + "trailing noise\n", request: request)
        #expect(facts["7"] == HostProcessReader.Facts(start: .value("9")))
    }

    // MARK: Malformed and truncated output

    @Test func everyCutThroughRecordedOutputFailsTheRead() {
        for (output, request) in [
            (Self.linuxOutput, Self.linuxRequest()), (Self.macOSOutput, Self.macOSRequest()),
        ] {
            let bytes = Data(output.utf8)
            let endMarker = Data("__HEELER_PROC_END_\(Self.nonce)".utf8)
            guard let end = bytes.range(of: endMarker)?.upperBound else {
                Issue.record("the recording has no end marker")
                continue
            }
            for cut in 0..<end {
                #expect(throws: HostProcessReader.MalformedOutput.self, "cut at \(cut)") {
                    _ = try HostProcessReader.parse(
                        stdout: bytes.prefix(cut), nonce: Self.nonce, request: request)
                }
            }
        }
    }

    @Test(arguments: [
        // Another run's markers.
        "__HEELER_PROC_BEGIN_ffffffffffffffffffffffff\nS 13 1\nE 13 ok\nO 13 ok\n__HEELER_PROC_END_ffffffffffffffffffffffff\n",
        // Requested reads without their answers.
        framed(),
        framed("S 13 1"),
        framed("S 13 1", "E 13 ok"),
        framed("E 13 ok", "O 13 ok"),
        // Lines this script never prints.
        framed("S 13 1", "E 13 ok", "O 13 ok", "garbage"),
        framed("S 13 1", "E 13 ok", "O 13 ok", "X 13 1"),
        framed("S 13", "E 13 ok", "O 13 ok"),
        // A pid, or a name, that was not asked for.
        framed("S 13 1", "S 14 1", "E 13 ok", "O 13 ok"),
        framed("S 13 1", "V 13 PATH 2f", "E 13 ok", "O 13 ok"),
        framed("S 13 1", "N 13 PATH", "E 13 ok", "O 13 ok"),
        // A prefix asked for only ever names a name.
        framed("S 13 1", "N 13 HERDR_X=secret", "E 13 ok", "O 13 ok"),
        framed("S 13 1", "N 13 HERDR_X secret", "E 13 ok", "O 13 ok"),
        // A value or a status in the wrong form.
        framed("S 13 1", "V 13 NAMED zz", "E 13 ok", "O 13 ok"),
        framed("S 13 1", "V 13 NAMED abc", "E 13 ok", "O 13 ok"),
        framed("S 13 1", "V 13 NAMED", "E 13 ok", "O 13 ok"),
        framed("S 13 1", "V 13 NAMED", "E 13 maybe", "O 13 ok"),
        framed("S 13 1", "E 13 ok", "F 13 xyz", "O 13 ok"),
        framed("S 13 1", "E 13 ok", "O 13 maybe"),
        framed("S 13 soon", "E 13 ok", "O 13 ok"),
        framed("S 13 Sat Oct 31 2026", "E 13 ok", "O 13 ok"),
    ])
    func malformedOutputFailsTheRead(output: String) {
        #expect(throws: HostProcessReader.MalformedOutput.self) {
            _ = try Self.parse(output)
        }
    }

    // MARK: Named arguments

    private static let argumentRequest = HostProcessReader.Request(
        pids: ["13"], argumentsAmong: ["--managed-daemon", "app-server"])

    @Test func onlyTheArgumentsAskedForAreReported() throws {
        // "--managed-daemon", hex.
        let facts = try Self.parse(
            Self.framed("A 13 2d2d6d616e616765642d6461656d6f6e", "B 13 ok"), request: Self.argumentRequest)
        #expect(facts["13"]?.arguments == .value(["--managed-daemon"]))
    }

    @Test func anArgvHoldingNoneReadsEmptyAndAnUnreadOneUnavailable() throws {
        let none = try Self.parse(Self.framed("B 13 ok"), request: Self.argumentRequest)
        #expect(none["13"]?.arguments == .value([]))
        let unread = try Self.parse(Self.framed("B 13 -"), request: Self.argumentRequest)
        #expect(unread["13"]?.arguments == .unavailable)
    }

    @Test(arguments: [
        // A word that was not asked for: "--token".
        framed("A 13 2d2d746f6b656e", "B 13 ok"),
        // An answer with no end, and a form this script never prints.
        framed("A 13 2d2d6d616e616765642d6461656d6f6e"),
        framed("B 13 maybe"),
        framed("A 13 zz", "B 13 ok"),
    ])
    func malformedArgumentsFailTheRead(output: String) {
        #expect(throws: HostProcessReader.MalformedOutput.self) {
            _ = try Self.parse(output, request: Self.argumentRequest)
        }
    }

    @Test(arguments: ["", "a b", "a'b", "$(id)", "a;b", "a\nb", "路径", "a=b"])
    func anArgumentThatIsNotAPlainWordIsRefused(word: String) {
        #expect(throws: HostProcessReader.Refusal.argument(word)) {
            _ = try HostProcessReader.script(
                HostProcessReader.Request(pids: ["13"], argumentsAmong: [word]), nonce: Self.nonce)
        }
    }

    @Test func bytesThatAreNotTextFailTheReadWithoutCrashing() {
        #expect(throws: HostProcessReader.MalformedOutput.self) {
            _ = try HostProcessReader.parse(
                stdout: Data([0xFF, 0x00, 0x0A, 0xC0, 0x80]), nonce: Self.nonce, request: Self.everything)
        }
    }
}
