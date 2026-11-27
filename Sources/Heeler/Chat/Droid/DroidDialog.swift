import Foundation

/// Each answer belongs to one live process on one instance of its terminal server.
struct DroidDialogTarget: Equatable, Sendable {
    var scope: String
    var pid: String
    var start: String
    var directory: String
    var sessionID: String?
    var transcriptFolder: String? = nil
    var userHooksDisabled = false

    /// Devin slugs are local to an account's SQLite store. A resumed writer
    /// can have a new PID and still own the same draft.
    func draftID(for program: ChatProgram) -> String? {
        guard let sessionID else { return nil }
        if program == .devin {
            guard let transcriptFolder else { return nil }
            return transcriptFolder + "#" + sessionID
        }
        return sessionID
    }

    func shows(_ dialog: BlockedDialog) -> Bool {
        if [.droidWorkspaceTrust, .devinWorkspaceTrust].contains(dialog.kind) {
            if dialog.kind == .devinWorkspaceTrust, sessionID != nil { return false }
            guard let path = dialog.subject.workspacePath else { return false }
            // /cd asks about a new destination while the current session and
            // process still belong to the old directory.
            if dialog.options.last?.role == .decline { return sessionID != nil }
            return path == directory || (["/tmp/", "/var/"].contains { directory.hasPrefix($0) } && path == "/private" + directory)
        }
        return sessionID != nil
    }
}

/// Factory Droid 1.21.1. Only a complete, active footer can identify a page.
enum DroidDialog {
    private static let trustFooter = "Enter to confirm · Esc to exit"
    private static let changeDirectoryFooter = "Enter to confirm · Esc to cancel"
    private static let askFooter = "Tab/⇧Tab or ←/→ Questions • ↑/↓ Navigate • Space/Enter/1–9 Select • ESC stop agent"
    private static let singleAskFooter = "↑/↓ Navigate • Space/Enter/1–9 Select • ESC stop agent"
    private static let fieldFooter = "Tab/⇧Tab Questions • Enter Continue • ⇧Enter newline • ↑ back to options • ESC stop agent"
    private static let reviewFooter = "←/⇧Tab Edit answers • Enter Submit • ESC stop agent"

    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        let rows = screen.rows
        guard let end = rows.lastIndex(where: { !$0.isBlank }) else { return .none }
        let footer = words(rows[end].trimmedText)
        let dialog: BlockedDialog?
        if footer == trustFooter || footer == changeDirectoryFooter {
            dialog = trust(rows, end, changesDirectory: footer == changeDirectoryFooter)
        } else if [askFooter, singleAskFooter, fieldFooter, reviewFooter].contains(footer) {
            dialog = question(rows, end, footer)
        } else if approvalFooter(footer) {
            dialog = approval(rows, end)
        } else if footer.contains("Tab reasoning") {
            dialog = spec(rows, end, footer)
        } else { return .none }
        if let dialog { return .dialog(dialog) }
        let excerpt = Array(rows[max(0, end - 22)...end])
        let reason = excerpt.contains { $0.trimmedText.hasPrefix("Tool to approve · ") }
            ? String(localized: "Review this tool and its permissions in the Droid terminal. Factory has not identified a matching tool request in this session.")
            : String(localized: "Open the Droid terminal to review the full prompt.")
        return .unrecognized(.init(rows: excerpt, numbered: [:],
            reason: reason,
            fingerprint: .init(program: .droid, excerptRows: excerpt.map(\.text))))
    }

    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func approvalFooter(_ text: String) -> Bool {
        let prefix = "↑↓ navigate Enter select Esc cancel "
        guard text.hasPrefix(prefix) else { return false }
        let detail = "Alt/Option+E to inspect approval details"
        let footers = [prefix + detail, prefix + "Ctrl+O expand diff " + detail]
        if text.hasSuffix("…"), text.count > prefix.count + 1 {
            return footers.contains { $0.hasPrefix(text.dropLast()) }
        }
        return footers.contains(text)
    }

    private static func border(_ text: String, _ left: Character, _ right: Character) -> Bool {
        text.count >= 4 && text.first == left && text.last == right && text.dropFirst().dropLast().allSatisfy { $0 == "─" }
    }

    private static func inside(_ row: ScreenRow) -> String? {
        let text = row.trimmedText
        guard text.first == "│", text.last == "│", text.count > 1 else { return nil }
        return text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    }

    private static func frame(_ rows: [ScreenRow], before index: Int) -> Range<Int>? {
        guard let last = rows[..<index].lastIndex(where: { !$0.isBlank }),
              border(rows[last].trimmedText, "╰", "╯"),
              let top = rows[..<last].lastIndex(where: { border($0.trimmedText, "╭", "╮") }),
              last > top + 1, rows[(top + 1)..<last].allSatisfy({ inside($0) != nil }) else { return nil }
        return (top + 1)..<last
    }

    private static func trust(_ rows: [ScreenRow], _ end: Int, changesDirectory: Bool) -> BlockedDialog? {
        let choices = rows.indices[..<end].filter { !rows[$0].isBlank }.suffix(2)
        let labels = ["1. Trust this folder", changesDirectory ? "2. Don't trust (cancel)" : "2. Exit without trusting"]
        guard let first = choices.first, choices.count == 2,
              let box = frame(rows, before: first) else { return nil }
        let lines = box.compactMap { inside(rows[$0]) }
        let blocks = lines.split(whereSeparator: \.isEmpty)
        guard blocks.count == 3, blocks[0].first == "Trust this folder?", blocks[0].count > 1 else { return nil }
        let pathRows = Array(box.dropFirst().prefix { inside(rows[$0]) != "" })
        let painted = pathRows.map { i in rows[i].runs.filter { $0.style.isBold }.map(\.text).joined() }
        guard pathRows.count == 1 || painted.allSatisfy({ !$0.isEmpty }) else { return nil }
        let path = painted.allSatisfy({ !$0.isEmpty }) ? painted.joined() : blocks[0].dropFirst().joined()
        let explanation = blocks[1].joined(separator: " ")
        let warning = blocks[2].joined(separator: " ")
        guard RemoteFilePath.isAcceptable(path), !path.contains("…"),
              explanation.hasPrefix("Droid will read, edit, and run files in this folder"),
              explanation.hasSuffix("execute commands on your machine."), warning.hasSuffix("before trusting it.") else { return nil }
        var options: [DialogOption] = []
        for (offset, index) in choices.enumerated() {
            let text = rows[index].trimmedText
            let focused = text.hasPrefix("> ")
            guard (focused ? String(text.dropFirst(2)) : text) == labels[offset] else { return nil }
            options.append(.init(ordinal: offset + 1, number: nil, label: String(labels[offset].dropFirst(3)),
                                 role: offset == 0 ? .trust : (changesDirectory ? .decline : .exitProgram), isFocused: focused))
        }
        guard options.filter(\.isFocused).count == 1 else { return nil }
        return make(.droidWorkspaceTrust, "Trust this folder?", [path, explanation, warning], options,
                    box.lowerBound..<end + 1, .init(workspacePath: path))
    }

    private static func highlighted(_ row: ScreenRow) -> Bool {
        row.runs.contains { $0.style.isBold && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func approval(_ rows: [ScreenRow], _ end: Int) -> BlockedDialog? {
        guard let optionsBox = frame(rows, before: end) else { return nil }
        var options: [DialogOption] = []
        var labels: [(text: String, focused: Bool)] = []
        for index in optionsBox {
            guard let line = inside(rows[index]) else { return nil }
            if line == "Yes, allow" || line.hasPrefix("Yes, and always allow ") || line == "No, cancel" {
                labels.append((line, highlighted(rows[index])))
            } else if !labels.isEmpty, labels[labels.count - 1].text.hasPrefix("Yes, and always allow ") {
                labels[labels.count - 1].text += " " + line
            } else { return nil }
        }
        for (label, focus) in labels {
            let role: DialogOptionRole
            if label == "Yes, allow" { role = .approve }
            else if label == "No, cancel" { role = .decline }
            else if label.hasPrefix("Yes, and always allow "), label.hasSuffix(")") { role = .approveModeSwitch }
            else { return nil }
            options.append(.init(ordinal: options.count + 1, number: nil, label: label, role: role, isFocused: focus))
        }
        guard options.first?.role == .approve, options.last?.role == .decline,
              options.filter(\.isFocused).count == 1 else { return nil }
        let top = optionsBox.lowerBound - 1
        guard let before = rows[..<top].lastIndex(where: { !$0.isBlank }) else { return nil }
        if let start = rows[...before].lastIndex(where: { $0.trimmedText.hasPrefix("Command to approve · ") }),
           start < before, rows[start + 1].trimmedText.hasPrefix("↳ ") {
            let wrapped = [String(rows[start + 1].trimmedText.dropFirst(2))]
                + rows[(start + 2)..<(before + 1)].map(\.trimmedText)
            let command = wrapped.joined(separator: " ")
            guard !command.isEmpty else { return nil }
            return make(.droidPermission, rows[start].trimmedText, [command], options, start..<end + 1,
                        .init(toolName: "Execute", command: command, commandRows: wrapped))
        }
        guard let diff = frame(rows, before: top), let heading = rows[..<(diff.lowerBound - 1)].lastIndex(where: { !$0.isBlank }),
              let match = rows[heading].trimmedText.wholeMatch(of: /(Create|Edit|Update) (.+): \((.+)\)/) else { return nil }
        let path = String(match.2)
        let changes = diff.compactMap { inside(rows[$0]) }
        return make(.droidPermission, rows[heading].trimmedText, [path] + changes, options, heading..<end + 1,
                    .init(toolName: String(match.1), filePath: path, changeLines: changes))
    }

    enum PatchReview: Equatable {
        case ordinaryCommand, file(String), terminal
    }

    /// Only one literal operand in the displayed working directory identifies a
    /// patch Chat can show in full. Compound commands and stdin need the terminal.
    static func patchReview(command: String, directory: String) -> PatchReview {
        if let match = command.wholeMatch(of: #/git[ \t]+apply[ \t]+(?:--[ \t]+)?(?:'([^'\r\n]+)'|"([^"\\\x24\x60\r\n]+)"|([\p{L}\p{M}\p{N}._/+@%-]+))/#),
           let operand = match.1 ?? match.2 ?? match.3, !operand.hasPrefix("/"), !operand.hasPrefix("-"),
           RemoteFilePath.isAcceptable(directory) {
            let parts = operand.split(separator: "/").filter { $0 != "." }
            let path = RemoteFilePath.join(directory, parts.joined(separator: "/"))
            if !parts.isEmpty, !operand.hasSuffix("/"), RemoteFilePath.isAcceptable(path) { return .file(path) }
        }
        let shell = command.filter { !["'", "\"", "\\"].contains($0) }
        let words = shell.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        if (words.contains("git") && words.contains("apply"))
            || shell.contains(#/(?:^|[/\s;&|()])(?:g?patch|apply_patch)(?:$|[\s;&|()<>])/#) { return .terminal }
        return .ordinaryCommand
    }

    static func matchesCommandRows(_ fragments: [String], command: String) -> Bool {
        var rest = command[...]
        for (index, fragment) in fragments.enumerated() {
            if index > 0, rest.first == " ", !rest.hasPrefix(fragment) { rest.removeFirst() }
            guard !fragment.isEmpty, rest.hasPrefix(fragment) else { return false }
            rest = rest.dropFirst(fragment.count)
        }
        return !fragments.isEmpty && rest.isEmpty
    }

    static func elidedCommand(_ displayed: String, matches full: String) -> Bool {
        let parts = displayed.components(separatedBy: "...")
        return parts.count == 2 && parts[0].count >= 12 && parts[1].count >= 12
            && full.count > parts[0].count + parts[1].count
            && full.hasPrefix(parts[0]) && full.hasSuffix(parts[1])
    }

    static func details(_ screen: ANSIScreen, show command: String) -> Bool {
        let lines = screen.rows.map(\.trimmedText).filter { !$0.isEmpty }
        guard lines.count >= 3, lines.first == "Approval details",
              lines.last == "Esc / Alt/Option+E to return", lines[1].hasPrefix("Execute ") else { return false }
        return matchesCommandRows([String(lines[1].dropFirst(8))] + lines.dropFirst(2).dropLast(), command: command)
    }

    private static func question(_ rows: [ScreenRow], _ end: Int, _ footer: String) -> BlockedDialog? {
        guard let start = rows[..<end].lastIndex(where: { $0.trimmedText == "Ask User" }), start + 2 < end else { return nil }
        let single = footer == singleAskFooter
        let page = single ? nil : rows[start + 1].trimmedText.replacingOccurrences(of: "●", with: "○")
        let lines = (start + (single ? 1 : 2)..<end).filter {
            let text = rows[$0].trimmedText
            return !text.isEmpty && text != "Hooks Notification → elicitation_dialog"
                && !text.hasPrefix("├─ ") && !text.hasPrefix("└─ ")
        }
        guard let first = lines.first, let last = lines.last else { return nil }
        let texts = lines.map { rows[$0].trimmedText }
        if footer == reviewFooter {
            guard texts.first == "Review your answers", texts.last == "❯ Submit answers" else { return nil }
            return make(.droidQuestionReview, "Review your answers", Array(texts.dropFirst().dropLast()), [
                .init(ordinal: 1, number: nil, label: "Submit answers", role: .submit, isFocused: true),
                .init(ordinal: 2, number: nil, label: "Edit answers", role: .answer)
            ], start..<end + 1, .init(), progress: page)
        }
        guard let choice = lines.first(where: { rows[$0].trimmedText.hasPrefix("1. ") }),
              first < choice, choice < last else { return nil }
        let body = lines.prefix { $0 < choice }.map { rows[$0].trimmedText }
        var options: [DialogOption] = []
        for index in lines where index >= choice && index < last {
            let number = options.count + 1
            let prefix = "\(number). "
            guard rows[index].trimmedText.hasPrefix(prefix), number <= 9 else { return nil }
            options.append(.init(ordinal: number, number: number, label: String(rows[index].trimmedText.dropFirst(prefix.count)),
                                 role: .answer, isFocused: highlighted(rows[index])))
        }
        let placeholder = "Or type your own answer..."
        let field = rows[last].trimmedText
        guard footer == fieldFooter || field == placeholder else { return nil }
        options.append(.init(ordinal: options.count + 1, number: nil, label: placeholder, role: .otherText,
                             isFocused: footer == fieldFooter, input: field == placeholder ? .placeholder(placeholder) : .text(field)))
        return make(.droidQuestion, "Ask User", body, options, start..<end + 1,
                    .init(question: body.first), progress: page, input: field == placeholder ? nil : field)
    }

    private static func spec(_ rows: [ScreenRow], _ end: Int, _ footer: String) -> BlockedDialog? {
        guard let box = frame(rows, before: end),
              let pathRow = rows[..<(box.lowerBound - 1)].lastIndex(where: { !$0.isBlank }),
              rows[pathRow].trimmedText.hasPrefix("Will save to: ") else { return nil }
        let path = String(rows[pathRow].trimmedText.dropFirst("Will save to: ".count))
        let lines = box.compactMap { inside(rows[$0]) }
        var options: [DialogOption] = []
        let kind: BlockedDialogKind
        var input: String?
        if footer.hasPrefix("↑↓ navigate 1-5 select"), lines.count == 5,
           lines[0] == "1. Proceed with the proposal", lines[1] == "2. Proceed with comment",
           lines[2].hasPrefix("3. Proceed and handoff to a new session"),
           ["4. Manually edit spec (open via system default)", "4. Manually edit spec (xdg-open via system default)"].contains(lines[3]),
           lines[4] == "5. No and explain why" {
            kind = .droidSpec
        } else if footer.hasPrefix("↑↓ navigate 1-4 select"), lines == [
            "1. Proceed with Manual Approvals", "2. Proceed with Low autonomy",
            "3. Proceed with Medium autonomy", "4. Proceed with High autonomy"] {
            kind = .droidSpecAutonomy
        } else if footer == "Enter submit ⇧Enter newline Tab reasoning ESC go back", let line = lines.first, lines.count == 1 {
            let prefix = "Comment: ", placeholder = "Add guidance for the implementation..."
            guard line.hasPrefix(prefix) else { return nil }
            let value = String(line.dropFirst(prefix.count))
            input = value == placeholder ? nil : value
            kind = .droidSpecFeedback
            options = [.init(ordinal: 1, number: nil, label: placeholder, role: .otherText, isFocused: true,
                             input: input.map(InputRowState.text) ?? .placeholder(placeholder))]
        } else { return nil }
        if options.isEmpty {
            for (index, line) in lines.enumerated() {
                options.append(.init(ordinal: index + 1, number: index + 1, label: String(line.dropFirst(3)),
                                     role: .answer, isFocused: highlighted(rows[box.lowerBound + index])))
            }
        }
        return make(kind, kind == .droidSpecAutonomy ? "Choose autonomy" : "Review proposal", [path], options,
                    pathRow..<end + 1, .init(planFilePath: path), input: input)
    }

    private static func make(
        _ kind: BlockedDialogKind, _ title: String, _ body: [String], _ options: [DialogOption],
        _ rows: Range<Int>, _ subject: DialogSubject, progress: String? = nil, input: String? = nil
    ) -> BlockedDialog {
        .init(kind: kind, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: progress,
              options: options, rows: rows, fingerprint: .init(program: .droid, kind: kind, title: title,
              sourceSuffix: nil, body: body, progress: progress, options: options),
              focus: .init(focusedOrdinal: options.first(where: \.isFocused)?.ordinal, inputText: input), subject: subject)
    }

    static func plan(_ action: DialogAction, _ dialog: BlockedDialog, callID: String?) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.kind == .droidWorkspaceTrust || callID != nil else {
            throw .unsupported(String(localized: "Waiting for Droid to identify this request. You can also answer in its terminal."))
        }
        var builder = StepBuilder(dialog: dialog)
        switch action {
        case .dismiss:
            builder.keys("esc")
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            switch dialog.kind {
            case .droidWorkspaceTrust, .droidPermission:
                if [.exitProgram, .decline].contains(option.role) { builder.keys("esc") }
                else { try builder.move(to: ordinal); builder.keys("enter") }
            case .droidQuestionReview:
                builder.keys(option.role == .submit ? "enter" : "left")
            case .droidQuestion, .droidSpec, .droidSpecAutonomy:
                guard let digit = DialogActionPlanner.digitKey(option.number), dialog.focus.inputText == nil,
                      dialog.option(dialog.focus.focusedOrdinal ?? 0)?.role != .otherText else {
                    throw .unsupported(String(localized: "Finish editing the answer in the Droid terminal."))
                }
                builder.keys(digit)
            default: throw .noSuchOption(ordinal)
            }
        case .respond(let ordinal, let text):
            guard let field = dialog.option(ordinal), field.role == .otherText, dialog.focus.inputText == nil else {
                throw .unsupported(String(localized: "Finish editing the answer in the Droid terminal."))
            }
            let value = try DialogActionPlanner.fieldText(text)
            if dialog.kind == .droidQuestion { try builder.move(to: ordinal) }
            builder.paste(value)
            builder.expect(.inputText(value))
            builder.keys("enter")
        default: throw .unsupported(String(localized: "Open the Droid terminal for this action."))
        }
        return .init(steps: builder.steps, confirmation: .fingerprintChange)
    }
}
