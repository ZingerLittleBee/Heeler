import Foundation

/// Only the task details page binds the Kill key to one process. The list
/// can reorder as tasks finish, so check each new selection before continuing.
enum DroidTaskPanel {
    struct Process: Equatable {
        var pid: String
        var command: String
    }

    enum ListEntry: Equatable {
        case process(Process)
        case truncated(String)

        func mayIdentify(_ item: ChatBackgroundWorkItem) -> Bool {
            switch self {
            case .process(let process): return DroidTaskPanel.matches(process, item: item)
            case .truncated(let prefix):
                guard let pid = item.taskID, let first = item.title.first else { return false }
                return [item.title, first.uppercased() + item.title.dropFirst()].contains {
                    "bash: \($0) (pid: \(pid))".hasPrefix(prefix)
                }
            }
        }
    }

    enum Page: Equatable {
        case list([ListEntry], selection: Int)
        case detail(Process, output: String)
    }

    static func read(_ screen: ANSIScreen) -> Page? {
        let lines = screen.rows.map(\.trimmedText)
        guard let footer = lines.lastIndex(where: { !$0.isEmpty }), footer > 1 else { return nil }
        let hint = footer - 1
        if lines[hint] == "[enter] details | [esc] back" {
            var processes: [ListEntry] = []
            var focus: Int?
            var index = hint
            while index > 0 {
                index -= 1
                var row = lines[index]
                let selected = row.hasPrefix("> ")
                if selected { row = String(row.dropFirst(2)) }
                let entry: ListEntry
                if let process = process(row) { entry = .process(process) }
                else if row.hasPrefix("bash: "), row.hasSuffix("...") {
                    entry = .truncated(String(row.dropLast(3)))
                } else { break }
                if selected {
                    guard focus == nil else { return nil }
                    focus = processes.count
                }
                processes.append(entry)
            }
            guard let focus else { return nil }
            return .list(processes.reversed(), selection: processes.count - 1 - focus)
        }
        guard lines[hint] == "[K] Kill [Esc] Back",
              let border = lines[..<hint].lastIndex(where: { $0.hasPrefix("╰──") && $0.hasSuffix("─╯") }),
              border + 2 < hint, let selected = process(lines[border + 1]),
              let started = lines[(border + 2)..<hint].firstIndex(where: { !$0.isEmpty }), lines[started].hasPrefix("Started: "),
              let output = lines[(started + 1)..<hint].firstIndex(of: "--- Latest output ---") else { return nil }
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
            let openedList = DroidTaskPanel.read(first) == nil
            if openedList {
                let available: @Sendable (ANSIScreen) -> Bool = { screen in
                    DroidInputBox.read(screen).isSendable && screen.rows.contains {
                        $0.trimmedText.wholeMatch(of: /\([1-9][0-9]*\) processes? running \(press ↓ to view\)/) != nil
                    }
                }
                try await key("down", showing: available)
            }
            func closeOpenedList() async throws {
                guard openedList else { return }
                let list = try await read { if case .list = DroidTaskPanel.read($0) { true } else { false } }
                let expected = DroidTaskPanel.read(list)
                try await key("esc") { DroidTaskPanel.read($0) == expected }
            }
            let panel = try await read { DroidTaskPanel.read($0) != nil }
            var enteredDetails = false
            if case .list(let list, let focus) = DroidTaskPanel.read(panel) {
                let matching = list.indices.filter { list[$0].mayIdentify(item) }
                guard matching.count == 1, let index = matching.first else {
                    try await closeOpenedList()
                    return denied
                }
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
                enteredDetails = true
            }
            let correctDetails: @Sendable (ANSIScreen) -> Bool = { screen in
                guard case .detail(let selected, _) = DroidTaskPanel.read(screen) else { return false }
                return DroidTaskPanel.matches(selected, item: item)
            }
            let details = try await read { if case .detail = DroidTaskPanel.read($0) { true } else { false } }
            guard case .detail(let selected, let output) = DroidTaskPanel.read(details) else { return denied }
            func leaveDetails() async throws {
                guard enteredDetails else { return }
                try await key("esc") {
                    guard case .detail(let visible, _) = DroidTaskPanel.read($0) else { return false }
                    return selected == visible
                }
                try await closeOpenedList()
            }
            guard DroidTaskPanel.matches(selected, item: item) else {
                try await leaveDetails()
                return denied
            }
            if stop {
                // A lost receipt must never press Kill again, even if the next
                // selected process reuses the same command or process id.
                droidTaskStops.insert(item.id)
                try await key("K", showing: correctDetails)
                return String(localized: "Stop requested. Waiting for Droid’s task result.")
            }
            try await leaveDetails()
            return output.isEmpty ? String(localized: "Droid has not shown any output yet.") : output
        } catch { return denied }
    }
}
