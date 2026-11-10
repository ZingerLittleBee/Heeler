import Foundation
import Testing

@testable import Heeler

@Suite("tmux probe")
struct TmuxProbeTests {
    private let nonce = "0123456789abcdef"

    private func output(_ lines: [String]) -> Data {
        Data((["", "\(nonce) tmux begin"] + lines + ["", "\(nonce) tmux end", ""]).joined(separator: "\n").utf8)
    }

    @Test(arguments: [
        ("tmux 3.3", "3.3", true), ("tmux 3.3a", "3.3a", true), ("tmux 3.7b", "3.7b", true),
        ("tmux 4.0", "4.0", true), ("tmux 10.1", "10.1", true), ("tmux next-3.4", "next-3.4", true),
        ("tmux 3.3-rc", "3.3-rc", true), ("tmux master", "master", true),
        ("tmux 3.2a", "3.2a", false), ("tmux 3.2", "3.2", false), ("tmux 2.9a", "2.9a", false),
        ("tmux 1.8", "1.8", false), ("tmux next-3.2", "next-3.2", false), (" tmux 3.1c \r", "3.1c", false),
    ])
    func aVersionLineSaysWhetherTmuxIsNewEnough(line: String, text: String, supported: Bool) throws {
        let version = try #require(TmuxVersion(versionLine: line))
        #expect(version.text == text)
        #expect(version.isSupported == supported)
    }

    @Test(arguments: ["", "tmux", "tmux ", "usage: tmux [-2CDlNuVv]", "3.7b", "screen 4.0"])
    func aLineThatIsNotTmuxsIsNoVersion(_ line: String) {
        #expect(TmuxVersion(versionLine: line) == nil)
    }

    @Test func everyServerCommandCarriesNoStartAndASocketPath() {
        let requests: [TmuxProbe.Request] = [
            .sockets, .resolve(socketName: "work"),
            .stored(executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/default"),
        ]
        for request in requests {
            let script = TmuxProbe.script(request, nonce: nonce)
            let serverCommands = script.split(separator: "\n").filter { $0.contains("display-message") }
            #expect(serverCommands.count == 1)
            #expect(serverCommands.allSatisfy { $0.contains("\"$t\" -N -S \"$1\" display-message") })
            // Nothing names a socket by `-L`, and no command but the version runs without one.
            #expect(!script.contains(" -L "))
            #expect(!script.contains("new-session"))
            #expect(!script.contains("start-server"))
        }
    }

    @Test func onlyAStoredProbeSkipsTheLoginShell() {
        let stored = TmuxProbe.script(
            .stored(executable: "/usr/bin/tmux", socket: "/tmp/tmux-501/default"), nonce: nonce)
        #expect(!stored.contains("-lic"))
        #expect(stored.contains("t='/usr/bin/tmux'"))
        #expect(stored.contains("s='/tmp/tmux-501/default'"))

        for request in [TmuxProbe.Request.sockets, .resolve(socketName: "work")] {
            let script = TmuxProbe.script(request, nonce: nonce)
            // One line for the login shell, which fish parses as a POSIX shell does.
            #expect(script.contains(#""${SHELL:-/bin/sh}" -lic 'exec /bin/sh -c "$__heeler_tmux_probe"' </dev/null"#))
            #expect(script.contains(#"|| /bin/sh -c "$__heeler_tmux_probe" </dev/null"#))
        }
        #expect(TmuxProbe.script(.resolve(socketName: "work"), nonce: nonce).contains("n='\\''work'\\''"))
    }

    @Test func aRunningServerReadsWithItsInstance() throws {
        let report = try TmuxProbe.parse(
            stdout: output([
                "kernel Darwin", "executable /opt/homebrew/bin/tmux", "version tmux 3.7b",
                "directory /private/tmp/tmux-501", "server 4242 1794326988",
            ]), nonce: nonce)

        #expect(report.kernel == "Darwin")
        #expect(report.installation == .usable(executable: "/opt/homebrew/bin/tmux", version: "3.7b"))
        #expect(report.server == TmuxServerInstance(pid: 4242, startTime: 1_794_326_988))
        #expect(report.socketPath(named: "") == "/private/tmp/tmux-501/default")
        #expect(report.socketPath(named: "work") == "/private/tmp/tmux-501/work")
    }

    @Test func socketsAreListedOnceAndOnlyNamesHeelerCanNameBack() throws {
        let report = try TmuxProbe.parse(
            stdout: output([
                "kernel Linux", "executable /usr/bin/tmux", "version tmux 3.4", "directory /tmp/tmux-1000",
                "socket work", "socket default", "socket two words", "socket work", "socket -L", "socket ",
            ]), nonce: nonce)

        #expect(report.sockets == ["work", "default"])
        #expect(report.server == nil)
    }

    @Test func whatTheProbeFoundSaysWhetherTmuxIsUsable() throws {
        let none = try TmuxProbe.parse(stdout: output(["kernel Linux", "directory /tmp/tmux-1000"]), nonce: nonce)
        #expect(none.installation == .notInstalled)

        let old = try TmuxProbe.parse(
            stdout: output(["executable /usr/bin/tmux", "version tmux 3.2a"]), nonce: nonce)
        #expect(old.installation == .updateRequired(version: "3.2a"))

        let notTmux = try TmuxProbe.parse(
            stdout: output(["executable /usr/bin/tmux", "version usage: other"]), nonce: nonce)
        #expect(notTmux.installation == .notInstalled)

        let silent = try TmuxProbe.parse(stdout: output(["executable /usr/bin/tmux", "version "]), nonce: nonce)
        #expect(silent.installation == .notInstalled)
    }

    /// A login shell that gave up partway is followed by the exec's own answer,
    /// and a startup file may print anything, markers included.
    @Test func onlyTheLastWholeAnswerIsRead() throws {
        var stdout = Data("Welcome\n\(nonce) tmux begin\nexecutable /nowhere/tmux\nversion tmux 9.9\n".utf8)
        stdout.append(Data([0xFF, 0xFE]))
        stdout.append(output(["executable /usr/bin/tmux", "version tmux 3.4", "server 1 2"]))

        let report = try TmuxProbe.parse(stdout: stdout, nonce: nonce)

        #expect(report.executable == "/usr/bin/tmux")
        #expect(report.server == TmuxServerInstance(pid: 1, startTime: 2))
    }

    @Test func outputCutShortDoesNotRead() {
        let whole = output(["executable /usr/bin/tmux", "version tmux 3.4"])
        let cut = whole.prefix(whole.count - "\(nonce) tmux end\n".utf8.count)
        #expect(throws: TmuxProbe.MalformedOutput.self) { try TmuxProbe.parse(stdout: Data(cut), nonce: nonce) }
        #expect(throws: TmuxProbe.MalformedOutput.self) { try TmuxProbe.parse(stdout: Data(), nonce: nonce) }
        #expect(throws: TmuxProbe.MalformedOutput.self) {
            try TmuxProbe.parse(stdout: whole, nonce: "another-nonce")
        }
    }

    @Test func aServerLineThatIsNotTwoNumbersIsNoServer() throws {
        for line in ["server", "server 12", "server a b", "server 1 2 3"] {
            let report = try TmuxProbe.parse(stdout: output([line]), nonce: nonce)
            #expect(report.server == nil)
        }
    }
}
