/// What Agent detail says while another window of the app holds its Host's
/// terminal channel. Not a terminal status: this window's Attach has been
/// released on purpose, and "Connecting…" would promise a connection that is
/// not coming until the channel is handed back.
struct LiveInAnotherWindowPresentation: Equatable {
    let title: String
    let message: String
    let systemImage: String
    /// Offered unless the other window shows a Shell Terminal, which cannot
    /// be handed over without losing it.
    let showsTakeOver: Bool

    static let takeOverTitle = String(localized: "Take Over Here")

    /// Nil while this window holds the channel.
    init?(access: HostTerminalAccess) {
        guard case .liveInAnotherWindow(let canTakeOver) = access else { return nil }
        title = String(localized: "Live in Another Window")
        systemImage = "rectangle.on.rectangle"
        showsTakeOver = canTakeOver
        message =
            canTakeOver
            ? String(localized: "This Host's terminal is open in another Heeler window, and input continues there.")
            : String(localized: "A Shell Terminal on this Host is open in another Heeler window, and input continues there. Close it to use the terminal here.")
    }
}
