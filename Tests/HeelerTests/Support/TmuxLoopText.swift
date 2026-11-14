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

    /// Quotes `value` as tmux's `#{q:...}` (`format_quote_shell`) does, plus
    /// tmux 3.4's `utf8_stravisx` (`VIS_OCTAL|VIS_CSTYLE|VIS_NOSLASH`) when asked.
    static func quoted(_ value: String, tmux34Escaped: Bool = false) -> String {
        let shellSpecial = Set("|&;<>()$`\\\"'*?[# =%".utf8)
        var shellBytes = Data()
        for byte in value.utf8 {
            if shellSpecial.contains(byte) { shellBytes.append(UInt8(ascii: "\\")) }
            shellBytes.append(byte)
        }
        guard tmux34Escaped else { return String(decoding: shellBytes, as: UTF8.self) }
        var out = Data()
        let bytes = Array(shellBytes)
        var index = 0
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x09 || b == 0x0a {
                out.append(b)
                index += 1
                continue
            }
            if b == 0x07 { out.append(contentsOf: "\\a".utf8); index += 1; continue }
            if b == 0x08 { out.append(contentsOf: "\\b".utf8); index += 1; continue }
            if b == 0x0b { out.append(contentsOf: "\\v".utf8); index += 1; continue }
            if b == 0x0c { out.append(contentsOf: "\\f".utf8); index += 1; continue }
            if b == 0x0d { out.append(contentsOf: "\\r".utf8); index += 1; continue }
            if b < 0x20 || b == 0x7f {
                let octal = String(b, radix: 8)
                let padded = String(repeating: "0", count: max(0, 3 - octal.count)) + octal
                out.append(contentsOf: ("\\" + padded).utf8)
                index += 1
                continue
            }
            if b == UInt8(ascii: "$"), index + 1 < bytes.count {
                let next = bytes[index + 1]
                let isIdent =
                    (next >= UInt8(ascii: "A") && next <= UInt8(ascii: "Z"))
                    || (next >= UInt8(ascii: "a") && next <= UInt8(ascii: "z"))
                    || next == UInt8(ascii: "_") || next == UInt8(ascii: "{")
                if isIdent {
                    out.append(contentsOf: "\\$".utf8)
                    index += 1
                    continue
                }
            }
            out.append(b)
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// One row: the line of ids and numbers, then the `#{q:...}` text fields.
    static func row(_ pane: TmuxInventory.Pane, instance: TmuxServerInstance, tmux34Escaped: Bool = false) -> Data {
        let texts = [
            pane.sessionName, pane.windowName, pane.command, pane.path, pane.status, pane.agentSession,
            pane.pipeMark, pane.attachMark, pane.worktree, pane.chatPick,
        ]
        let fixed: [String] = [
            String(instance.pid), String(instance.startTime), pane.sessionID, pane.windowID,
            String(pane.windowIndex), pane.paneID, String(pane.paneIndex), String(pane.processID),
            String(pane.width), String(pane.height), pane.isDead ? "1" : "0", pane.hasPipe ? "1" : "0",
        ]
        let header = fixed.joined(separator: "\t")
        let body = texts.map { quoted($0, tmux34Escaped: tmux34Escaped) }.joined(separator: " ") + " .\n"
        return Data((header + "\n" + body).utf8)
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
        arguments: [(pane: String, arguments: Arguments)] = [], nonce: String = nonce,
        tmux34Escaped: Bool = false
    ) -> Data {
        var text = Data("\(nonce) begin\n".utf8)
        for pane in panes { text.append(row(pane, instance: instance, tmux34Escaped: tmux34Escaped)) }
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
        pipeMark: String = "", attachMark: String = "", worktree: String = "", chatPick: String = "",
        arguments: [String]? = nil
    ) -> TmuxInventory.Pane {
        var made = TmuxInventory.Pane(
            sessionID: "$\(session)", sessionName: sessionName, windowID: "@\(window)", windowIndex: windowIndex,
            windowName: windowName, paneID: "%\(pane)", paneIndex: paneIndex, processID: processID,
            command: command, path: path, width: width, height: height, isDead: isDead, hasPipe: hasPipe,
            status: status, agentSession: agentSession, pipeMark: pipeMark, attachMark: attachMark,
            worktree: worktree, chatPick: chatPick)
        made.foregroundArguments = arguments
        return made
    }
}
