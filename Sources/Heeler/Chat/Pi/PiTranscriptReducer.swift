import Foundation

/// Pi/OMP v2-v3 JSONL is an append-only tree. Replay the latest selected
/// leaf's ancestry, including invisible extension/state entries. File order
/// alone would resurrect messages abandoned by /tree or a branch switch.
struct PiTranscriptReducer: ChatTranscriptReducer {
    static let revision = 10

    private struct Record: Sendable {
        let offset: UInt64
        let length: Int
        let value: JSONValue
        let isTruncated: Bool
        var type: String { value["type"]?.stringValue ?? "" }
        var id: String? { value["id"]?.stringValue }
        var parent: String? { value["parentId"]?.stringValue }
    }

    private var records: [UInt64: Record] = [:]
    private var invalid: Set<UInt64> = []
    private var oversized: Set<UInt64> = []
    /// Oh My Pi flags every message that steered a running turn; only
    /// Pi's steers are told apart by when they were written.
    private let flagsSteers: Bool

    init(program: ChatProgram = .pi) {
        flagsSteers = program == .omp
    }

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            if line.isTruncated {
                oversized.insert(line.offset)
            }
            // Preserve ids/parents before a large text or image block. The
            // shared structural prefix repair never invents a partial string.
            let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
            guard let data, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                value["type"]?.stringValue != nil
            else {
                invalid.insert(line.offset)
                continue
            }
            records[line.offset] = Record(
                offset: line.offset, length: line.length, value: value, isTruncated: line.isTruncated)
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    var unsupportedFormat: String? {
        for record in records.values where record.type == "session" {
            guard case .number(let version)? = record.value["version"], version == 2 || version == 3 else {
                return "Pi session without a supported v2/v3 tree"
            }
        }
        return nil
    }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        let ordered = records.values.sorted { $0.offset < $1.offset }
        var byID: [String: Record] = [:]
        var leaf: String?
        var title: String?
        var directory: String?
        for record in ordered {
            if record.type == "session" || record.type == "title" {
                if let name = record.value["title"]?.stringValue { title = name }
                if let cwd = record.value["cwd"]?.stringValue { directory = cwd }
                continue
            }
            guard let id = record.id else { continue }
            byID[id] = record
            if record.type == "model_usage", let active = record.value["activeLeafId"] {
                // Late usage belongs to an earlier call and must not
                // select that call's branch again.
                leaf = active.stringValue
            } else {
                leaf = id
            }
        }
        var chain: [Record] = []
        var seen: Set<String> = []
        var missingAncestor = false
        while let id = leaf, seen.insert(id).inserted {
            guard let record = byID[id] else {
                missingAncestor = true
                break
            }
            chain.append(record)
            leaf = record.parent
        }
        chain.reverse()

        var transcript = ChatTranscript(
            title: title, needsOlderHistory: context.windowStart > 0 || missingAncestor,
            diagnostics: ChatTranscriptDiagnostics(invalidLines: invalid.count, oversizedLines: oversized.count))
        var calls: [String: Int] = [:]
        /// The path each call names in its arguments, which Pi's edit
        /// result leaves out.
        var callPaths: [String: String] = [:]
        /// The `local://` files a free-form edit's patch names, by call id.
        var localPatchPaths: [String: [String]] = [:]
        /// The text each write call names, which its result leaves out,
        /// and the call's line, which an expanded row reads it from again.
        var writes: [String: (content: String, call: ChatOutputReference)] = [:]
        /// Calls that show no row, and whose results show none.
        var hiddenCalls: Set<String> = []

        func entryID(_ record: Record, _ suffix: String = "") -> ChatEntryID {
            ChatEntryID("pi:\(record.id ?? String(record.offset))\(suffix)")
        }
        func add(_ record: Record, _ content: ChatEntry.Content, _ suffix: String = "") {
            transcript.entries.append(
                ChatEntry(id: entryID(record, suffix), sourceOffset: record.offset, content: content))
        }
        func finish(_ ending: ChatTurn.Ending, at record: Record) {
            if let index = transcript.turns.indices.last {
                transcript.turns[index].ending = ending
                transcript.turns[index].endedAt = Self.date(record)
            } else {
                transcript.precedingTurnEnd = ChatTurnEnd(ending: ending, endedAt: Self.date(record))
            }
        }
        /// A prompt the user sent: it closes a turn still open and opens
        /// its own. `prompt` is the text pending-echo matching compares,
        /// as the program recorded what was sent.
        func openTurn(_ record: Record, _ content: ChatEntry.Content, prompt: String) {
            if let last = transcript.turns.indices.last, transcript.turns[last].ending == nil {
                transcript.turns[last].ending = .interrupted
                transcript.turns[last].endedAt = Self.date(record)
            }
            add(record, content)
            let id = entryID(record)
            transcript.turns.append(ChatTurn(firstEntryID: id, startedAt: Self.date(record)))
            if !record.isTruncated {
                transcript.recordedPrompts.append(ChatRecordedPrompt(offset: record.offset, text: prompt, entryID: id))
            }
            transcript.latestPromptOffset = record.offset
        }
        /// A prompt that steered the running turn: it stays in that turn,
        /// and the tools before it keep running.
        func joinTurn(_ record: Record, _ content: ChatEntry.Content, prompt: String) {
            add(record, content)
            if !record.isTruncated {
                transcript.recordedPrompts.append(
                    ChatRecordedPrompt(offset: record.offset, text: prompt, entryID: entryID(record)))
            }
        }
        func customNotice(_ record: Record, _ value: JSONValue) {
            guard value["display"] == .bool(true) else { return }
            add(
                record,
                .notice(
                    ChatNotice(
                        kind: .hook, title: value["customType"]?.stringValue ?? "Extension",
                        detail: Self.text(value["content"]))))
        }
        // The last assistant's stop reason says whether the branch's latest
        // turn ended, whatever opened it.
        var lastStopReason: String?
        // The latest tool result's text, until the next assistant message.
        var lastToolResultText: String?
        // When the latest tool result was written, while it is the last
        // message: a prompt Pi writes right after it is one it delivered
        // while the turn ran.
        var toolResultWrittenAt: Date?

        for (position, record) in chain.enumerated() {
            switch record.type {
            case "session_info", "title_change":
                // Pi clears a session's name with an empty one.
                if let name = record.value["name"]?.stringValue ?? record.value["title"]?.stringValue {
                    transcript.title = name.isEmpty ? nil : name
                }
            case "compaction":
                // Pi writes its summaries in Markdown, which neither row
                // draws: they preview, and read aloud, as plain lines.
                add(record, .divider(.compaction(summary: record.value["summary"]?.stringValue)))
            case "branch_summary":
                // Oh My Pi's atomic rewrite records the entry it dropped as
                // an empty summary, which is nothing to show.
                guard let summary = record.value["summary"]?.stringValue, !summary.isEmpty,
                    record.value["details"]?["kind"]?.stringValue != "discarded-entry-branch"
                else { continue }
                // Copy gives the summary as written.
                let plain = ChatMarkdown.plainText(summary)
                add(
                    record,
                    .notice(
                        ChatNotice(
                            kind: .system, title: "Branch summary", detail: plain,
                            rawDetail: plain == summary ? nil : summary)))
            case "reset_boundary":
                add(record, .notice(ChatNotice(kind: .system, title: "Conversation context cleared")))
            case "custom_message":
                // Oh My Pi records `/skill:name` as the expanded skill, with
                // the prompt as submitted in its details.
                if record.value["customType"]?.stringValue == "skill-prompt",
                    record.value["attribution"]?.stringValue != "agent",
                    let prompt = record.value["details"]?["prompt"]?.stringValue
                {
                    let message =
                        Self.skillCommand(prompt).map { ChatUserMessage(text: $0.displayText, command: $0) }
                        ?? ChatUserMessage(text: prompt)
                    openTurn(record, .user(message), prompt: prompt)
                    toolResultWrittenAt = nil
                } else {
                    customNotice(record, record.value)
                }
            case "message":
                guard let message = record.value["message"], let role = message["role"]?.stringValue else { continue }
                switch role {
                case "user":
                    let text = Self.text(message["content"])
                    let images = Self.images(message["content"])
                    // A message sent while a turn runs steers it. Oh My Pi
                    // flags it; Pi writes it as a plain prompt the moment
                    // the turn's tool batch ends, before its next reply. A
                    // turn whose reply broke off unrecorded, such as one
                    // resumed after its process died, still ends at a
                    // prompt. The turn may have opened above the lines read.
                    let isOpen =
                        transcript.turns.last.map { $0.ending == nil }
                        ?? (transcript.needsOlderHistory && transcript.precedingTurnEnd == nil)
                    let delivered =
                        !flagsSteers
                        && toolResultWrittenAt.flatMap { result in
                            Self.date(record).map { $0.timeIntervalSince(result) < Self.steerWriteWindow }
                        } == true
                    let steers = isOpen && (message["steering"] == .bool(true) || delivered)
                    let content: ChatEntry.Content
                    let prompt: String
                    if record.isTruncated, text.isEmpty, images == 0 {
                        content = .notice(ChatNotice(kind: .system, title: "Message exceeds the preview limit"))
                        prompt = text
                    } else if let skill = Self.piSkill(text) {
                        // Pi records `/skill:name args` as the skill's block
                        // followed by the arguments.
                        let invocation = ChatCommandInvocation(name: skill.name, arguments: skill.arguments)
                        content = .user(
                            ChatUserMessage(
                                text: invocation.displayText, imageCount: images, command: invocation,
                                wasQueued: steers))
                        prompt =
                            skill.arguments.isEmpty
                            ? "/skill:\(skill.name)" : "/skill:\(skill.name) \(skill.arguments)"
                    } else {
                        content = .user(ChatUserMessage(text: text, imageCount: images, wasQueued: steers))
                        prompt = text
                    }
                    if steers {
                        joinTurn(record, content, prompt: prompt)
                    } else {
                        openTurn(record, content, prompt: prompt)
                    }
                    toolResultWrittenAt = nil
                case "assistant":
                    let planProposed = lastToolResultText == Self.planReady
                    lastToolResultText = nil
                    for (index, block) in Self.blocks(message["content"]).enumerated() {
                        switch block["type"]?.stringValue {
                        case "text":
                            if let text = block["text"]?.stringValue, !text.isEmpty {
                                add(record, .assistant(ChatAssistantMessage(text: text)), ":\(index)")
                            }
                        case "thinking":
                            if let text = block["thinking"]?.stringValue, !text.isEmpty {
                                add(record, .reasoning(ChatReasoning(text: text)), ":\(index)")
                            }
                        case "toolCall":
                            guard let callID = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
                                continue
                            }
                            let path = block["arguments"]?["path"]?.stringValue
                            let device = Self.device(name: name, path: path)
                            // Oh My Pi hands a plan to its review screen as a
                            // write to `xd://propose`, which changes no file;
                            // the notice its turn ends with says so.
                            if device == Self.planDevice {
                                hiddenCalls.insert(callID)
                                continue
                            }
                            // Any other device is a tool Oh My Pi drives by a
                            // write to `xd://<tool>`, its arguments as JSON in
                            // `content`: a row for that tool, not a file.
                            let tool =
                                if let device {
                                    Self.tool(
                                        name: device, arguments: Self.deviceArguments(block["arguments"]),
                                        callID: callID, activity: context.activity, directory: directory)
                                } else {
                                    Self.tool(
                                        name: name, arguments: block["arguments"], callID: callID,
                                        activity: context.activity, directory: directory)
                                }
                            calls[callID] = transcript.entries.count
                            callPaths[callID] = device == nil ? path : nil
                            if device == nil, path == nil, let input = block["arguments"]?["input"]?.stringValue {
                                let local = PiFileChanges.patchPaths(input).filter { $0.hasPrefix(Self.localScheme) }
                                if !local.isEmpty { localPatchPaths[callID] = local }
                            }
                            if device == nil, name.lowercased() == "write",
                                let content = block["arguments"]?["content"]?.stringValue
                            {
                                writes[callID] = (content, ChatOutputReference(offset: record.offset, length: record.length))
                            }
                            transcript.entries.append(
                                ChatEntry(
                                    id: ChatEntryID("pi:tool:\(callID)"), sourceOffset: record.offset,
                                    content: .tool(tool)))
                        default: break
                        }
                    }
                    let stopReason = message["stopReason"]?.stringValue
                    let errorMessage = message["errorMessage"]?.stringValue
                    lastStopReason = stopReason
                    toolResultWrittenAt = nil
                    switch stopReason {
                    case "stop", "length": finish(.completed, at: record)
                    case "aborted" where errorMessage == Self.ompSilentAbort:
                        // Oh My Pi ends a turn this way when it hands over to
                        // its own screen, such as a plan to review.
                        if planProposed {
                            add(record, .notice(ChatNotice(kind: .system, title: "Plan ready for review")), ":end")
                        }
                        finish(.completed, at: record)
                    case "aborted":
                        add(record, .notice(ChatNotice(kind: .interrupted, title: "Interrupted")), ":end")
                        finish(.interrupted, at: record)
                    case "error" where errorMessage == Self.piAbort:
                        // Pi records Esc during a tool as an error.
                        add(record, .notice(ChatNotice(kind: .interrupted, title: "Interrupted")), ":end")
                        finish(.interrupted, at: record)
                    case "error":
                        add(
                            record,
                            .notice(
                                ChatNotice(
                                    kind: .error, title: "Agent error", detail: message["errorMessage"]?.stringValue)),
                            ":end")
                        // Pi retries a provider error on its own and records
                        // the retry as the error's reply. Until that is
                        // written, an Agent still working is retrying.
                        let next = chain[(position + 1)...].first {
                            $0.type == "message" || $0.type == "custom_message"
                        }
                        if next?.value["message"]?["role"]?.stringValue == "assistant"
                            || (next == nil && context.activity == .working)
                        {
                            lastStopReason = nil
                        } else {
                            finish(.failed, at: record)
                        }
                    default: break
                    }
                case "toolResult":
                    guard let callID = message["toolCallId"]?.stringValue else { continue }
                    let resultText = Self.text(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    lastToolResultText = resultText
                    toolResultWrittenAt = Self.date(record)
                    // A device's result names it in `details.xdev`, which
                    // tells a plan hand-off whose call is above the lines read.
                    let device = message["details"]?["xdev"]?["tool"]?.stringValue
                    let index = calls[callID]
                    if hiddenCalls.contains(callID) || (index == nil && device == Self.planDevice) { continue }
                    var tool: ChatToolActivity
                    if let index, case .tool(let existing) = transcript.entries[index].content {
                        tool = existing
                    } else {
                        tool = Self.tool(
                            name: device ?? message["toolName"]?.stringValue ?? "Tool", arguments: nil, callID: callID,
                            activity: context.activity, directory: directory)
                    }
                    // The write call whose text the row shows as its output.
                    var writtenBy: ChatOutputReference?
                    if message["isError"] == .bool(true) {
                        tool.status =
                            if resultText.hasPrefix(Self.deniedPrefix) || resultText == Self.askCancelled {
                                .declined
                            } else if Self.abortedResults.contains(resultText) {
                                .interrupted
                            } else {
                                .failed
                            }
                    } else {
                        tool.status = .succeeded
                        Self.recordAnswers(message["details"], in: &tool.questions)
                        if let changes = PiFileChanges.changes(
                            details: message["details"], callPath: callPaths[callID], directory: directory)
                        {
                            Self.show(
                                changes, in: &tool, namedByCall: callPaths[callID] != nil,
                                localPaths: localPatchPaths[callID] ?? [])
                        } else if let path = callPaths[callID], !path.isEmpty, let write = writes[callID],
                            !write.content.isEmpty
                        {
                            // A write records no diff and says nothing of what
                            // the file held before: its text, all added.
                            let file = ChatFileChange.allAdded(path: path, content: write.content, kind: .written)
                            Self.show(ChatFileChanges(files: [file], directory: directory), in: &tool, namedByCall: true)
                            writtenBy = write.call
                        }
                    }
                    tool.preview = Self.preview(message)
                    if record.isTruncated {
                        tool.preview?.isTruncated = true
                        tool.note = "Output exceeds the preview limit."
                    }
                    if tool.kind == .fileRead, tool.status == .succeeded {
                        tool.imagePath = Self.imagePath(
                            details: message["details"], callPath: callPaths[callID], directory: directory,
                            readImage: (tool.preview?.imageCount ?? 0) > 0
                                || resultText.hasPrefix(Self.imageReadPrefix),
                            isTruncated: record.isTruncated)
                    }
                    tool.output = writtenBy ?? ChatOutputReference(offset: record.offset, length: record.length)
                    if let index {
                        transcript.entries[index].content = .tool(tool)
                    } else {
                        calls[callID] = transcript.entries.count
                        transcript.entries.append(
                            ChatEntry(
                                id: ChatEntryID("pi:tool:\(callID)"), sourceOffset: record.offset, content: .tool(tool))
                        )
                    }
                case "custom", "hookMessage":
                    customNotice(record, message)
                case "developer":
                    break
                case "bashExecution":
                    add(
                        record,
                        .notice(
                            ChatNotice(
                                kind: .shellCommand, title: message["command"]?.stringValue ?? "Shell command",
                                detail: ChatToolPreview(capping: message["output"]?.stringValue ?? "").text)))
                case "pythonExecution":
                    // Oh My Pi's `$ code`, recorded as `!` is.
                    add(
                        record,
                        .notice(
                            ChatNotice(
                                kind: .pythonCommand, title: message["code"]?.stringValue ?? "Python",
                                detail: ChatToolPreview(capping: message["output"]?.stringValue ?? "").text)))
                default: transcript.diagnostics.unknownRecordTypes.insert("message:\(role)")
                }
            case "model_change", "thinking_level_change", "model_usage", "usage", "service_tier_change", "custom",
                "label",
                "context_edit", "session_init", "credential_pin", "ttsr_injection", "mode_change":
                break
            default: transcript.diagnostics.unknownRecordTypes.insert(record.type)
            }
        }
        let latestTurnOffset = transcript.latestPromptOffset ?? context.windowStart
        let ended = ["stop", "length", "aborted", "error"].contains(lastStopReason)
        for index in transcript.entries.indices {
            guard case .tool(var tool) = transcript.entries[index].content, tool.output == nil else { continue }
            if transcript.entries[index].sourceOffset < latestTurnOffset || ended { tool.status = .interrupted }
            if tool.status == .awaitingApproval {
                transcript.pendingRequests.append(
                    ChatPendingRequest(
                        entryID: transcript.entries[index].id, callID: tool.callID,
                        kind: tool.kind, toolName: tool.name, summary: tool.title, detail: tool.subtitle,
                        questions: tool.questions))
            }
            transcript.entries[index].content = .tool(tool)
        }
        return transcript
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard !line.isTruncated, let record = try? JSONDecoder().decode(JSONValue.self, from: line.data),
            record["type"]?.stringValue == "message", let message = record["message"]
        else { return nil }
        // A write's row reads its text from the call.
        if message["role"]?.stringValue == "assistant" {
            guard let file = tool.fileChanges?.files.first, file.kind == .written,
                let call = Self.blocks(message["content"]).first(where: {
                    $0["type"]?.stringValue == "toolCall" && $0["id"]?.stringValue == tool.callID
                }),
                let content = call["arguments"]?["content"]?.stringValue
            else { return nil }
            let changes = ChatFileChanges(
                files: [.allAdded(path: file.path, content: content, kind: .written)],
                directory: tool.fileChanges?.directory)
            return .preview(nil, fileChanges: changes)
        }
        guard message["role"]?.stringValue == "toolResult", message["toolCallId"]?.stringValue == tool.callID
        else { return nil }
        // Pi's path came from the call, which the row's changes kept.
        let fileChanges =
            message["isError"] == .bool(true)
            ? nil
            : PiFileChanges.changes(
                details: message["details"], callPath: tool.fileChanges?.files.first?.path,
                directory: tool.fileChanges?.directory)
        return .preview(Self.preview(message), fileChanges: fileChanges)
    }

    /// Lists an edit's files under its row. A call whose arguments named no
    /// path, such as Oh My Pi's free-form patch, takes its title from them,
    /// read as the list reads them. A file the patch named as
    /// `local://name`, which Oh My Pi resolves into the session's own
    /// `<session>/local/name`, keeps that name, as the read and write rows
    /// of the same file show it, rather than the account's session path.
    private static func show(
        _ changes: ChatFileChanges, in tool: inout ChatToolActivity, namedByCall: Bool, localPaths: [String] = []
    ) {
        tool.fileChanges = changes
        tool.diff = ChatDiffStats(
            added: changes.files.reduce(0) { $0 + $1.added }, removed: changes.files.reduce(0) { $0 + $1.removed },
            files: changes.files.count + changes.moreFiles)
        if !namedByCall, !changes.files.isEmpty {
            let names = changes.files.map { file in
                localPaths.first { file.path.hasSuffix("/local/" + $0.dropFirst(localScheme.count)) }
                    ?? changes.displayPath(of: file)
            }
            tool.title = String(names.joined(separator: ", ").prefix(500))
        }
    }

    /// Oh My Pi's scheme for the session's own planning files.
    private static let localScheme = "local://"

    /// How Pi and Oh My Pi begin a read's result when the file is an image,
    /// including one they could not attach (Pi 0.85.1 `read.js`).
    private static let imageReadPrefix = "Read image file ["

    /// The file a read showed as an image. Oh My Pi names it in the
    /// result's `details.mediaPath` (18.12.1); Pi records only the image,
    /// and the path in the call, relative to the session's directory
    /// (0.85.1). A result cut short may have lost its content; its path's
    /// extension decides then.
    private static func imagePath(
        details: JSONValue?, callPath: String?, directory: String?, readImage: Bool, isTruncated: Bool
    ) -> String? {
        let media = details?["mediaPath"]?.stringValue.flatMap { RemoteHostPath.isAbsolute($0) ? $0 : nil }
        guard let path = media ?? ChatImagePath.resolve(callPath, cwd: directory) else { return nil }
        return readImage || (isTruncated && ChatImagePath.hasImageExtension(path)) ? path : nil
    }

    private static func tool(
        name: String, arguments: JSONValue?, callID: String, activity: ChatAgentActivity, directory: String?
    ) -> ChatToolActivity {
        let kind: ChatToolActivity.Kind
        switch name.lowercased() {
        case "bash", "exec", "python": kind = .command
        case "read": kind = .fileRead
        case "edit", "apply_patch": kind = .fileEdit
        case "write": kind = .fileWrite
        // Oh My Pi 18 calls its file finder `glob`.
        case "grep", "find", "glob": kind = .search
        case "ls": kind = .listing
        case "web_search", "fetch", "browse": kind = .web
        case "task", "subagent": kind = .agent
        case "ask", "ask_user": kind = .question
        default: kind = .other
        }
        let questions = kind == .question ? Self.questions(arguments?["questions"]) : []
        // Paths read relative to the session's directory, and Oh My Pi's
        // free-form edit patch names its files only in its headers.
        let paths =
            (arguments?["path"]?.stringValue ?? arguments?["file_path"]?.stringValue).map { [$0] }
            ?? (kind == .fileEdit ? PiFileChanges.patchPaths(arguments?["input"]?.stringValue ?? "") : [])
        let pathTarget =
            paths.isEmpty
            ? nil : paths.map { ChatFileChanges.displayPath($0, in: directory) }.joined(separator: ", ")
        let target =
            arguments?["command"]?.stringValue ?? pathTarget ?? arguments?["pattern"]?.stringValue
            ?? arguments?["query"]?.stringValue ?? arguments?["url"]?.stringValue
        // A question's Blocked label is its first question. A call with no
        // target says what it is for in `i`.
        let summary = questions.first?.text ?? target ?? name
        let subtitle = target == nil && questions.isEmpty ? arguments?["i"]?.stringValue : nil
        let status: ChatToolActivity.Status =
            switch activity {
            case .working: .running
            case .blocked: .awaitingApproval
            default: .interrupted
            }
        return ChatToolActivity(
            kind: kind, name: name, title: String(summary.prefix(500)), subtitle: subtitle, status: status,
            questions: questions, callID: callID)
    }

    /// Oh My Pi's `ask` questions. Optional fields arrive as JSON null.
    private static func questions(_ value: JSONValue?) -> [ChatQuestion] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard let text = item["question"]?.stringValue else { return nil }
            var options: [ChatQuestion.Option] = []
            if case .array(let rows) = item["options"] {
                options = rows.compactMap { row in
                    row["label"]?.stringValue.map {
                        ChatQuestion.Option(label: $0, detail: row["description"]?.stringValue)
                    }
                }
            }
            var recommended: Int?
            if case .number(let index) = item["recommended"], let exact = Int(exactly: index),
                options.indices.contains(exact)
            {
                recommended = exact
            }
            return ChatQuestion(
                id: item["id"]?.stringValue, header: item["header"]?.stringValue, text: text, options: options,
                isMultiSelect: item["multi"] == .bool(true), recommendedIndex: recommended)
        }
    }

    /// The options an answered `ask` selected: one question's in
    /// `selectedOptions`, several questions' in `results` by id.
    private static func recordAnswers(_ details: JSONValue?, in questions: inout [ChatQuestion]) {
        func answer(_ value: JSONValue?) -> String? {
            guard case .array(let selected) = value?["selectedOptions"] else { return nil }
            let labels = selected.compactMap(\.stringValue)
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        }
        if case .array(let results) = details?["results"] {
            for result in results {
                guard let index = questions.firstIndex(where: { $0.id != nil && $0.id == result["id"]?.stringValue })
                else { continue }
                questions[index].answer = answer(result) ?? questions[index].answer
            }
        } else if questions.count == 1, let given = answer(details) {
            questions[0].answer = given
        }
    }

    /// Oh My Pi's `skill-prompt` as `/name arguments` when the prompt starts
    /// with its `/skill:` token; it may also sit mid-sentence.
    private static func skillCommand(_ prompt: String) -> ChatCommandInvocation? {
        let prefix = ChatCommandMenu.skillCommandPrefix
        guard prompt.hasPrefix(prefix) else { return nil }
        let rest = prompt.dropFirst(prefix.count)
        let name = rest.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        return ChatCommandInvocation(
            name: String(name),
            arguments: rest.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Pi's expanded `/skill:name args`, matched as Pi parses it back:
    /// `^<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n</skill>(?:\n\n([\s\S]+))?$`.
    private static func piSkill(_ text: String) -> (name: String, arguments: String)? {
        guard let header = text.prefixMatch(of: /<skill name="([^"]+)" location="[^"]+">\n/) else { return nil }
        let name = String(header.output.1)
        let rest = text[header.range.upperBound...]
        let closing = "\n</skill>"
        // The body is the shortest one after which only the arguments follow.
        var from = rest.startIndex
        while let range = rest.range(of: closing, range: from..<rest.endIndex) {
            let after = rest[range.upperBound...]
            if after.isEmpty { return (name, "") }
            if after.hasPrefix("\n\n"), !after.dropFirst(2).isEmpty { return (name, String(after.dropFirst(2))) }
            from = rest.index(after: range.lowerBound)
        }
        return nil
    }

    /// What Oh My Pi records for an assistant message that ends a turn
    /// without an interruption the user made.
    private static let ompSilentAbort = "__omp.silent_abort__"
    /// The result of Oh My Pi's plan proposal, before its review screen.
    private static let planReady = "Plan ready for review."
    /// The `xd://` device Oh My Pi proposes a plan through.
    private static let planDevice = "propose"
    /// Pi's assistant error for a turn the user stopped.
    private static let piAbort = "This operation was aborted"
    /// Oh My Pi's results for a call the user declined: an approval denied,
    /// or a question dismissed.
    private static let deniedPrefix = "Tool call denied by user:"
    private static let askCancelled = "Ask tool was cancelled by the user"
    /// How soon after a turn's tool results Pi writes a steer it delivers:
    /// observed within a millisecond, far below any prompt typed later.
    private static let steerWriteWindow: TimeInterval = 2
    /// Results of calls the user stopped while they ran.
    private static let abortedResults: Set<String> = ["Command aborted", "Operation aborted"]

    /// The device a write to `xd://<tool>` or `xd://<tool>/<topic>` drives:
    /// Oh My Pi mounts discoverable tools there (setting `tools.xdev`, on by
    /// default in 18.11).
    private static func device(name: String, path: String?) -> String? {
        guard name.lowercased() == "write", let path, path.hasPrefix(devicePrefix) else { return nil }
        let device = path.dropFirst(devicePrefix.count).prefix { $0 != "/" }
        return device.isEmpty ? nil : String(device)
    }

    private static let devicePrefix = "xd://"

    /// A device call's arguments: the JSON object its write's `content` holds.
    private static func deviceArguments(_ arguments: JSONValue?) -> JSONValue? {
        guard let content = arguments?["content"]?.stringValue, let data = content.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func blocks(_ content: JSONValue?) -> [JSONValue] {
        if case .array(let blocks) = content { return blocks }
        if case .string(let text) = content { return [.object(["type": .string("text"), "text": .string(text)])] }
        return []
    }

    private static func text(_ content: JSONValue?) -> String {
        blocks(content).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(
            separator: "\n")
    }

    private static func images(_ content: JSONValue?) -> Int {
        blocks(content).filter { $0["type"]?.stringValue == "image" }.count
    }

    private static func preview(_ message: JSONValue) -> ChatToolPreview {
        ChatToolPreview(capping: text(message["content"]), imageCount: images(message["content"]))
    }

    private static func date(_ record: Record) -> Date? {
        if let text = record.value["timestamp"]?.stringValue {
            return Date.ISO8601FormatStyle(includingFractionalSeconds: true).parseStrategy.parseOptional(text)
                ?? Date.ISO8601FormatStyle().parseStrategy.parseOptional(text)
        }
        return nil
    }
}

extension ParseStrategy where ParseInput == String, ParseOutput == Date {
    fileprivate func parseOptional(_ input: String) -> Date? { try? parse(input) }
}
