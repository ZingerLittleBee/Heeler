import Foundation

@testable import Heeler

/// What the inventory loop's script prints, written by hand: tests of the
/// reader and the scripted tmux Host speak the loop's own text, so the reader
/// they exercise is the one the app runs.
enum TmuxLoopText {
    static let nonce = "0123456789abcdef"

    /// How a snapshot carries one pane's arguments.
    enum Arguments: Equatable, Sendable {
        /// `A pane hex`: the arguments with a NUL between two.
        case list([String])
        /// `a pane hex`: a process's words in one line.
        case words(String)
        /// `A pane -`: they could not be read.
        case unreadable
    }

    /// One row: the line of ids, numbers and byte lengths, then the text.
    static func row(_ pane: TmuxInventory.Pane, instance: TmuxServerInstance) -> Data {
        let texts = [
            pane.sessionName, pane.windowName, pane.command, pane.path, pane.status, pane.agentSession,
            pane.pipeMark, pane.attachMark, pane.worktree,
        ]
        let fixed: [String] = [
            String(instance.pid), String(instance.startTime), pane.sessionID, pane.windowID,
            String(pane.windowIndex), pane.paneID, String(pane.paneIndex), String(pane.processID),
            String(pane.width), String(pane.height), pane.isDead ? "1" : "0", pane.hasPipe ? "1" : "0",
        ]
        let header = (fixed + texts.map { String($0.utf8.count) }).joined(separator: "\t")
        return Data((header + "\n" + texts.joined() + ".\n").utf8)
    }

    static func argumentLine(pane: String, _ arguments: Arguments) -> Data {
        switch arguments {
        case .list(let list):
            Data("A \(pane) \(hex(Data(list.joined(separator: "\0").utf8)))\n".utf8)
        case .words(let words):
            Data("a \(pane) \(hex(Data(words.utf8)))\n".utf8)
        case .unreadable:
            Data("A \(pane) -\n".utf8)
        }
    }

    /// A whole snapshot, from its `begin` line to its `end` line.
    static func snapshot(
        _ panes: [TmuxInventory.Pane], instance: TmuxServerInstance,
        arguments: [(pane: String, arguments: Arguments)] = [], nonce: String = nonce
    ) -> Data {
        var text = Data("\(nonce) begin\n".utf8)
        for pane in panes { text.append(row(pane, instance: instance)) }
        // The shell's command substitution drops the newline that ends the last row.
        if !panes.isEmpty { text.removeLast() }
        text.append(Data("\n\(nonce) argv\n".utf8))
        for entry in arguments { text.append(argumentLine(pane: entry.pane, entry.arguments)) }
        text.append(Data("\(nonce) end\n".utf8))
        return text
    }

    static func alive(nonce: String = nonce) -> Data { Data("\(nonce) alive\n".utf8) }
    static func gone(nonce: String = nonce) -> Data { Data("\(nonce) gone\n".utf8) }

    private static func hex(_ data: Data) -> String {
        data.map { byte in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
    }
}

extension TmuxInventory.Pane {
    /// A pane of window `@window` in session `$session`, with the rest as tmux
    /// would say it of a pane running `command`.
    static func make(
        session: Int = 0, sessionName: String = "main", window: Int = 0, windowIndex: Int = 0,
        windowName: String = "first", pane: Int = 0, paneIndex: Int = 0, processID: Int = 4000,
        command: String = "zsh", path: String = "/home/dev", width: Int = 80, height: Int = 24,
        isDead: Bool = false, hasPipe: Bool = false, status: String = "", agentSession: String = "",
        pipeMark: String = "", attachMark: String = "", worktree: String = "",
        arguments: [String]? = nil
    ) -> TmuxInventory.Pane {
        var made = TmuxInventory.Pane(
            sessionID: "$\(session)", sessionName: sessionName, windowID: "@\(window)", windowIndex: windowIndex,
            windowName: windowName, paneID: "%\(pane)", paneIndex: paneIndex, processID: processID,
            command: command, path: path, width: width, height: height, isDead: isDead, hasPipe: hasPipe,
            status: status, agentSession: agentSession, pipeMark: pipeMark, attachMark: attachMark,
            worktree: worktree)
        made.foregroundArguments = arguments
        return made
    }
}
