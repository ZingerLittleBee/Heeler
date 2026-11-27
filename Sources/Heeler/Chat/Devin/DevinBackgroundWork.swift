import Foundation

/// Only the result of an acknowledged launch associates a shell or child
/// with its parent call. A main turn ending says nothing about either.
struct DevinBackgroundWork {
    private var calls: [String: (DevinSessionPage.Call, UInt64, Date?)] = [:]
    private var shells: [String: Int] = [:]
    private var children: [String: Int] = [:]
    private var ambiguousShells: Set<String> = []
    private(set) var items: [ChatBackgroundWorkItem] = []

    mutating func observe(_ row: DevinSessionPage.Row, at offset: UInt64, date: Date?) {
        if row.role == "assistant" {
            for call in row.calls { calls[call.id] = (call, offset, date) }
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
                if let shell = args.shell_id, !shell.isEmpty, let command = args.command, row.success != false, !row.truncated,
                   row.text.hasSuffix("Command running in background with ID: " + shell + ". Run get_output with timeout if you need to wait.") {
                    if let previous = shells[shell], items[previous].state == .running { ambiguousShells.insert(shell) }
                    var item = ChatBackgroundWorkItem(id: id, kind: .command, title: command,
                                                      launchOffset: launch, launchedAt: started)
                    item.taskID = shell
                    shells[shell] = items.count
                    items.append(item)
                }
            case "get_output":
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

    private mutating func finish(_ index: Int, _ state: ChatBackgroundWorkItem.State, output: String, at offset: UInt64, date: Date?) {
        items[index].state = state
        items[index].reportedOutput = output
        items[index].endOffset = offset
        items[index].endedAt = date
    }
}
