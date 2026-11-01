// What the Windows branches of the herdr-core scripts need from the app's transport
// sources, for tool tests that compile those scripts with no app around them. These
// tests run only the POSIX forms; the Windows ones are tested in the app.

enum HostPlatform: Sendable, Equatable {
    case posix
    case nativeWindows
}

enum PowerShellCommand {
    static let streamMarker = "__HEELER_STREAM_READY__"
    static func encoded(_ script: String, loadingProfile: Bool = false) -> String { script }
    static func literal(_ value: String) -> String { value }
}

enum RemoteHostPath {
    static func isWindowsAbsolute(_ path: String) -> Bool { false }
}
