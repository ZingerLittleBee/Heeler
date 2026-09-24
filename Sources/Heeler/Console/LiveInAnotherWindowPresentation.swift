/// What Agent detail says while another window of the app holds its Host's
/// terminal channel. Not a terminal status: this window's Attach has been
/// released on purpose, and "Connecting…" would promise a connection that is
/// not coming until the channel is handed back.
struct LiveInAnotherWindowPresentation: Equatable {
    let title: String
    let message: String
    let systemImage: String

    static let takeOverTitle = "Take Over Here"

    /// Nil while this window holds the channel.
    init?(access: HostTerminalAccess) {
        guard access == .liveInAnotherWindow else { return nil }
        title = "Live in Another Window"
        systemImage = "rectangle.on.rectangle"
        message = "This Host's terminal is open in another Heeler window, and input continues there."
    }
}
