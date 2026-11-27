import Foundation

/// Only the task details page binds the Kill key to one process. The list
/// can reorder as tasks finish, so check each new selection before continuing.
enum DroidTaskPanel {
    struct Process: Equatable {
        var pid: String
        var command: String
    }

    enum Page: Equatable {
        case list([Process], selection: Int)
        case detail(Process, output: String)
    }

    static func read(_ screen: ANSIScreen) -> Page? {
        let lines = screen.rows.map(\.trimmedText)
        guard let footer = lines.lastIndex(where: { !$0.isEmpty }), footer > 1 else { return nil }
        let hint = footer - 1
        if lines[hint] == "[enter] details | [esc] back" {
            var processes: [Process] = []
            var focus: Int?
            var index = hint
            while index > 0 {
                index -= 1
                var row = lines[index]
                let selected = row.hasPrefix("> ")
                if selected { row = String(row.dropFirst(2)) }
                guard let process = process(row) else { break }
                if selected {
                    guard focus == nil else { return nil }
                    focus = processes.count
                }
                processes.append(process)
            }
            guard let focus else { return nil }
            return .list(processes.reversed(), selection: processes.count - 1 - focus)
        }
        guard lines[hint] == "[K] Kill [Esc] Back",
              let border = lines[..<hint].lastIndex(where: { $0.hasPrefix("╰──") && $0.hasSuffix("─╯") }),
              border + 2 < hint, let selected = process(lines[border + 1]),
              lines[border + 2].hasPrefix("Started: "),
              let output = lines[(border + 3)..<hint].firstIndex(of: "--- Latest output ---") else { return nil }
        return .detail(selected, output: lines[(output + 1)..<hint].joined(separator: "\n").trimmingCharacters(in: .newlines))
    }

    private static func process(_ line: String) -> Process? {
        guard let match = line.wholeMatch(of: /bash: (.+) \(pid: ([1-9][0-9]*)\)/) else { return nil }
        return .init(pid: String(match.2), command: String(match.1))
    }

    static func matches(_ process: Process, item: ChatBackgroundWorkItem) -> Bool {
        guard item.kind == .command, item.taskID == process.pid, let first = item.title.first else { return false }
        return process.command == item.title || process.command == first.uppercased() + item.title.dropFirst()
    }
}

extension AgentChatStore {
    /// Uses the same scoped read and checked Attach as a Blocked Card. Never
    /// signal an OS PID or send a key from an unrecognized task screen.
    func inspectDroidTask(_ item: ChatBackgroundWorkItem, session: String, stop: Bool) async -> String {
        let denied = String(localized: "Open this Droid terminal to inspect the task. Its current selection could not be verified.")
        guard program == .droid, !droidTaskActionInFlight, !droidTaskStops.contains(item.id) else { return denied }
        droidTaskActionInFlight = true
        defer { droidTaskActionInFlight = false }
        guard
              let id = item.taskID, !id.isEmpty, let inspect = droidScreen.droidTarget,
              let target = try? await inspect(), target.sessionID == session,
              item.kind == .command, backgroundWork.rows.contains(where: { $0.item == item && $0.isRunning }),
              await confirmSessionBeforeSend() == nil else { return denied }
        let io = droidScreen
        func key(_ name: String, showing test: @escaping @Sendable (ANSIScreen) -> Bool) async throws {
            guard try await inspect() == target, test(try await io.readScreen()) else { throw TransportError.cancelled }
            try await io.type(.keys([name]), whileShowing: test)
        }
        func read(_ test: (ANSIScreen) -> Bool) async throws -> ANSIScreen {
            for _ in 0..<8 {
                let screen = try await io.readScreen()
                if test(screen) { return screen }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw TransportError.cancelled
        }
        do {
            let first = try await io.readScreen()
            if DroidTaskPanel.read(first) == nil {
                let available: @Sendable (ANSIScreen) -> Bool = { screen in
                    DroidInputBox.read(screen).isSendable && screen.rows.contains {
                        $0.trimmedText.wholeMatch(of: /\([1-9][0-9]*\) processes? running \(press ↓ to view\)/) != nil
                    }
                }
                try await key("down", showing: available)
            }
            let panel = try await read { DroidTaskPanel.read($0) != nil }
            if case .list(let list, let focus) = DroidTaskPanel.read(panel) {
                let matching = list.indices.filter { DroidTaskPanel.matches(list[$0], item: item) }
                guard matching.count == 1, let index = matching.first else { return denied }
                var position = focus
                while position != index {
                    let expected = DroidTaskPanel.Page.list(list, selection: position)
                    try await key(index > position ? "down" : "up") { DroidTaskPanel.read($0) == expected }
                    position += index > position ? 1 : -1
                    let next = DroidTaskPanel.Page.list(list, selection: position)
                    _ = try await read { DroidTaskPanel.read($0) == next }
                }
                let selected = DroidTaskPanel.Page.list(list, selection: index)
                try await key("enter") { DroidTaskPanel.read($0) == selected }
            }
            let correctDetails: @Sendable (ANSIScreen) -> Bool = { screen in
                guard case .detail(let selected, _) = DroidTaskPanel.read(screen) else { return false }
                return DroidTaskPanel.matches(selected, item: item)
            }
            let details = try await read(correctDetails)
            guard case .detail(_, let output) = DroidTaskPanel.read(details) else { return denied }
            if stop {
                // A lost receipt must never press Kill again, even if the next
                // selected process reuses the same command or process id.
                droidTaskStops.insert(item.id)
                try await key("K", showing: correctDetails)
                return String(localized: "Stop requested. Waiting for Droid’s task result.")
            }
            try await key("esc", showing: correctDetails)
            let list = try await read { if case .list = DroidTaskPanel.read($0) { true } else { false } }
            let expected = DroidTaskPanel.read(list)
            try await key("esc") { DroidTaskPanel.read($0) == expected }
            return output.isEmpty ? String(localized: "Droid has not shown any output yet.") : output
        } catch { return denied }
    }
}
