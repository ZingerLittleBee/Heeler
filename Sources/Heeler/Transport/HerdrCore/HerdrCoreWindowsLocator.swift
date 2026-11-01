import Foundation

/// A native Windows Host's locator and its `connect` line (ADR 0031). Pure, like
/// the Unix locator, and it prints the same fields for the same parser.
///
/// The probe is one bounded exec of PowerShell, which reads `core.lock` from its
/// second byte, since a running core locks the first, and checks that the named pipe
/// exists. It asks the core only for `--version`, which starts nothing, and never
/// runs `hc` by that name. What it says decides whether `connect`, which starts a
/// core when none listens, runs at all.
extension HerdrCoreLocator {
    /// What the probe prints as `kernel`, where a Unix Host prints its `uname -s`.
    static let windowsKernel = "Windows"

    /// Where `install.ps1` puts the core, from the home folder an SSH exec starts
    /// in, as hc's own machine dialer finds it. Not PATH: a session riding an older
    /// login keeps the PATH from before the install.
    static let windowsExecutable = #".\AppData\Local\Programs\herdr-core\herdr-core.exe"#

    /// A named pipe's path, which only a native Windows Host reports.
    static func isWindowsPipe(_ path: String) -> Bool {
        path.hasPrefix(#"\\.\pipe\"#)
    }

    /// PowerShell's single-quoted literals carry everything from outside, so a
    /// name or nonce can never become syntax. Output goes through `Console.Out`
    /// with `\n` line ends, which the parser reads as it does a Unix Host's.
    static func windowsProbe(session: String, nonce: String) throws -> String {
        PowerShellCommand.encoded(
            windowsPrelude + "\n" + (try windowsLocatorBody(session: session, nonce: nonce)) + "\nexit 0")
    }

    static let windowsPrelude = """
        $ErrorActionPreference = 'SilentlyContinue'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        function say($t) { [Console]::Out.Write($t + "`n") }
        """

    /// Runs after `windowsPrelude`, alone or after detection's Herdr TUI read.
    static func windowsLocatorBody(session: String, nonce: String) throws -> String {
        guard HerdrCoreSessionName.windowsRefusal(session) == nil else {
            throw SessionRefused(session: session)
        }
        let name = HerdrCoreSessionName.normalized(session)
        return """
            say ''
            say \(PowerShellCommand.literal("\(nonce) begin"))
            say 'kernel \(windowsKernel)'
            if ($env:USERPROFILE) { say ('home ' + $env:USERPROFILE) }
            $exe = \(PowerShellCommand.literal(windowsExecutable))
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $v = & $exe --version 2>$null | Select-Object -First 1
                if ($v -match '^(hc|herdr-core) [0-9]') {
                    say ('executable ' + (Resolve-Path -LiteralPath $exe).ProviderPath)
                    say ('version ' + ($v.Trim() -replace '^\\S+ ', ''))
                }
            }
            $s = \(PowerShellCommand.literal(name))
            $p = '\\\\.\\pipe\\herdr-core-' + ($env:USERNAME -replace '[^A-Za-z0-9]', '') + '-' + $s + '.sock'
            say ('default ' + $p)
            $r = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\\Local' }
            $l = Join-Path $r ('herdr-core\\' + $s + '\\core.lock')
            $t = $null
            try {
                $f = [IO.File]::Open($l, 'Open', 'Read', 'ReadWrite,Delete')
                try { $f.Position = 1; $t = (New-Object IO.StreamReader($f)).ReadToEnd() } finally { $f.Close() }
            } catch { $t = $null }
            if ($t) {
                $n = '\\' + $t.Trim()
                if ($n -match '^\\\\\\\\\\.\\\\pipe\\\\[^\\r\\n]+$') { say ('lock ' + $n); $p = $n }
            }
            if (Test-Path -LiteralPath $p) { say 'socket-file 1' } else { say 'socket-file 0' }
            say \(PowerShellCommand.literal("\(nonce) end"))
            """
    }

    /// The link's exec, by the path the probe checked. `cmd /d /c` reads the same
    /// under a `cmd` or PowerShell DefaultShell and skips AutoRun, and `connect` stays
    /// its direct child on the exec's own stdio, where every byte crossed unchanged.
    /// No PowerShell sits on this stream: what it does to one was never measured.
    static func windowsConnectCommand(session: String) throws -> String {
        guard HerdrCoreSessionName.windowsRefusal(session) == nil else {
            throw SessionRefused(session: session)
        }
        let name = HerdrCoreSessionName.normalized(session)
        return "cmd /d /c \"echo \(PowerShellCommand.streamMarker)&& \(windowsExecutable) connect --session \(name)\""
    }
}
