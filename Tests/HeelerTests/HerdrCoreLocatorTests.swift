import Foundation
import Testing

@testable import Heeler

/// The shared core session name cases from `plugin/test-vectors/`, which the
/// Helper reads too.
private struct SessionNameVectors: Decodable {
    struct Case: Decodable {
        let name: String
        let raw: String
        let normalized: String?
    }
    let cases: [Case]

    private final class BundleLocator {}

    static func load() throws -> SessionNameVectors {
        let url = try #require(
            Bundle(for: BundleLocator.self).url(
                forResource: "herdr-core-session-names-v1", withExtension: "json"))
        return try JSONDecoder().decode(SessionNameVectors.self, from: Data(contentsOf: url))
    }
}

@Suite struct HerdrCoreLocatorTests {
    private static let nonce = "0123456789abcdef"

    private func script(session: String = "work") throws -> String {
        String(decoding: try HerdrCoreLocator.script(session: session, nonce: Self.nonce), as: UTF8.self)
    }

    private func parse(_ lines: [String]) throws -> HerdrCoreLocator.Location {
        let output = (["\(Self.nonce) begin"] + lines + ["\(Self.nonce) end"]).joined(separator: "\n") + "\n"
        return try HerdrCoreLocator.parse(stdout: Data(output.utf8), nonce: Self.nonce)
    }

    /// The bytes the script prints, its leading newline included.
    private static let scriptOutput = Data(
        "\n\(nonce) begin\nkernel Linux\ndefault /tmp/s.sock\nsocket-file 0\n\(nonce) end\n".utf8)

    // MARK: The script

    @Test func theScriptRunsNoHCAndExportsNoPATH() throws {
        let body = try script()
        // `hc ` appears once, as the version text it accepts, never as a command.
        #expect(body.components(separatedBy: "'hc '").count == 2)
        #expect(body.replacingOccurrences(of: "'hc '", with: "").range(
            of: #"\bhc\b"#, options: .regularExpression) == nil)
        #expect(!body.contains("PATH="))
        #expect(!body.contains("export"))
        #expect(!body.contains("HerdrHostPath"))
    }

    @Test func theOnlyThingTheScriptRunsFromTheCoreIsItsVersion() throws {
        let body = try script()
        for subcommand in ["server", "connect", "attach", " run ", " start"] {
            #expect(!body.contains(subcommand), "\(subcommand)")
        }
        #expect(body.contains(#""$1" --version"#))
    }

    @Test func aSessionNameReachesTheScriptAsOneQuotedWord() throws {
        for (session, quoted) in [
            ("work team", "'work team'"), ("東京", "'東京'"), ("work; id", "'work; id'"),
            ("$(id)", "'$(id)'"), ("a'b", #"'a'\''b'"#),
        ] {
            #expect(try script(session: session).hasPrefix("__session=\(quoted)\n"), "\(session)")
        }
    }

    @Test func refusedSessionNamesNeverReachARemoteShell() throws {
        for session in [".", "..", "a/b", "a\nb", "a:b", "bad|name"] {
            #expect(throws: HerdrCoreLocator.SessionRefused(session: session)) {
                try HerdrCoreLocator.script(session: session, nonce: Self.nonce)
            }
        }
    }

    @Test func theSharedSessionVectorNormalizesAndRefusesAsHCDoes() throws {
        let vectors = try SessionNameVectors.load()
        #expect(vectors.cases.count == 29)
        #expect(vectors.cases.contains { $0.normalized == nil })
        for vector in vectors.cases {
            if let expected = vector.normalized {
                #expect(HerdrCoreSessionName.isValid(vector.raw), "\(vector.name)")
                #expect(HerdrCoreSessionName.normalized(vector.raw) == expected, "\(vector.name)")
                let body = try script(session: vector.raw)
                #expect(body.hasPrefix("__session='\(expected.replacingOccurrences(of: "'", with: #"'\''"#))'\n"), "\(vector.name)")
            } else {
                #expect(!HerdrCoreSessionName.isValid(vector.raw), "\(vector.name)")
                #expect(throws: HerdrCoreLocator.SessionRefused.self) {
                    try HerdrCoreLocator.script(session: vector.raw, nonce: Self.nonce)
                }
            }
        }
    }

    // MARK: What the output says

    @Test func noProgramReadsAsNotInstalled() throws {
        let location = try parse([
            "kernel Linux", "default /run/user/1000/herdr-core/work.sock", "socket-file 0",
            "shell /bin/bash",
        ])
        #expect(location.executablePath == nil)
        #expect(location.version == nil)
    }

    @Test func theInstallersPathReadsAsTheExecutable() throws {
        let location = try parse([
            "kernel Linux", "executable /home/me/.local/bin/herdr-core", "version 0.1.13",
            "default /run/user/1000/herdr-core/work.sock", "socket-file 0",
        ])
        #expect(location.executablePath == "/home/me/.local/bin/herdr-core")
        #expect(location.version == "0.1.13")
    }

    @Test func aVersionOtherThanTheTestedOneStillLocates() throws {
        let location = try parse([
            "kernel Linux", "executable /opt/bin/herdr-core", "version 9.8.7",
            "default /run/user/1000/herdr-core/work.sock", "socket-file 1",
        ])
        #expect(location.executablePath == "/opt/bin/herdr-core")
        #expect(location.version == "9.8.7")
    }

    @Test func aLockNamesTheSocket() throws {
        let location = try parse([
            "kernel Darwin", "executable /opt/herdr-core", "version 0.1.13",
            "default /Users/me/.local/state/herdr-core/work/work.sock",
            "lock /tmp/elsewhere/work.sock", "socket-file 1",
        ])
        #expect(location.socketPath == "/tmp/elsewhere/work.sock")
        #expect(location.socketSource == .lock)
        #expect(location.socketFilePresent)
        #expect(!location.isStaleLock)
    }

    @Test func aLockWhoseSocketIsGoneIsStale() throws {
        let location = try parse([
            "kernel Linux", "executable /opt/herdr-core", "version 0.1.13",
            "default /run/user/1000/herdr-core/work.sock",
            "lock /run/user/1000/herdr-core/work.sock", "socket-file 0",
        ])
        #expect(location.socketSource == .lock)
        #expect(location.isStaleLock)
    }

    @Test func noLockFallsBackToTheSessionsDefaultPath() throws {
        let location = try parse([
            "kernel Linux", "executable /opt/herdr-core", "version 0.1.13",
            "default /run/user/1000/herdr-core/work.sock", "socket-file 0",
        ])
        #expect(location.socketPath == "/run/user/1000/herdr-core/work.sock")
        #expect(location.socketSource == .sessionDefault)
        #expect(!location.isStaleLock)
    }

    @Test func aSocketFileLeftBehindIsReported() throws {
        let location = try parse([
            "kernel Linux", "executable /opt/herdr-core", "version 0.1.13",
            "default /run/user/1000/herdr-core/work.sock", "socket-file 1",
        ])
        #expect(location.socketFilePresent)
    }

    @Test(arguments: [("Linux", 107), ("Darwin", 103), ("", 103), ("FreeBSD", 103)])
    func theSocketPathLimitFollowsTheKernel(kernel: String, limit: Int) throws {
        let atLimit = "/" + String(repeating: "a", count: limit - 1)
        let fits = try parse(["kernel \(kernel)", "default \(atLimit)", "socket-file 0"])
        #expect(fits.socketPathLimit == limit)
        #expect(fits.fitsSocketPathLimit)
        let over = try parse(["kernel \(kernel)", "default \(atLimit)a", "socket-file 0"])
        #expect(!over.fitsSocketPathLimit)
    }

    @Test func theLimitCountsBytesNotCharacters() throws {
        let path = "/" + String(repeating: "東", count: 40)
        #expect(path.count < 103)
        let location = try parse(["kernel Darwin", "default \(path)", "socket-file 0"])
        #expect(!location.fitsSocketPathLimit)
    }

    @Test func theLoginShellIsReported() throws {
        let location = try parse([
            "kernel Linux", "default /tmp/s.sock", "socket-file 0", "shell /usr/bin/fish",
        ])
        #expect(location.loginShell == "/usr/bin/fish")
        let unknown = try parse(["kernel Linux", "default /tmp/s.sock", "socket-file 0"])
        #expect(unknown.loginShell == nil)
    }

    // MARK: What the shell prints around the script

    @Test func theBeginMarkerStartsItsOwnLineAfterAnythingTheShellPrinted() throws {
        #expect(try script().contains(#"printf '\n%s begin\n'"#))
    }

    @Test(arguments: [
        Data("Welcome to box\n".utf8),
        Data("Welcome to box".utf8),
        Data("line one\n\nkernel Darwin\nsocket-file 1\n".utf8),
        Data([0xFF, 0xFE, 0x0A]),
        Data([0x63, 0x61, 0x66, 0xE9]),
    ])
    func whatTheShellPrintsBeforeTheScriptIsNotRead(banner: Data) throws {
        let location = try HerdrCoreLocator.parse(stdout: banner + Self.scriptOutput, nonce: Self.nonce)
        #expect(location.socketPath == "/tmp/s.sock")
        #expect(location.socketPathLimit == 107)
        #expect(!location.socketFilePresent)
        #expect(location.executablePath == nil)
    }

    @Test func whatTheShellPrintsAfterTheScriptIsNotRead() throws {
        for trailer in [Data("logout\nsocket-file 1\n".utf8), Data([0xFF, 0xFE])] {
            let location = try HerdrCoreLocator.parse(stdout: Self.scriptOutput + trailer, nonce: Self.nonce)
            #expect(!location.socketFilePresent)
        }
    }

    // MARK: Output it cannot trust

    @Test func aCutOutputStillFailsTheReadAfterTheShellPrinted() {
        let banner = Data("Welcome to box\n".utf8)
        // The final newline is not part of the end marker.
        for length in 0..<(Self.scriptOutput.count - 1) {
            #expect(throws: HerdrCoreLocator.MalformedOutput.self, "\(length)") {
                try HerdrCoreLocator.parse(
                    stdout: banner + Self.scriptOutput.prefix(length), nonce: Self.nonce)
            }
        }
    }

    @Test func markersOutsideTheirOwnLineOrFromAnotherReadDoNotFrameTheOutput() {
        let fields = "kernel Linux\ndefault /tmp/s.sock\nsocket-file 0\n"
        for output in [
            "Welcome \(Self.nonce) begin\n\(fields)\(Self.nonce) end\n",
            "\(Self.nonce) begin\n\(fields)bye \(Self.nonce) end\n",
            "fedcba9876543210 begin\n\(fields)fedcba9876543210 end\n",
            "\(Self.nonce) end\n\(fields)\(Self.nonce) begin\n",
        ] {
            #expect(throws: HerdrCoreLocator.MalformedOutput.self, "\(output)") {
                try HerdrCoreLocator.parse(stdout: Data(output.utf8), nonce: Self.nonce)
            }
        }
    }

    @Test func aSecondFrameInsideTheOutputFailsTheRead() {
        let fields = "kernel Linux\ndefault /tmp/s.sock\nsocket-file 0\n"
        let begin = "\(Self.nonce) begin\n"
        let end = "\(Self.nonce) end\n"
        for output in ["\(begin)\(begin)\(fields)\(end)", "\(begin)\(fields)\(end)\(end)"] {
            #expect(throws: HerdrCoreLocator.MalformedOutput.self, "\(output)") {
                try HerdrCoreLocator.parse(stdout: Data(output.utf8), nonce: Self.nonce)
            }
        }
    }

    @Test func bytesThatAreNotTextBetweenTheMarkersFailTheRead() {
        var output = Data("\(Self.nonce) begin\nkernel Linux\ndefault /tmp/".utf8)
        output.append(contentsOf: [0xFF, 0xFE])
        output.append(Data("\nsocket-file 0\n\(Self.nonce) end\n".utf8))
        #expect(throws: HerdrCoreLocator.MalformedOutput.self) {
            try HerdrCoreLocator.parse(stdout: output, nonce: Self.nonce)
        }
    }

    @Test func outputThatIsNotTheScriptsFailsTheRead() throws {
        let good = [
            "kernel Linux", "executable /opt/herdr-core", "version 0.1.13", "default /tmp/s.sock",
            "socket-file 1",
        ]
        #expect(throws: Never.self) { try parse(good) }
        let cases: [[String]] = [
            good.filter { $0 != "socket-file 1" },
            good.filter { !$0.hasPrefix("default") },
            good.filter { !$0.hasPrefix("kernel") },
            good.filter { !$0.hasPrefix("version") },
            good.filter { !$0.hasPrefix("executable") },
            good + ["socket-file 0"],
            good + ["unknown field"],
            good + ["/a/lock/with\nits newline"],
            ["kernel Linux", "default /tmp/s.sock", "socket-file 2"],
            ["kernel Linux", "default /tmp/s.sock", "socket-file 0", "executable relative", "version 1"],
        ]
        for lines in cases {
            #expect(throws: HerdrCoreLocator.MalformedOutput.self, "\(lines)") { try parse(lines) }
        }
    }

    @Test func everyCutThroughTheOutputFailsTheRead() throws {
        let output = Data(
            "\(Self.nonce) begin\nkernel Linux\ndefault /tmp/s.sock\nsocket-file 0\n\(Self.nonce) end\n".utf8)
        #expect(throws: Never.self) { try HerdrCoreLocator.parse(stdout: output, nonce: Self.nonce) }
        // The final newline is not part of the end marker.
        for length in 0..<(output.count - 1) {
            #expect(throws: HerdrCoreLocator.MalformedOutput.self, "\(length)") {
                try HerdrCoreLocator.parse(stdout: output.prefix(length), nonce: Self.nonce)
            }
        }
    }

    @Test func bytesThatAreNotTextFailTheRead() {
        #expect(throws: HerdrCoreLocator.MalformedOutput.self) {
            try HerdrCoreLocator.parse(stdout: Data([0xff, 0xfe]), nonce: Self.nonce)
        }
    }
}
