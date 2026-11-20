import Foundation

/// What this device remembers of each herdr-core Host: the core it last spoke
/// to, the kernel a locator last found, the directory it first saw each Terminal launched in, which decides that
/// Terminal's derived Workspace (ADR 0032), and each Terminal's turns and seen
/// mark, which decide Done on this device (ADR 0033). None of it is a secret or
/// shared with the Host. It goes with the Host. When the Host's core id changes it
/// starts over, since addresses belong to one core, all but the kernel, which
/// belongs to the machine.
///
/// A tmux Host keeps its server instance here as its core id (ADR 0045): pane
/// ids belong to one run of the server as addresses belong to one core, and so
/// do its Panes' turns and seen marks (ADR 0046), which go with the instance.
/// A Rex Host keeps its server instance and its terminals' turns and seen
/// marks the same way (ADR 0054), and the conversation the user picked for a
/// terminal's Agent, which a tmux Host keeps on the Pane: nothing is written
/// on a Rex Host, so the pick stays on this device.
@MainActor
final class HerdrCoreHostMemory {
    /// A Rex terminal's pick (ADR 0034): the `heeler.chat` value, with the
    /// foreground and the Agent kind it was made on, so another program in
    /// the terminal voids it as the inventory says so.
    struct RexChatPick: Codable, Equatable, Sendable {
        let label: String
        let foregroundPID: Int?
        let kind: String

        init(label: String, foregroundPID: Int?, kind: String) {
            self.label = label
            self.foregroundPID = foregroundPID
            self.kind = kind
        }
    }

    private struct Entry: Codable, Equatable {
        var coreID: String?
        /// What the locator prints as `kernel` (`uname -s` on Unix, `Windows` on
        /// native Windows), for a Host whose connection has yet to say.
        var kernel: String?
        var directories: [String: String] = [:]
        var turns: [String: HerdrCoreTurnState] = [:]
        /// A tmux Host's, by pane id.
        var tmuxTurns: [String: TmuxTurnState] = [:]
        /// A Rex Host's, by pane id.
        var rexTurns: [String: RexTurnState] = [:]
        /// A Rex Host's picks, by pane id.
        var rexChatPicks: [String: RexChatPick] = [:]

        init(coreID: String? = nil) {
            self.coreID = coreID
        }

        /// Memory written before seen marks has no `turns`.
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            coreID = try fields.decodeIfPresent(String.self, forKey: .coreID)
            kernel = try fields.decodeIfPresent(String.self, forKey: .kernel)
            directories = try fields.decodeIfPresent([String: String].self, forKey: .directories) ?? [:]
            turns = try fields.decodeIfPresent([String: HerdrCoreTurnState].self, forKey: .turns) ?? [:]
            tmuxTurns = try fields.decodeIfPresent([String: TmuxTurnState].self, forKey: .tmuxTurns) ?? [:]
            rexTurns = try fields.decodeIfPresent([String: RexTurnState].self, forKey: .rexTurns) ?? [:]
            rexChatPicks = try fields.decodeIfPresent([String: RexChatPick].self, forKey: .rexChatPicks) ?? [:]
        }
    }

    private static let defaultsKey = "herdr-core.host-memory"

    private let defaults: UserDefaults?
    private var entries: [Host.ID: Entry]

    /// With no `defaults` it lasts as long as the object: demo mode and tests
    /// build Console stores in the app's own container, and their `setHosts`
    /// would otherwise clear the real one.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        entries =
            defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Host.ID: Entry].self, from: $0) } ?? [:]
    }

    func coreID(for hostID: Host.ID) -> String? {
        entries[hostID]?.coreID
    }

    func kernel(for hostID: Host.ID) -> String? {
        entries[hostID]?.kernel
    }

    /// What a locator last found, which outlives the core it found.
    func noteKernel(_ kernel: String, for hostID: Host.ID) {
        var entry = entries[hostID] ?? Entry()
        guard entry.kernel != kernel else { return }
        entry.kernel = kernel
        entries[hostID] = entry
        save()
    }

    func firstSeenDirectories(for hostID: Host.ID) -> [String: String] {
        entries[hostID]?.directories ?? [:]
    }

    func turnStates(for hostID: Host.ID) -> [String: HerdrCoreTurnState] {
        entries[hostID]?.turns ?? [:]
    }

    func updateTurnState(
        of address: String, for hostID: Host.ID, _ change: (inout HerdrCoreTurnState) -> Void
    ) {
        var entry = entries[hostID] ?? Entry()
        var state = entry.turns[address] ?? HerdrCoreTurnState()
        change(&state)
        guard entry.turns[address] != state else { return }
        entry.turns[address] = state
        entries[hostID] = entry
        save()
    }

    func tmuxTurnStates(for hostID: Host.ID) -> [String: TmuxTurnState] {
        entries[hostID]?.tmuxTurns ?? [:]
    }

    func updateTmuxTurnState(
        of paneID: String, for hostID: Host.ID, _ change: (inout TmuxTurnState) -> Void
    ) {
        var entry = entries[hostID] ?? Entry()
        var state = entry.tmuxTurns[paneID] ?? TmuxTurnState()
        change(&state)
        guard entry.tmuxTurns[paneID] != state else { return }
        entry.tmuxTurns[paneID] = state
        entries[hostID] = entry
        save()
    }

    /// The panes a tmux server lists: any other's turns are forgotten, since
    /// the server never gives a closed pane's id out again.
    func retainTmuxPanes(_ paneIDs: Set<String>, for hostID: Host.ID) {
        guard var entry = entries[hostID] else { return }
        let retained = entry.tmuxTurns.filter { paneIDs.contains($0.key) }
        guard retained != entry.tmuxTurns else { return }
        entry.tmuxTurns = retained
        entries[hostID] = entry
        save()
    }

    func rexTurnStates(for hostID: Host.ID) -> [String: RexTurnState] {
        entries[hostID]?.rexTurns ?? [:]
    }

    func updateRexTurnState(
        of paneID: String, for hostID: Host.ID, _ change: (inout RexTurnState) -> Void
    ) {
        var entry = entries[hostID] ?? Entry()
        var state = entry.rexTurns[paneID] ?? RexTurnState()
        change(&state)
        guard entry.rexTurns[paneID] != state else { return }
        entry.rexTurns[paneID] = state
        entries[hostID] = entry
        save()
    }

    /// The terminals a Rex server lists: any other's turns and pick are
    /// forgotten.
    func retainRexPanes(_ paneIDs: Set<String>, for hostID: Host.ID) {
        guard var entry = entries[hostID] else { return }
        let retained = entry.rexTurns.filter { paneIDs.contains($0.key) }
        let picks = entry.rexChatPicks.filter { paneIDs.contains($0.key) }
        guard retained != entry.rexTurns || picks != entry.rexChatPicks else { return }
        entry.rexTurns = retained
        entry.rexChatPicks = picks
        entries[hostID] = entry
        save()
    }

    func rexChatPicks(for hostID: Host.ID) -> [String: RexChatPick] {
        entries[hostID]?.rexChatPicks ?? [:]
    }

    /// Keeps `pick` for the terminal, or forgets its pick when nil.
    func setRexChatPick(_ pick: RexChatPick?, of paneID: String, for hostID: Host.ID) {
        var entry = entries[hostID] ?? Entry()
        guard entry.rexChatPicks[paneID] != pick else { return }
        entry.rexChatPicks[paneID] = pick
        entries[hostID] = entry
        save()
    }

    /// The core a `hello` reported. Another core forgets the old one's Terminals.
    func noteCore(_ coreID: String, for hostID: Host.ID) {
        guard entries[hostID]?.coreID != coreID else { return }
        var entry = Entry(coreID: coreID)
        entry.kernel = entries[hostID]?.kernel
        entries[hostID] = entry
        save()
    }

    /// A snapshot's Terminals: new ones are remembered where they launched, and
    /// any the core no longer has are forgotten.
    func noteInventory(_ terminals: [HerdrCoreTerminalRecord], for hostID: Host.ID) {
        var entry = entries[hostID] ?? Entry()
        var directories: [String: String] = [:]
        for terminal in terminals {
            directories[terminal.address] = entry.directories[terminal.address] ?? terminal.cwd
        }
        entry.directories = directories
        entry.turns = entry.turns.filter { directories[$0.key] != nil }
        guard entries[hostID] != entry else { return }
        entries[hostID] = entry
        save()
    }

    /// The first directory stays: a kept Terminal restarting elsewhere changes nothing.
    func noteTerminal(_ terminal: HerdrCoreTerminalRecord, for hostID: Host.ID) {
        var entry = entries[hostID] ?? Entry()
        guard entry.directories[terminal.address] == nil else { return }
        entry.directories[terminal.address] = terminal.cwd
        entries[hostID] = entry
        save()
    }

    func forgetTerminal(_ address: String, for hostID: Host.ID) {
        let forgotDirectory = entries[hostID]?.directories.removeValue(forKey: address) != nil
        let forgotTurns = entries[hostID]?.turns.removeValue(forKey: address) != nil
        guard forgotDirectory || forgotTurns else { return }
        save()
    }

    /// Also the launch-time sweep: a Host removed while the app was not running
    /// leaves memory no one else would delete.
    func retainHosts(_ hostIDs: Set<Host.ID>) {
        let retained = entries.filter { hostIDs.contains($0.key) }
        guard retained != entries else { return }
        entries = retained
        save()
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
