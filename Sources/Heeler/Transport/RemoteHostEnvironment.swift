import Foundation

/// Host shell and endpoint policy. Windows uses herdr's supported stdio API,
/// never a fallback for a Unix Host that refuses stream-local forwarding.
enum RemoteHostEnvironment: Sendable, Equatable {
    case posix(home: String)
    case windows(home: String, configDirectory: String)

    var home: String {
        switch self {
        case .posix(let home), .windows(let home, _): home
        }
    }

    var isWindows: Bool {
        if case .windows = self { return true }
        return false
    }

    func socketPath(for location: HerdrSocketLocation) throws -> String {
        switch self {
        case .posix:
            // API endpoints are stream-local values, not shell arguments.
            // The SSH channel validates absolute paths and embedded NULs.
            return location.path(homeDirectory: home)
        case .windows(_, let config):
            let path: String
            switch location {
            case .defaultSession: path = "\(config)\\herdr.sock"
            case .namedSession(let name):
                guard HerdrSessionName.isValid(name) else {
                    throw TransportError.invalidDirectoryPath(path: name)
                }
                path = "\(config)\\sessions\\\(name)\\herdr.sock"
            case .absolutePath(let custom): path = custom
            }
            guard RemoteHostPath.isAbsolute(path), !path.hasPrefix("/") else {
                throw TransportError.invalidDirectoryPath(path: path)
            }
            return path
        }
    }

    static let windowsMarker = "__HEELER_WINDOWS__="

    static let windowsProbe = PowerShellCommand.encoded("""
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $homePath = $env:USERPROFILE
        if ([string]::IsNullOrEmpty($homePath)) { exit 1 }
        if ($env:XDG_CONFIG_HOME) { $config = Join-Path $env:XDG_CONFIG_HOME 'herdr' }
        elseif ($env:APPDATA) { $config = Join-Path $env:APPDATA 'herdr' }
        else { $config = Join-Path $homePath 'AppData\\Roaming\\herdr' }
        [Console]::WriteLine('__HEELER_WINDOWS__=' + (@{home=$homePath;config=$config} | ConvertTo-Json -Compress))
        """)

    static func windows(from output: Data) -> Self? {
        struct Probe: Decodable { let home: String; let config: String }
        guard let line = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(windowsMarker) }),
            let probe = try? JSONDecoder().decode(
                Probe.self, from: Data(line.dropFirst(windowsMarker.count).utf8)),
            RemoteHostPath.isAbsolute(probe.home), !probe.home.hasPrefix("/"),
            RemoteHostPath.isAbsolute(probe.config), !probe.config.hasPrefix("/")
        else { return nil }
        return .windows(home: probe.home, configDirectory: probe.config)
    }
}

/// EncodedCommand is understood by both cmd.exe and PowerShell login shells.
/// Paths are PowerShell literals inside UTF-16LE, never login-shell arguments.
enum PowerShellCommand {
    static let streamMarker = "__HEELER_STREAM_READY__"
    static func encoded(_ script: String) -> String {
        let bytes = script.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "
            + Data(bytes).base64EncodedString()
    }

    /// Doubles every character PowerShell closes a single-quoted string on, which
    /// includes three typographic quotes a folder can be named with. Each doubled
    /// character reads back as itself.
    static func literal(_ value: String) -> String {
        var quoted = "'"
        for character in value.unicodeScalars {
            if singleQuotes.contains(character) { quoted.unicodeScalars.append(character) }
            quoted.unicodeScalars.append(character)
        }
        return quoted + "'"
    }

    private static let singleQuotes: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"]

    static let preamble = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        """

    static func herdr(
        arguments: [String], socketPath: String? = nil,
        location: HerdrSocketLocation = .defaultSession,
        streaming: Bool = false
    ) -> String {
        var script = preamble + "\n"
        if let socketPath {
            // The terminal controller uses the client endpoint. A legacy
            // override must not redirect it away from the selected API session.
            script += "Remove-Item Env:HERDR_CLIENT_SOCKET_PATH -ErrorAction SilentlyContinue\n"
            if case .absolutePath = location {
                script += "$env:HERDR_SOCKET_PATH = \(literal(socketPath))\n"
            } else {
                // Named pipes are identified by herdr's path spelling. Let its
                // native resolver own separators and configuration precedence.
                script += "Remove-Item Env:HERDR_SOCKET_PATH -ErrorAction SilentlyContinue\n"
            }
            // Do not inherit a different session from the SSH account shell.
            if case .namedSession(let name) = location {
                script += "$env:HERDR_SESSION = \(literal(name))\n"
            } else {
                script += "Remove-Item Env:HERDR_SESSION -ErrorAction SilentlyContinue\n"
            }
        }
        script += "if (-not (Get-Command herdr.exe -ErrorAction SilentlyContinue)) { exit 127 }\n"
        if streaming { script += "[Console]::WriteLine('\(streamMarker)')\n" }
        script += "& herdr.exe \(arguments.map(literal).joined(separator: " "))\nexit $LASTEXITCODE"
        return encoded(script)
    }

    static var discovery: String {
        let checks = SupportedAgentKind.allCases.map { kind in
            "if (Get-Command \(literal(kind.executable)) -ErrorAction SilentlyContinue) { "
                + "[Console]::WriteLine(\(literal(SSHTransportSettings.agentAvailabilityMarker + kind.rawValue))) }"
        }
        return encoded(preamble + "\n[Console]::WriteLine('\(streamMarker)')\n" + checks.joined(separator: "\n"))
    }

    static func outputAfterMarker(_ output: Data) -> Data? {
        let marker = Data((streamMarker + "\r\n").utf8)
        let lfMarker = Data((streamMarker + "\n").utf8)
        guard let range = output.range(of: marker) ?? output.range(of: lfMarker) else { return nil }
        return Data(output[range.upperBound...])
    }
}
