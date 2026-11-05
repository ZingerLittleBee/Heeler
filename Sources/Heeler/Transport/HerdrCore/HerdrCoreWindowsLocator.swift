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
    /// Where `install.ps1` puts the core, inside the user's profile folder. Not
    /// PATH: a session riding an older login keeps the PATH from before the install.
    /// Not the folder an SSH exec starts in either, which hc's own dialer uses: a
    /// PowerShell `DefaultShell` runs the account's profile first, and a profile
    /// that calls `Set-Location` moves it (#587).
    static let windowsInstallPath = #"AppData\Local\Programs\herdr-core\herdr-core.exe"#

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
            if ($env:USERPROFILE) {
                say ('home ' + $env:USERPROFILE)
                $exe = Join-Path $env:USERPROFILE \(PowerShellCommand.literal(windowsInstallPath))
                if (Test-Path -LiteralPath $exe -PathType Leaf) {
                    $exe = (Resolve-Path -LiteralPath $exe).ProviderPath
                    $v = $null
                    try { $v = & $exe --version 2>$null | Select-Object -First 1 } catch { $v = $null }
                    if ($v -match '^(hc|herdr-core) [0-9]') {
                        say ('executable ' + $exe)
                        say ('version ' + ($v.Trim() -replace '^\\S+ ', ''))
                    } else { say ('present ' + $exe) }
                }
            }
            $s = \(PowerShellCommand.literal(name))
            $u = $env:USERNAME
            try { $u = ([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\\\')[-1] } catch { }
            $p = '\\\\.\\pipe\\herdr-core-' + ($u -replace '[^A-Za-z0-9]', '') + '-' + $s + '.sock'
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

    /// The link's exec, by the path the probe checked: `cd /d` to the profile folder
    /// the probe joined it to, so a profile's `Set-Location` cannot move it. `cmd /d /c`
    /// skips AutoRun and reads the same under a `cmd` or PowerShell DefaultShell, and
    /// `cmd` expands `%USERPROFILE%` itself, so the line needs no quotes a PowerShell
    /// DefaultShell would drop; `cd` takes a path with spaces unquoted. `connect` stays
    /// `cmd`'s direct child on the exec's own stdio (ADR 0031). Heeler adds no PowerShell
    /// of its own here.
    static func windowsConnectCommand(session: String) throws -> String {
        guard HerdrCoreSessionName.windowsRefusal(session) == nil else {
            throw SessionRefused(session: session)
        }
        let name = HerdrCoreSessionName.normalized(session)
        return "cmd /d /c \"echo \(PowerShellCommand.streamMarker)&& cd /d %USERPROFILE%&& "
            + ".\\\(windowsInstallPath) connect --session \(name)\""
    }
}
