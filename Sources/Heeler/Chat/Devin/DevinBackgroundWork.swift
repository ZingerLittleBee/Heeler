import Foundation

/// Only the result of an acknowledged launch associates a shell or child
/// with its parent call. A main turn ending says nothing about either.
struct DevinBackgroundWork {
    private let requiresShellLookup: Bool
    private var calls: [String: (DevinSessionPage.Call, UInt64, Date?)] = [:]
    private var shells: [String: Int] = [:]
    private var children: [String: Int] = [:]
    private var ambiguousShells: Set<String> = []
    private var readsRequested: Set<String> = []
    private var automaticLaunches: [String: (item: ChatBackgroundWorkItem, acknowledgement: UInt64)] = [:]
    private(set) var items: [ChatBackgroundWorkItem] = []

    init(requiresShellLookup: Bool) {
        self.requiresShellLookup = requiresShellLookup
    }

    mutating func observe(_ row: DevinSessionPage.Row, at offset: UInt64, date: Date?) {
        if row.role == "assistant" {
            for call in row.calls {
                calls[call.id] = (call, offset, date)
                if call.name == "get_output", let shell = call.arguments.shell_id { readsRequested.insert(shell) }
            }
        } else if row.role == "subagent_report", let id = row.agentID, !row.text.isEmpty, let index = children[id] {
            finish(index, .completed, output: row.text, at: offset, date: date)
        } else if row.role == "tool", let id = row.resultFor, let (call, launch, started) = calls[id] {
            let args = call.arguments
            switch call.name {
            case "run_subagent":
                if args.is_background == true, let child = row.agentID, !child.isEmpty, children[child] == nil,
                   row.text.hasPrefix("Background subagent started with agent_id=" + child + ".") {
                    var item = ChatBackgroundWorkItem(id: id, kind: .subagent, title: args.title ?? call.name,
                                                      launchOffset: launch, launchedAt: started)
                    item.taskID = child
                    children[child] = items.count
                    items.append(item)
                }
            case "exec":
                if let command = args.command, let shell = acknowledgedShell(call, result: row) {
                    automaticLaunches[shell] = nil
                    if let previous = shells[shell], items[previous].state == .running { ambiguousShells.insert(shell) }
                    var item = ChatBackgroundWorkItem(id: id, kind: .command, title: command,
                                                      launchOffset: launch, launchedAt: started)
                    item.taskID = shell
                    shells[shell] = items.count
                    items.append(item)
                } else if call.complete, call.requestsAutomaticShell == true, args.shell_id == nil, let command = args.command,
                          row.isExecutionResult == true, row.success == true, !row.truncated,
                          let match = row.text.wholeMatch(of: /Command running in background with ID: ([0-9a-f]{6})/) {
                    let shell = String(match.1)
                    // The short acknowledgement alone cannot create a task. An existing
                    // name or a second claimant cannot acquire another command's results.
                    if shells[shell] == nil, !readsRequested.contains(shell), !ambiguousShells.contains(shell) {
                        if automaticLaunches[shell] == nil {
                            var item = ChatBackgroundWorkItem(id: id, kind: .command, title: command,
                                                              launchOffset: launch, launchedAt: started)
                            item.taskID = shell
                            automaticLaunches[shell] = (item, offset)
                        } else {
                            automaticLaunches[shell] = nil
                            ambiguousShells.insert(shell)
                        }
                    }
                }
            case "get_output":
                // Confirm the CLI-assigned name with a later typed lookup and its
                // own successful tool result, each associated by structured call ID.
                if call.complete, let shell = args.shell_id, let pending = automaticLaunches[shell],
                   pending.acknowledgement < launch, shells[shell] == nil, !ambiguousShells.contains(shell),
                   row.isExecutionResult == true, row.success == true {
                    shells[shell] = items.count
                    items.append(pending.item)
                    automaticLaunches[shell] = nil
                }
                if let shell = args.shell_id, !ambiguousShells.contains(shell), let index = shells[shell] {
                    items[index].lastActivityAt = date
                    if !row.truncated, row.success == false, row.text == "This background shell was killed by the user and is no longer running. If you still need to run this command, start a new shell." {
                        finish(index, .stopped, output: row.text, at: offset, date: date)
                    } else if let exit = row.shellExit, exit.outputLength >= 0 {
                        let output = String(row.text.unicodeScalars.prefix(exit.outputLength)).trimmingCharacters(in: .newlines)
                        finish(index, exit.code == 0 ? .completed : .failed, output: output, at: offset, date: date)
                    } else if row.success == true, !row.text.isEmpty {
                        items[index].reportedOutput = row.text
                    }
                }
            default: break
            }
        }
        for (id, report) in row.childReports ?? [:] {
            if let index = children[id], items[index].state == .running, !report.isEmpty {
                finish(index, .completed, output: report, at: offset, date: nil)
            }
        }
    }

    private func acknowledgedShell(_ call: DevinSessionPage.Call, result: DevinSessionPage.Row) -> String? {
        guard !result.truncated, result.success != false else { return nil }
        if let id = call.arguments.shell_id {
            let receipt = "Command running in background with ID: " + id + ". Run get_output with timeout if you need to wait."
            return !id.isEmpty && result.text.hasSuffix(receipt) ? id : nil
        }
        // Devin assigns the ID when exec requests an immediate background return.
        guard !requiresShellLookup, call.complete, call.arguments.timeout == 0, result.success == true,
              let receipt = result.text.wholeMatch(of: /Command running in background with ID: ([0-9a-f]{6})/)
        else { return nil }
        return String(receipt.1)
    }

    private mutating func finish(_ index: Int, _ state: ChatBackgroundWorkItem.State, output: String, at offset: UInt64, date: Date?) {
        items[index].state = state
        items[index].reportedOutput = output
        items[index].endOffset = offset
        items[index].endedAt = date
    }
}
