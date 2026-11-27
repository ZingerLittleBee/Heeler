import Foundation

/// Devin CLI 3000.15.14. A chooser must own the last nonblank row and show
/// exactly one focus. Scrollback and partially visible choices cannot act.
enum DevinDialog {
    private static let selectFooter = "↑↓ select · ↵ confirm · esc cancel"
    private static let scopeFooter = "↑↓ select · ←→ 1-4 scope · e edit · ↵ confirm · esc cancel"
    private static let scopes = ["Once", "Session", "Project", "Always"]
    private static let trustTitle = "Do you trust the authors of this directory?"
    private static let trustNote = "For security, devin should not be run in directories with untrusted content."

    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        let lines = screen.rows.map(\.trimmedText)
        guard let end = lines.lastIndex(where: { !$0.isEmpty }) else { return .none }
        let footerStart = lines.indices[max(0, end - 2)...end].last { lines[$0].hasPrefix("↑↓ select") } ?? end
        let footer = lines[footerStart...end].joined(separator: " ")
        let dialog: BlockedDialog?
        if footer == selectFooter || footer == scopeFooter {
            let visible = lines[..<footerStart].indices.filter { !lines[$0].isEmpty }
            guard let last = visible.last else { return .none }
            if label(lines[last]) == "2 No, exit" { dialog = trust(lines, visible, end) }
            else if label(lines[last]).hasPrefix("3 No") { dialog = proposal(lines, visible, end) }
            else { dialog = permission(lines, visible, end, scoped: footer == scopeFooter) }
        } else if footer.hasPrefix("↑↓ select · ↵ confirm · "), footer.contains("? help me out"),
                  footer.hasSuffix("esc cancel") || footer.hasSuffix("esc clear") {
            dialog = question(lines, footerStart: footerStart, end: end)
        } else { return .none }
        if let dialog { return .dialog(dialog) }
        let rows = Array(screen.rows[max(0, end - 18)...end])
        return .unrecognized(.init(rows: rows, numbered: [:], reason: String(localized: "Open Devin’s terminal to review this prompt."),
                                   fingerprint: .init(program: .devin, excerptRows: rows.map(\.text))))
    }

    private static func label(_ row: String) -> String {
        row.hasPrefix("❭ ") ? String(row.dropFirst(2)) : row
    }

    private static func trust(_ lines: [String], _ visible: [Int], _ end: Int) -> BlockedDialog? {
        guard visible.count >= 5, let start = visible.last(where: { lines[$0] == "✱ " + trustTitle }) else { return nil }
        let inside = Array(visible.filter { $0 > start }.dropLast(2))
        guard let pathStart = inside.firstIndex(where: { lines[$0].hasPrefix("/") }),
              inside[..<pathStart].map({ lines[$0] }).joined(separator: " ") == trustNote else { return nil }
        let path = inside[pathStart...].map { lines[$0] }.joined()
        let indices = Array(visible.suffix(2))
        guard RemoteFilePath.isAcceptable(path), indices.map({ label(lines[$0]) }) == ["1 Yes, trust", "2 No, exit"] else { return nil }
        let choices = indices.enumerated().map { index, i in
            DialogOption(ordinal: index + 1, number: index + 1, label: String(label(lines[i]).dropFirst(2)),
                         role: index == 0 ? .trust : .exitProgram, isFocused: lines[i].hasPrefix("❭ "))
        }
        return make(.devinWorkspaceTrust, trustTitle, [path, trustNote], choices, start...end, .init(workspacePath: path))
    }

    private static func permission(_ lines: [String], _ visible: [Int], _ end: Int, scoped: Bool) -> BlockedDialog? {
        guard let last = visible.last, label(lines[last]) == "Deny",
              let first = visible.last(where: { label(lines[$0]).hasPrefix("Allow  ") }),
              let header = visible.last(where: { $0 < first && (lines[$0].hasPrefix("⏺ ") || lines[$0].hasPrefix("● ")) }) else { return nil }
        let title = String(lines[header].dropFirst(2))
        var subject = DialogSubject()
        let body = visible.filter { $0 > header && $0 < first }.map { lines[$0] }
        let allow = label(lines[first])
        let scope: String
        if scoped {
            guard title == "Running command", let line = body.first, !body.contains(where: { $0.hasSuffix("…") }) else { return nil }
            var fragments: [String]
            if body.count == 1, line.hasPrefix("└ $ ") {
                fragments = [String(line.dropFirst(4))]
            } else {
                guard body.count > 1, line.hasPrefix("│ $ "), body.last?.hasPrefix("└   ") == true,
                      body.dropFirst().dropLast().allSatisfy({ $0.hasPrefix("│   ") }) else { return nil }
                fragments = body.map { String($0.dropFirst(4)) }
            }
            let words = allow.split(whereSeparator: \.isWhitespace)
            guard let i = words.firstIndex(where: { scopes.contains(String($0)) }), i + 1 < words.count,
                  let selected = scopes.firstIndex(of: String(words[i])) else { return nil }
            scope = words[(i + 1)...].joined(separator: " ")
            subject.devinScope = selected + 1
            subject.toolName = "exec"
            subject.commandRows = fragments
            subject.command = fragments.joined(separator: " ")
        } else {
            if title.hasPrefix("Writing ") {
                subject.toolName = "write"
                subject.filePath = String(title.dropFirst(8))
            } else if title.hasPrefix("Editing ") {
                subject.toolName = "edit"
                subject.filePath = String(title.dropFirst(8))
            } else { return nil }
            scope = String(allow.dropFirst("Allow  ".count))
            subject.changeLines = body
        }
        guard !scope.isEmpty, scope.hasSuffix(")"), !scope.contains("…") else { return nil }
        let indices = visible.filter { $0 >= first }
        var options: [DialogOption] = []
        for (i, index) in indices.enumerated() {
            let text = label(lines[index])
            if i == 0, let selected = subject.devinScope {
                for (position, name) in scopes.enumerated() {
                    options.append(.init(ordinal: position + 1, number: nil, label: "Allow · " + name,
                                         detail: scope, role: position == 0 ? .approve : .approvePersistent,
                                         isFocused: selected == position + 1 && lines[index].hasPrefix("❭ ")))
                }
                continue
            }
            let role: DialogOptionRole
            if i == 0 { role = .approve }
            else if text == "Accept edits mode" || text == "Bypass mode" { role = .approveModeSwitch }
            else if i == indices.count - 1, text == "Deny" { role = .decline }
            else { return nil }
            options.append(.init(ordinal: options.count + 1, number: nil, label: i == 0 ? "Allow" : text,
                                 detail: i == 0 ? scope : nil, role: role, isFocused: lines[index].hasPrefix("❭ ")))
        }
        return make(.devinPermission, title, [scope] + body, options, header...end, subject)
    }

    private static func proposal(_ lines: [String], _ visible: [Int], _ end: Int) -> BlockedDialog? {
        guard let header = visible.last(where: { ["● Starting implementation", "⏺ Starting implementation"].contains(lines[$0]) }),
              let file = visible.last(where: { lines[$0].hasPrefix("└ Plan file: ") }), header < file else { return nil }
        let text = visible.filter { $0 > header && $0 < file }.map { line in
            lines[line].hasPrefix("│") ? String(lines[line].dropFirst()).trimmingCharacters(in: .whitespaces) : lines[line]
        }
        let labels = ["Yes, switch to accept edits mode", "Yes, switch to bypass mode", "No"]
        let options = visible.filter { $0 > file }
        guard options.count == labels.count, !text.isEmpty else { return nil }
        var choices: [DialogOption] = []
        for (i, position) in options.enumerated() {
            let value = label(lines[position])
            let name = "\(i + 1) " + labels[i]
            guard value == name || (value.hasPrefix(name + "  (") && value.hasSuffix(")")) else { return nil }
            choices.append(.init(ordinal: i + 1, number: i + 1, label: labels[i],
                                 role: i < 2 ? .approveModeSwitch : .decline, isFocused: lines[position].hasPrefix("❭ ")))
        }
        return make(.devinPlan, "Starting implementation", text, choices, header...end,
                    .init(planFilePath: String(lines[file].dropFirst("└ Plan file: ".count))))
    }

    private static func question(_ lines: [String], footerStart: Int, end: Int) -> BlockedDialog? {
        let indices = lines[..<footerStart].indices.filter { !lines[$0].isEmpty }
        guard let bottom = indices.last, lines[bottom].allSatisfy({ $0 == "─" }),
              let top = indices.last(where: { $0 < bottom && lines[$0].hasPrefix("── ") && lines[$0].hasSuffix("─") }),
              let title = indices.first(where: { $0 > top }),
              let first = indices.first(where: { $0 > title && (label(lines[$0]).hasPrefix("1 ") || label(lines[$0]).hasPrefix("· ")) }) else { return nil }
        let prompt = indices.filter { $0 >= title && $0 < first }.map { lines[$0] }.joined(separator: " ")
        // Devin adds a check to the current tab as free text is entered.
        // The unique question and options in the pending call identify the page.
        let tab = lines[top].trimmingCharacters(in: CharacterSet(charactersIn: "─ "))
            .replacingOccurrences(of: " ✓", with: "")
        let data = Array(indices.filter { $0 >= first && $0 < bottom })
        var options: [DialogOption] = []
        var pos = 0
        var typed: String?
        while pos < data.count {
            let raw = lines[data[pos]], value = label(raw)
            let n = options.count + 1
            let item = value.hasPrefix("\(n) ") ? String(value.dropFirst(String(n).count + 1)) :
                value.hasPrefix("· ") ? String(value.dropFirst(2)) : value
            let other = item == "Other"
            guard other || value != item, pos + 1 < data.count else { return nil }
            let detail = lines[data[pos + 1]]
            let focused = raw.hasPrefix("❭ ")
            if other, focused, detail.hasPrefix("└") {
                let input = String(detail.dropFirst()).trimmingCharacters(in: .whitespaces)
                typed = input.isEmpty ? nil : input
            }
            options.append(.init(ordinal: n, number: other ? nil : n, label: item,
                                 detail: other ? nil : detail, role: other ? .otherText : .answer, isFocused: focused,
                                 input: other ? typed.map(InputRowState.text) ?? .placeholder("type your own") : nil))
            pos += 2
        }
        guard options.last?.role == .otherText else { return nil }
        return make(.devinQuestion, prompt, [prompt], options, top...end, .init(question: prompt), progress: tab, typed: typed)
    }

    private static func make(_ kind: BlockedDialogKind, _ title: String, _ body: [String], _ options: [DialogOption],
                             _ rows: ClosedRange<Int>, _ subject: DialogSubject, progress: String? = nil,
                             typed: String? = nil) -> BlockedDialog? {
        guard options.filter(\.isFocused).count == 1 else { return nil }
        return .init(kind: kind, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: progress,
                     options: options, rows: rows.lowerBound..<(rows.upperBound + 1),
                     fingerprint: .init(program: .devin, kind: kind, title: title, sourceSuffix: nil,
                                        body: body, progress: progress, options: options),
                     focus: .init(focusedOrdinal: options.first(where: \.isFocused)?.ordinal, inputText: typed), subject: subject)
    }

    static func plan(_ action: DialogAction, _ dialog: BlockedDialog, call: String?) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.kind == .devinWorkspaceTrust || call != nil else {
            throw .unsupported(String(localized: "Waiting for Devin to identify the request in this terminal."))
        }
        var builder = StepBuilder(dialog: dialog)
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal), option.role != .otherText else { throw .noSuchOption(ordinal) }
            if let selected = dialog.subject.devinScope {
                guard var focus = dialog.focus.focusedOrdinal else { throw .noFocus }
                while (focus > 4 || ordinal > 4) && focus != ordinal {
                    let down = ordinal > focus
                    let next = down ? max(5, focus + 1) : (focus == 5 ? selected : focus - 1)
                    builder.keys(down ? "down" : "up")
                    builder.expect(.focus(ordinal: next))
                    focus = next
                }
                while focus != ordinal {
                    let right = focus < ordinal
                    focus += right ? 1 : -1
                    builder.keys(right ? "right" : "left")
                    builder.expect(.focus(ordinal: focus))
                }
            } else {
                try builder.move(to: ordinal)
            }
            builder.keys("enter")
        case .respond(let ordinal, let text):
            guard dialog.option(ordinal)?.role == .otherText, dialog.focus.inputText == nil else {
                throw .unsupported(String(localized: "Finish editing the answer in Devin’s terminal."))
            }
            let answer = try DialogActionPlanner.fieldText(text)
            try builder.move(to: ordinal)
            builder.paste(answer)
            builder.expect(.inputText(answer))
            builder.keys("enter")
        case .dismiss:
            guard dialog.focus.inputText == nil else { throw .unsupported(String(localized: "Finish editing the answer in Devin’s terminal.")) }
            builder.keys("esc")
        default: throw .unsupported(String(localized: "Open Devin’s terminal for this action."))
        }
        return .init(steps: builder.steps, confirmation: .fingerprintChange)
    }
}
