import Foundation
import Testing

@testable import Heeler

/// The native Windows probe and connect line. Nothing here runs PowerShell or
/// `cmd`: the forms are held to what `docs/agents/herdr-compatibility.md` records
/// from one Windows machine, and what comes back is scripted exec output.
@Suite struct HerdrCoreWindowsLocatorTests {
    private static let nonce = "0123456789abcdef"
    private static let pipe = #"\\.\pipe\herdr-core-me-work.sock"#
    private static let executable = #"C:\Users\me\AppData\Local\Programs\herdr-core\herdr-core.exe"#

    /// The PowerShell the exec's `-EncodedCommand` carries.
    static func decoded(_ command: String) throws -> String {
        let prefix = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "
        #expect(command.hasPrefix(prefix))
        let bytes = try #require(Data(base64Encoded: String(command.dropFirst(prefix.count))))
        return try #require(String(data: bytes, encoding: .utf16LittleEndian))
    }

    private func script(session: String = "work") throws -> String {
        try Self.decoded(try HerdrCoreLocator.windowsProbe(session: session, nonce: Self.nonce))
    }

    private func parse(_ lines: [String], framing: String = "\n") throws -> HerdrCoreLocator.Location {
        let output = (["\(Self.nonce) begin"] + lines + ["\(Self.nonce) end"]).joined(separator: framing) + framing
        return try HerdrCoreLocator.parse(stdout: Data(output.utf8), nonce: Self.nonce)
    }

    // MARK: The probe

    @Test func theProbeFindsTheCoreAtTheInstallersPathAndAsksOnlyItsVersion() throws {
        let body = try script()
        #expect(body.contains(#"'.\AppData\Local\Programs\herdr-core\herdr-core.exe'"#))
        #expect(body.contains("& $exe --version"))
        #expect(!body.contains("connect"))
        #expect(!body.contains("server start"))
        #expect(!body.contains("Get-Command"))
    }

    /// A running core locks the file's first byte, so a plain read fails.
    @Test func theProbeReadsTheLockFromItsSecondByteAndRestoresTheBackslash() throws {
        let body = try script()
        #expect(body.contains(#"$s = 'work'"#))
        #expect(body.contains(#"'herdr-core\' + $s + '\core.lock'"#))
        #expect(body.contains("[IO.File]::Open($l, 'Open', 'Read', 'ReadWrite,Delete')"))
        #expect(body.contains("$f.Position = 1"))
        #expect(body.contains(#"'\' + $t.Trim()"#))
        #expect(!body.contains("Get-Content"))
        #expect(!body.contains("ReadAllText"))
    }

    @Test func theProbeFallsBackToTheSessionsDefaultPipeAndChecksThePipeItFound() throws {
        let body = try script()
        #expect(body.contains(#"'\\.\pipe\herdr-core-' + ($env:USERNAME -replace '[^A-Za-z0-9]', '') + '-' + $s + '.sock'"#))
        #expect(body.contains("Test-Path -LiteralPath $p"))
        #expect(!body.contains("if exist"))
    }

    @Test func theProbeNeverNamesHC() throws {
        let body = try script()
        // `hc` appears once, in the pattern for the version text it accepts.
        #expect(body.components(separatedBy: "(hc|herdr-core)").count == 2)
        #expect(body.replacingOccurrences(of: "(hc|herdr-core)", with: "").range(
            of: #"\bhc\b"#, options: [.regularExpression, .caseInsensitive]) == nil)
    }

    /// `cmd.exe` refuses a line over 8191 characters.
    @Test func theCommandFitsACmdLineWithARoomyName() throws {
        let name = String(repeating: "a", count: 200)
        #expect(try HerdrCoreLocator.windowsProbe(session: name, nonce: UUID().uuidString).count < 8191)
    }

    @Test func aNameIsAPowerShellLiteral() throws {
        #expect(try script(session: "  it.s-a_name ").contains(#"$s = 'it.s-a_name'"#))
        #expect(try script(session: "").contains(#"$s = 'default'"#))
    }

    // MARK: Session names

    @Test(arguments: [#"a/b"#, #"a\b"#, "a:b", "a*b", "a?b", #"a"b"#, "a<b", "a>b", "a|b", ".", "..", "a\u{7}b"])
    func aNameHCRefusesRunsNothing(name: String) {
        #expect(throws: HerdrCoreLocator.SessionRefused.self) {
            try HerdrCoreLocator.windowsProbe(session: name, nonce: Self.nonce)
        }
        #expect(throws: HerdrCoreLocator.SessionRefused.self) {
            try HerdrCoreLocator.windowsConnectCommand(session: name)
        }
    }

    /// hc takes these, but they would become syntax in the exec's `cmd` line, which
    /// has no quoting that also survives a PowerShell DefaultShell.
    @Test(arguments: ["a&calc", "a b", "100%", "a^b", "(a)", "a'b", "a;b", "a$b", "a`b", "a!b", "-a", "工作"])
    func aNameTheCmdLineCannotCarryIsRefusedToo(name: String) {
        #expect(HerdrCoreSessionName.isValid(name))
        #expect(throws: HerdrCoreLocator.SessionRefused.self) {
            try HerdrCoreLocator.windowsProbe(session: name, nonce: Self.nonce)
        }
        #expect(throws: HerdrCoreLocator.SessionRefused.self) {
            try HerdrCoreLocator.windowsConnectCommand(session: name)
        }
        #expect(HerdrCoreSessionName.windowsRefusal(name)?.contains("letters, digits") == true)
    }

    @Test(arguments: ["default", "work", "Work_2", "a-b.c", ""])
    func anOrdinaryNameIsCarried(name: String) throws {
        #expect(HerdrCoreSessionName.windowsRefusal(name) == nil)
        _ = try HerdrCoreLocator.windowsProbe(session: name, nonce: Self.nonce)
        _ = try HerdrCoreLocator.windowsConnectCommand(session: name)
    }

    // MARK: The connect line

    /// `cmd /d /c` reads alike under a `cmd` or PowerShell DefaultShell, skips its
    /// AutoRun, and leaves the core a direct child that inherits the exec's stdio.
    @Test func connectRunsUnderCmdAfterAMarkerByTheInstallersPath() throws {
        #expect(
            try HerdrCoreLocator.windowsConnectCommand(session: "work")
                == #"cmd /d /c "echo __HEELER_STREAM_READY__&& .\AppData\Local\Programs\herdr-core\herdr-core.exe connect --session work""#)
        #expect(
            try HerdrCoreLocator.windowsConnectCommand(session: " ").hasSuffix(#"connect --session default""#))
    }

    // MARK: What comes back

    @Test func aRunningCoresLockAndPipeAreRead() throws {
        let location = try parse([
            "kernel Windows", #"home C:\Users\me"#, "executable \(Self.executable)", "version 0.1.16",
            "default \(Self.pipe)", #"lock \\.\pipe\custom.sock"#, "socket-file 1",
        ])
        #expect(location.isNativeWindows)
        #expect(location.executablePath == Self.executable)
        #expect(location.version == "0.1.16")
        #expect(location.socketPath == #"\\.\pipe\custom.sock"#)
        #expect(location.socketSource == .lock)
        #expect(location.socketFilePresent)
        #expect(location.home == #"C:\Users\me"#)
        #expect(location.loginShell == nil)
    }

    @Test func noLockUsesTheDefaultPipeAndAbsentReadsAsAbsent() throws {
        let location = try parse([
            "kernel Windows", "executable \(Self.executable)", "version 0.1.16",
            "default \(Self.pipe)", "socket-file 0",
        ])
        #expect(location.socketPath == Self.pipe)
        #expect(location.socketSource == .sessionDefault)
        #expect(!location.socketFilePresent)
        #expect(!location.appMayStartCore)
    }

    @Test func noExecutableReadsAsNotInstalled() throws {
        let location = try parse(["kernel Windows", "default \(Self.pipe)", "socket-file 0"])
        #expect(location.executablePath == nil)
    }

    /// A pipe name may run to 256 characters there, past any Unix socket path.
    @Test func thePipeLimitIsTheOneWindowsHas() throws {
        let long = #"\\.\pipe\"# + String(repeating: "a", count: 200)
        #expect(try parse(["kernel Windows", "default \(long)", "socket-file 0"]).fitsSocketPathLimit)
        #expect(HerdrCoreLocator.socketPathLimit(kernel: "Windows") == 256)
    }

    @Test func aRelativeExecutableIsNotThisProbesOutput() {
        #expect(throws: HerdrCoreLocator.MalformedOutput.self) {
            try parse(["kernel Windows", #"executable .\herdr-core.exe"#, "version 1", "default x", "socket-file 0"])
        }
    }

    /// A Windows path means nothing on a Unix Host, as a Unix one does here.
    @Test func aUnixHostStillRefusesAnythingButAnAbsoluteUnixPath() {
        #expect(throws: HerdrCoreLocator.MalformedOutput.self) {
            try parse(["kernel Linux", "executable \(Self.executable)", "version 1", "default x", "socket-file 0"])
        }
    }

    // MARK: Telling the user what to run

    @Test func theStartInstructionsNameTheProbedPathAndTheSession() {
        #expect(
            HerdrCoreStart.windowsManualCommand(executablePath: Self.executable, session: "work")
                == "$env:HC_SESSION='work'; \(Self.executable) server start")
    }

    @Test func theDefaultSessionNeedsNoVariable() {
        #expect(
            HerdrCoreStart.windowsManualCommand(executablePath: Self.executable, session: "")
                == "\(Self.executable) server start")
    }

    /// `&` is what PowerShell, the desktop's terminal, needs to run a quoted path.
    @Test func aPathWithASpaceIsQuotedForPowerShell() {
        let spaced = #"C:\Users\A B\AppData\Local\Programs\herdr-core\herdr-core.exe"#
        #expect(
            HerdrCoreStart.windowsManualCommand(executablePath: spaced, session: "work")
                == "$env:HC_SESSION='work'; & '\(spaced)' server start")
        #expect(HerdrCoreStart.windowsUpdateCommand(executablePath: spaced) == "& '\(spaced)' update")
        #expect(HerdrCoreStart.windowsUpdateCommand(executablePath: Self.executable) == "\(Self.executable) update")
    }

    /// A Windows account name may hold any of these, and PowerShell reads each one
    /// as syntax in a bare word.
    @Test(arguments: ["O'Neil", "R&D", "a(b)", "a$b", "a`b", "a{b}", "a#b", "a@b", "a%b", "a~b", "a!b", "张三", "O’Neil"])
    func aPathPowerShellWouldReadAsSyntaxIsQuoted(account: String) {
        let path = #"C:\Users\"# + account + #"\AppData\Local\Programs\herdr-core\herdr-core.exe"#
        let literal = PowerShellCommand.literal(path)
        #expect(HerdrCoreStart.windowsUpdateCommand(executablePath: path) == "& \(literal) update")
        #expect(
            HerdrCoreStart.windowsManualCommand(executablePath: path, session: "default")
                == "& \(literal) server start")
    }

    @Test func aQuoteInThePathIsDoubledInTheCommand() {
        let path = #"C:\Users\O'Neil\herdr-core.exe"#
        #expect(HerdrCoreStart.windowsUpdateCommand(executablePath: path) == #"& 'C:\Users\O''Neil\herdr-core.exe' update"#)
    }
}
