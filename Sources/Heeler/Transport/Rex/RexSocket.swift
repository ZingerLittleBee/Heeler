import Foundation

/// Where a Rex Host's server listens (ADR 0049).
///
/// On macOS and Linux it is the Unix socket detection found: absolute and
/// quotable as one remote shell word, like every path Heeler names on a Host,
/// so a path with spaces, such as macOS's
/// `~/Library/Application Support/rex/server.sock`, is fine.
///
/// On native Windows it is the account's named pipe, written as Rex writes
/// its address, `npipe:////./pipe/rex-<SID>`. SSH cannot forward a named pipe,
/// so a channel reaches it through `rex -S <path> __internal dial-stdio`
/// (`RexWindowsDial`).
struct RexSocket: Codable, Hashable, Sendable {
    let path: String

    init?(path: String) {
        if Self.isWindowsPipeAddress(path) {
            self.path = path
            return
        }
        guard RemoteShellPath.isQuotableAbsolute(path), !path.hasSuffix("/") else { return nil }
        self.path = path
    }

    /// A native Windows server's named pipe.
    var isWindowsPipe: Bool { Self.isWindowsPipeAddress(path) }

    /// The prefix Rex gives a named pipe's address.
    static var windowsPipePrefix: String { RexProbe.windowsPipePrefix }

    static func isWindowsPipeAddress(_ path: String) -> Bool {
        RexProbe.isWindowsPipeAddress(path)
    }

    private enum CodingKeys: String, CodingKey {
        case path
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        guard let socket = RexSocket(path: path) else {
            throw DecodingError.dataCorruptedError(
                forKey: .path, in: container, debugDescription: "Invalid Rex socket path")
        }
        self = socket
    }
}

/// How a channel reaches a native Windows Rex server (ADR 0049, update
/// 2026-11-25). SSH forwards no named pipe, so each channel is an exec of
/// Rex's own stdio bridge, the one Rex's command-line tool uses over SSH to a
/// Windows host: `rex -S <pipe> __internal dial-stdio --autostart=false`. The
/// bridge copies bytes between the exec and the pipe, so the control link and
/// each data link carry the same WebSocket they carry over a Unix socket.
///
/// `--autostart=false` keeps it from starting a server where none listens, so
/// connecting still starts nothing.
enum RexWindowsDial {
    /// `cmd /d /c` skips AutoRun and reads the same under a `cmd` or
    /// PowerShell DefaultShell, as herdr-core's `connect` line does (ADR 0031),
    /// and `cd /d %USERPROFILE%` keeps a profile's `Set-Location` from choosing
    /// where cmd looks first. The marker comes first, so whatever the
    /// account's shell prints at startup is dropped before the WebSocket's
    /// upgrade (`BootstrappedExecChannel`). `rex.exe` is named in full and
    /// found on the exec's PATH, where the Windows probe found it, so no
    /// `rex.cmd` or `rex.bat` takes its place; the pipe's address needs no
    /// quoting (`RexSocket.isWindowsPipeAddress`).
    /// Why a running Windows server cannot be reached: the bridge runs
    /// `rex.exe` from the exec's PATH, and it is not there.
    static var notOnPathReason: String {
        String(localized: "Rex is running, but rex.exe is not on the PATH of this account's SSH sessions.")
    }

    static func command(for socket: RexSocket) -> String? {
        guard socket.isWindowsPipe else { return nil }
        return "cmd /d /c \"echo \(PowerShellCommand.streamMarker)&& cd /d %USERPROFILE%&& "
            + "rex.exe -S \(socket.path) __internal dial-stdio --autostart=false\""
    }
}
