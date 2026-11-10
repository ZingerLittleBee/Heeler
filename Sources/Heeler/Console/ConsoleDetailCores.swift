import Foundation

/// The core each detail in one window keeps to, past the views that show it.
///
/// A failed Host's placeholder, a tab swap and a size-class change all take a detail
/// down with what it held, and a suspension takes its terminal. By the time it comes
/// back the Host may serve another core with a Terminal of its own at the same
/// address. What comes back is still the detail opened on the old core. Only a pick
/// from the list opens the address anew (ADR 0031).
@MainActor
final class ConsoleDetailCores {
    private var sessions: [ConsoleAgent.ID: AgentComposerSession] = [:]
    private var pins: [ConsoleTerminal.ID: TerminalCorePin] = [:]

    /// The Composer session of the detail shown for `agent`, whose pin everything
    /// the detail does keeps to. A Herdr TUI Host has no core to keep to.
    func session(for agent: ConsoleAgent, console: ConsoleStore) -> AgentComposerSession {
        guard console.keepsDetailsToCores(on: agent.hostID) else {
            return console.composerSession(for: agent)
        }
        if let held = sessions[agent.id] { return held }
        let session = console.composerSession(for: agent)
        sessions[agent.id] = session
        return session
    }

    /// What the screen shown for `terminal` keeps to.
    func pin(for terminal: ConsoleTerminal, console: ConsoleStore) -> TerminalCorePin {
        if let held = pins[terminal.id] { return held }
        let pin = console.corePin(on: terminal.hostID)
        pins[terminal.id] = pin
        return pin
    }

    /// What the list beside `shown` marks as selected. The row at the address of a
    /// detail left on a gone core is another Terminal, so it is not marked, and a tap
    /// on it is a new pick rather than this selection again.
    func listSelection(for shown: ConsoleSelection, console: ConsoleStore) -> ConsoleSelection {
        hasLeftCore(shown, console: console) ? .leftBehind(shown) : shown
    }

    /// A pick from the list. Says whether it replaces a detail left on a gone core;
    /// any other detail at this address stays as it is.
    func openAnew(_ selection: ConsoleSelection, console: ConsoleStore) -> Bool {
        guard hasLeftCore(selection, console: console) else { return false }
        switch selection {
        case .agent(let id): sessions[id] = nil
        case .terminal(let id): pins[id] = nil
        case .leftBehind: break
        }
        return true
    }

    /// Forgets every detail but the one on stage and those parked under a list tab.
    /// Coming back to any other is opening it anew.
    func keep(only held: Set<ConsoleSelection>) {
        sessions = sessions.filter { held.contains(.agent($0.key)) }
        pins = pins.filter { held.contains(.terminal($0.key)) }
    }

    private func hasLeftCore(_ selection: ConsoleSelection, console: ConsoleStore) -> Bool {
        switch selection {
        case .agent(let id): console.hasLeftCore(sessions[id]?.corePin, on: id.hostID)
        case .terminal(let id): console.hasLeftCore(pins[id], on: id.hostID)
        case .leftBehind: false
        }
    }
}
