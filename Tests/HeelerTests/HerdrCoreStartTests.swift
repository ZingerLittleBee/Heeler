import Foundation
import Testing

@testable import Heeler

@Suite struct HerdrCoreStartTests {
    private static let path = "/home/me/.local/bin/herdr-core"

    private func script(session: String = "work", path: String = path) throws -> String {
        String(decoding: try HerdrCoreStart.script(executablePath: path, session: session), as: UTF8.self)
    }

    /// Reads a line as a POSIX shell splits it into words, for the quoting this
    /// command uses: single quotes, double quotes and backslashes.
    private func shellWords(_ line: String) throws -> [String] {
        var words: [String] = []
        var word: String?
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            switch character {
            case " ":
                if let finished = word { words.append(finished) }
                word = nil
            case "\\":
                let escaped = characters.popFirst()
                word = (word ?? "") + String(try #require(escaped))
            case "'":
                let end = try #require(characters.firstIndex(of: "'"))
                word = (word ?? "") + String(characters[..<end])
                characters = characters[(end + 1)...]
            case "\"":
                let end = try #require(characters.firstIndex(of: "\""))
                word = (word ?? "") + String(characters[..<end])
                characters = characters[(end + 1)...]
            default:
                word = (word ?? "") + String(character)
            }
        }
        if let finished = word { words.append(finished) }
        return words
    }

    // MARK: The command

    @Test func theProbedPathRunsServerStartThroughTheInteractiveLoginShell() throws {
        #expect(
            try script() == #""$SHELL" -lic 'HC_SESSION='\''work'\'' exec '\''/home/me/.local/bin/herdr-core'\'' server start'"#
        )
    }

    /// One word to the shell that reads the script, and the session as one word
    /// to the login shell that reads that word, so the assignment comes after
    /// the startup files have run.
    @Test func everySessionNameHCAcceptsSurvivesBothQuotingLayers() throws {
        let extra = ["it's", "a b", "a  b", "''", "$(id)", "`id`", "$HOME", "a!b", "-x", "~", "a;b", "東京"]
        let vectors = try SessionNameVectors.load().cases.compactMap { vector in
            vector.normalized.map { (vector.raw, $0) }
        }
        for (raw, normalized) in vectors + extra.map({ ($0, $0) }) {
            let outer = try shellWords(script(session: raw))
            #expect(outer.count == 3, "\(raw)")
            #expect(outer.prefix(2) == ["$SHELL", "-lic"], "\(raw)")
            let inner = try shellWords(try #require(outer.last))
            #expect(
                inner == ["HC_SESSION=\(normalized)", "exec", Self.path, "server", "start"], "\(raw)")
        }
    }

    @Test func aBlankSessionStartsTheDefaultOneByName() throws {
        let inner = try shellWords(try #require(try shellWords(script(session: "  ")).last))
        #expect(inner.first == "HC_SESSION=default")
    }

    @Test func aPathThatNeedsQuotingSurvivesBothLayers() throws {
        let path = "/home/o'neil smith/.local/bin/herdr-core"
        let inner = try shellWords(try #require(try shellWords(script(path: path)).last))
        #expect(inner == ["HC_SESSION=work", "exec", path, "server", "start"])
    }

    @Test func aSessionNameHCRefusesBuildsNoCommand() throws {
        for session in [".", "..", "a/b", "a\nb", "a:b", #"a"b"#] {
            #expect(throws: HerdrCoreLocator.SessionRefused(session: session)) {
                try script(session: session)
            }
        }
    }

    @Test func theManualCommandNamesThePathAndTheSession() {
        #expect(
            HerdrCoreStart.manualCommand(executablePath: "/opt/hc/herdr-core", session: " work ")
                == "HC_SESSION=work /opt/hc/herdr-core server start")
        #expect(
            HerdrCoreStart.manualCommand(executablePath: "/opt/hc/herdr-core", session: "")
                == "HC_SESSION=default /opt/hc/herdr-core server start")
        #expect(
            HerdrCoreStart.manualCommand(executablePath: "/my apps/herdr-core", session: "it's")
                == #"HC_SESSION='it'\''s' '/my apps/herdr-core' server start"#)
    }

    @Test func theUpdateCommandQuotesAPathTheShellWouldSplit() {
        #expect(HerdrCoreStart.updateCommand(executablePath: "/opt/hc/herdr-core") == "/opt/hc/herdr-core update")
        #expect(HerdrCoreStart.updateCommand(executablePath: "/my apps/herdr-core") == "'/my apps/herdr-core' update")
    }

    // MARK: The result

    private static let statusLine = #"{"core":{"id":"c1","name":"lab"},"pid":7,"uptime_ms":1200}"#
    private static let warnings = """
        bash: cannot set terminal process group (-1): Inappropriate ioctl for device
        bash: no job control in this shell

        """

    private func outcome(
        stdout: Data, stderr: String = warnings, status: Int32 = 0, elapsed: Duration = .seconds(5)
    ) -> HerdrCoreStart.Outcome {
        HerdrCoreStart.outcome(stdout: stdout, stderr: Data(stderr.utf8), exitStatus: status, elapsed: elapsed)
    }

    private func outcome(
        stdout: String, stderr: String = warnings, status: Int32 = 0, elapsed: Duration = .seconds(5)
    ) -> HerdrCoreStart.Outcome {
        outcome(stdout: Data(stdout.utf8), stderr: stderr, status: status, elapsed: elapsed)
    }

    @Test func anUptimeWithinTheStartReadsAsStarted() {
        #expect(outcome(stdout: Self.statusLine + "\n") == .started)
        #expect(outcome(stdout: Self.statusLine + "\n", elapsed: .milliseconds(1200)) == .started)
    }

    @Test func anUptimeThatPredatesTheStartReadsAsAlreadyRunning() {
        #expect(outcome(stdout: Self.statusLine + "\n", elapsed: .milliseconds(1199)) == .alreadyRunning)
    }

    @Test func startupOutputBeforeTheLastLineIsIgnored() {
        let banner = Data("Welcome to box\n".utf8) + Data([0xFF, 0xFE, 0x0A]) + Data(#"{"uptime_ms":999999999}"#.utf8) + Data([0x0A])
        #expect(outcome(stdout: banner + Data((Self.statusLine + "\n\n").utf8)) == .started)
    }

    @Test func aStartupFileThatLeavesNoNewlineDoesNotHideTheUptime() {
        #expect(outcome(stdout: "\u{1B}]0;{box}\u{07}" + Self.statusLine + "\n") == .started)
    }

    @Test func aNonZeroExitReadsAsFailedWithTheLastOutputLine() {
        #expect(
            outcome(stdout: Self.statusLine + "\n", stderr: Self.warnings + "first\nbash: nope: not found\n", status: 127)
                == .failed(detail: "bash: nope: not found"))
        #expect(outcome(stdout: "only on stdout\n", stderr: "", status: 1) == .failed(detail: "only on stdout"))
        #expect(outcome(stdout: "", stderr: "", status: 1) == .failed(detail: nil))
    }

    @Test func aCoreFailureReadsAsItsMessage() {
        let line = #"{"error":{"kind":"io","message":"bind failed","hint":"see the log"}}"#
        #expect(outcome(stdout: "", stderr: Self.warnings + line + "\n", status: 3) == .failed(detail: "bind failed"))
    }

    @Test func anExitWithoutAnUptimeIsNotAStart() {
        #expect(outcome(stdout: "tmux attached\n") == .failed(detail: "tmux attached"))
        #expect(outcome(stdout: #"{"pid":7}"# + "\n") == .failed(detail: #"{"pid":7}"#))
        #expect(outcome(stdout: "") == .failed(detail: nil))
    }
}
