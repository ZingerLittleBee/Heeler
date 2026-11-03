import Foundation

/// How an OpenCode tool call shows as a row: its kind by name, its title
/// from its input, its status from its state, and its output.
enum OpenCodeToolSummary {
    /// The errors OpenCode records for a call the user declined, or a
    /// question the user dismissed. Either ends the turn with no `idle` row.
    static let declinedMessages: Set<String> = ["The user declined this tool call", "The user dismissed this question"]

    /// The line that ends an output OpenCode itself shortened.
    static let shortenedNote = "[OpenCode shortened this output. The full output stays on the Host.]"

    /// The row for `tool` as its step recorded it, its output read again
    /// from `output`. The reducer settles a running call by its turn.
    /// `directory` is the folder the session was in at the call.
    static func activity(_ tool: OpenCodeTool, output: ChatOutputReference, directory: String?) -> ChatToolActivity {
        let kind = kind(of: tool.name)
        let status = status(of: tool)
        let questions = questions(of: tool)
        let label = label(of: tool, kind: kind)
        var activity = ChatToolActivity(
            kind: kind, name: tool.name, title: String(label.title.prefix(500)), subtitle: label.subtitle,
            status: status, exitCode: status == .failed ? tool.metadata?.exit : nil, questions: questions,
            callID: tool.callID, preview: preview(of: tool, kind: kind, questions: questions), output: output)
        if kind == .fileRead, status == .succeeded { activity.imagePath = imagePath(of: tool, directory: directory) }
        if let changes = fileChanges(of: tool) {
            activity.fileChanges = changes
            activity.diff = ChatDiffStats(
                added: changes.files.reduce(0) { $0 + $1.added }, removed: changes.files.reduce(0) { $0 + $1.removed },
                files: changes.files.count + changes.moreFiles)
            // A patch names its files only in its text; the changes name
            // them as the row lists them.
            if path(of: tool) == nil, !changes.files.isEmpty {
                let names = changes.files.map { changes.displayPath(of: $0) }
                activity.title = String(names.joined(separator: ", ").prefix(500))
            }
        }
        return activity
    }

    /// `tool`'s output, decoded again for an expanded row.
    static func output(of tool: OpenCodeTool) -> ChatToolOutput {
        .preview(
            preview(of: tool, kind: kind(of: tool.name), questions: questions(of: tool)),
            fileChanges: fileChanges(of: tool))
    }

    /// The first matching kind wins: `ast_grep_replace` edits, the other
    /// `ast_grep_*` tools search.
    static func kind(of name: String) -> ChatToolActivity.Kind {
        let name = name.lowercased()
        switch name {
        case "shell", "bash", "interactive_bash", "execute": return .command
        case "read": return .fileRead
        case "edit", "patch", "apply_patch", "ast_grep_replace": return .fileEdit
        case "write": return .fileWrite
        case "grep", "glob", "codesearch": return .search
        case "list", "ls": return .listing
        case "webfetch", "websearch": return .web
        case "subagent", "task", "call_omo_agent": return .agent
        case "question": return .question
        case "todowrite", "todoread": return .todo
        case "mcp-resource": return .mcp
        default: break
        }
        if name.hasPrefix("grep_app_") || name.hasPrefix("ast_grep_") { return .search }
        if name.hasPrefix("websearch_") { return .web }
        return .other
    }

    static func status(of tool: OpenCodeTool) -> ChatToolActivity.Status {
        switch tool.status {
        case "completed":
            if let exit = tool.metadata?.exit, exit != 0 { return .failed }
            // A call that left its work running in the background, such
            // as a background subagent, completes saying so.
            return tool.metadata?.status == "running" ? .started : .succeeded
        case "error":
            guard tool.error?.type == "aborted" else { return .failed }
            return declinedMessages.contains(tool.error?.message ?? "") ? .declined : .interrupted
        default:
            return .running
        }
    }

    /// The path the call's input names.
    private static func path(of tool: OpenCodeTool) -> String? {
        tool.input.filePath ?? tool.input.path
    }

    private static func label(of tool: OpenCodeTool, kind: ChatToolActivity.Kind) -> (title: String, subtitle: String?) {
        let input = tool.input
        switch kind {
        case .agent:
            let agent = input.agent ?? input.subagentType
            guard let description = input.description else { return (agent ?? tool.name, nil) }
            return (description, agent)
        case .question:
            return (input.questions.first?.question ?? tool.name, nil)
        case .other:
            guard tool.name.lowercased() == "skill" else { return (tool.name, nil) }
            return ((tool.metadata?.name ?? input.id).map { "Skill \($0)" } ?? tool.name, nil)
        default:
            let patchPaths = input.patchText.map(PiFileChanges.patchPaths) ?? []
            let target =
                path(of: tool) ?? input.command ?? input.pattern ?? input.url ?? input.query
                ?? (patchPaths.isEmpty ? nil : patchPaths.joined(separator: ", "))
            return (target ?? tool.name, nil)
        }
    }

    /// The questions a question tool asked, each with its answer once given.
    private static func questions(of tool: OpenCodeTool) -> [ChatQuestion] {
        let answers = tool.metadata?.answers ?? []
        return tool.input.questions.enumerated().compactMap { index, question in
            guard let text = question.question else { return nil }
            let labels = answers.indices.contains(index) ? answers[index] : []
            return ChatQuestion(
                header: question.header, text: text,
                options: question.options.compactMap { option in
                    option.label.map { ChatQuestion.Option(label: $0, detail: option.description) }
                },
                isMultiSelect: question.multiple == true,
                answer: labels.isEmpty ? nil : labels.joined(separator: ", "))
        }
    }

    /// The output as the row shows it: the call's content, a subagent's
    /// without its wrapper, or the answers a question was given. Nil when
    /// the call recorded none.
    private static func preview(
        of tool: OpenCodeTool, kind: ChatToolActivity.Kind, questions: [ChatQuestion]
    ) -> ChatToolPreview? {
        let answers = questions.compactMap(\.answer)
        if tool.status == "completed", !answers.isEmpty {
            return ChatToolPreview(capping: "Answered: " + answers.joined(separator: "; "))
        }
        guard var text = tool.output else {
            // A call that failed records its error, and may record nothing else.
            guard tool.status == "error", tool.error?.type != "aborted", let message = tool.error?.message else {
                return nil
            }
            return ChatToolPreview(capping: message)
        }
        let isCut = (tool.outputLength ?? 0) > text.unicodeScalars.count
        if kind == .agent { text = subagentResult(text) }
        if tool.metadata?.truncated == true, !isCut {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + shortenedNote
        }
        var preview = ChatToolPreview(capping: text)
        if isCut { preview.isTruncated = true }
        return preview
    }

    /// A subagent's result without the `<subagent …>` element around it.
    private static func subagentResult(_ text: String) -> String {
        guard text.hasPrefix("<subagent "), let end = text.firstIndex(of: "\n"), text[..<end].hasSuffix(">") else {
            return text
        }
        var result = text[text.index(after: end)...]
        if result.hasSuffix("</subagent>") { result = result.dropLast("</subagent>".count) }
        if result.hasSuffix("\n") { result = result.dropLast() }
        return String(result)
    }

    /// The files a completed call changed.
    private static func fileChanges(of tool: OpenCodeTool) -> ChatFileChanges? {
        guard tool.status == "completed" else { return nil }
        return OpenCodeFileChanges.changes(tool.metadata, callPath: path(of: tool))
    }

    /// The Host file a read showed as an image. OpenCode 2 returns the image
    /// named as the path it read, which is relative to the session's folder
    /// when the input's was. A 1.x read records an absolute `filePath` and
    /// no image, so its extension decides.
    private static func imagePath(of tool: OpenCodeTool, directory: String?) -> String? {
        if let image = tool.image { return ChatImagePath.resolve(image, cwd: directory) }
        guard let path = path(of: tool), RemoteHostPath.isAbsolute(path), ChatImagePath.hasImageExtension(path)
        else { return nil }
        return path
    }
}
