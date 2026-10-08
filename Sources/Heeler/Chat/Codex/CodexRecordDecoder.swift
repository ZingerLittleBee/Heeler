import Foundation

/// The two shapes a rollout's history takes (`session_meta.history_mode`).
enum CodexRolloutDialect: String, Equatable, Sendable, Codable {
    /// Every line has an ordinal; visible history is `item_completed` turn
    /// items.
    case paginated
    /// No ordinals; visible history is legacy events plus tool response items.
    case legacy
}

/// What decoding one line produced.
struct CodexLineOutcome: Equatable, Sendable {
    var record: CodexRecord?
    /// False when Codex itself would reject the line, so it must not take an
    /// ordinal: a torn crash fragment, an unknown record type.
    var isAccepted = true
    var isInvalid = false
    /// The line was too long to keep whole and its content had to be skipped.
    var isOversized = false
    /// A record, event or item type this adapter does not know.
    var unknownType: String?

    static let accepted = CodexLineOutcome()
    static let invalid = CodexLineOutcome(isAccepted: false, isInvalid: true)
    static let oversized = CodexLineOutcome(isOversized: true)

    static func unknown(_ type: String, accepted: Bool = false) -> CodexLineOutcome {
        CodexLineOutcome(isAccepted: accepted, unknownType: type)
    }
}

/// Turns one classified line into a record.
///
/// Decoding is the expensive step, so it runs only for lines that can show
/// something; everything else is checked for shape and skipped. A truncated
/// line is decoded from its repaired prefix when the fields that matter come
/// first (a tool item's argv and status), and skipped as oversized when the
/// content is the message itself.
enum CodexRecordDecoder {
    struct Context: Equatable, Sendable {
        var dialect: CodexRolloutDialect
        /// The session's working directory, for relative paths in titles.
        var cwd: String?
        /// The longest tool output decoded; an expanded row reading one
        /// again raises it.
        var outputDecodeLimit = CodexRecordDecoder.outputDecodeLimit
    }

    /// Event types some Codex version persists. Others are unknown to this
    /// adapter, and to the Codex that reads the file, which skips them
    /// without spending their ordinal.
    static let knownEventTypes: Set<String> = [
        "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted",
        "token_count", "thread_settings_applied", "thread_goal_updated", "thread_rolled_back",
        "user_message", "agent_message", "agent_reasoning", "agent_reasoning_raw_content",
        "context_compacted", "patch_apply_end", "mcp_tool_call_end", "web_search_end",
        "image_generation_end", "sub_agent_activity", "entered_review_mode", "exited_review_mode",
    ]

    static let knownItemTypes: Set<CodexItemType> = [
        .userMessage, .agentMessage, .reasoning, .plan, .contextCompaction, .hookPrompt,
        .commandExecution, .fileChange, .mcpToolCall, .webSearch, .extension, .dynamicToolCall,
        .functionCallOutput, .imageView, .imageGeneration, .collabAgentToolCall,
        .subAgentActivity, .enteredReviewMode, .exitedReviewMode,
    ]

    /// Item types a legacy rollout's `item_completed` contributes
    /// (`handle_materialized_item_lifecycle`).
    static let legacyItemTypes: Set<CodexItemType> = [
        .plan, .hookPrompt, .functionCallOutput, .commandExecution, .dynamicToolCall,
        .collabAgentToolCall, .subAgentActivity, .extension, .enteredReviewMode, .exitedReviewMode,
    ]

    /// Tool outputs up to this size are decoded while following: question
    /// answers and legacy previews. Larger ones only resolve their call.
    static let outputDecodeLimit = 256 * 1_024

    /// The text Codex records when a question closes unanswered.
    static let cancelledQuestionOutput = "request_user_input was cancelled before receiving a response"

    static func decode(
        _ line: ChatLine, as classification: CodexLineClassification, in context: Context
    ) -> CodexLineOutcome {
        switch classification.kind {
        case .sessionMeta, .ignorable:
            return shapeChecked(line)
        case .compacted:
            let outcome = shapeChecked(line)
            guard outcome.isAccepted, context.dialect == .legacy else { return outcome }
            return CodexLineOutcome(record: .compacted)
        case .unknown(let type):
            return .unknown(type)
        case .unclassified:
            return .invalid
        case .event(let type):
            return decodeEvent(type, line, context)
        case .item(let type):
            return decodeItem(CodexItemType(rawValue: type), line, context)
        case .response(let type):
            return decodeResponse(type, line, classification, context)
        case .retainedContext(let type):
            return decodeRetained(type, line)
        }
    }

    /// A line that is never decoded: accepted when it is one whole object.
    /// A truncated line cannot be checked and is trusted.
    private static func shapeChecked(_ line: ChatLine) -> CodexLineOutcome {
        guard !line.isTruncated else { return .accepted }
        return CodexJSONPrefix.isCompleteObject(line.data) ? .accepted : .invalid
    }

    /// Decodes a whole line, or a truncated line's repaired prefix.
    private static func envelope<Payload: Decodable>(_ line: ChatLine, _ type: Payload.Type) -> CodexEnvelope<Payload>? {
        let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
        guard let data else { return nil }
        return try? JSONDecoder().decode(CodexEnvelope<Payload>.self, from: data)
    }

    private static func reference(_ line: ChatLine) -> ChatOutputReference {
        ChatOutputReference(offset: line.offset, length: line.length)
    }

    // MARK: Events

    private static func decodeEvent(_ type: String, _ line: ChatLine, _ context: Context) -> CodexLineOutcome {
        guard knownEventTypes.contains(type) else { return .unknown("event_msg/\(type)") }
        let legacy = context.dialect == .legacy
        switch type {
        case "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted":
            break
        case "user_message", "agent_message", "agent_reasoning":
            guard legacy else { return shapeChecked(line) }
            if line.isTruncated { return .oversized }
        case "context_compacted", "thread_rolled_back", "patch_apply_end", "mcp_tool_call_end",
            "web_search_end", "image_generation_end", "sub_agent_activity", "entered_review_mode",
            "exited_review_mode":
            guard legacy else { return shapeChecked(line) }
        default:
            return shapeChecked(line)
        }
        guard let event = envelope(line, CodexRawEvent.self)?.payload else {
            return line.isTruncated ? .oversized : .invalid
        }
        switch eventRecord(type, event, line, context) {
        case .record(let record):
            return CodexLineOutcome(record: record)
        case .nothing:
            return .accepted
        case .malformed:
            return line.isTruncated ? .oversized : .invalid
        }
    }

    private enum EventResult {
        case record(CodexRecord)
        /// A valid event with nothing to show.
        case nothing
        /// The event lacks a field Codex requires, so Codex rejects the line.
        case malformed
    }

    private static func turnTimes(_ event: CodexRawEvent) -> CodexTurnTimes {
        func date(_ seconds: Double?) -> Date? {
            guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        return CodexTurnTimes(startedAt: date(event.turnStartedAt), completedAt: date(event.turnCompletedAt))
    }

    private static func eventRecord(
        _ type: String, _ event: CodexRawEvent, _ line: ChatLine, _ context: Context
    ) -> EventResult {
        switch type {
        case "task_started", "turn_started":
            return event.turnID.map { .record(.turnStarted(turnID: $0, times: turnTimes(event))) } ?? .malformed
        case "task_complete", "turn_complete":
            return event.turnID.map {
                .record(.turnCompleted(turnID: $0, error: event.errorMessage, times: turnTimes(event)))
            } ?? .malformed
        case "turn_aborted":
            return .record(
                .turnAborted(
                    turnID: event.turnID, reason: event.reason ?? .interrupted, error: event.errorMessage,
                    times: turnTimes(event)))
        case "user_message":
            let text = event.message ?? ""
            if CodexMessageFormatter.isContextualLegacyMessage(text, kind: event.kind) {
                return .nothing
            }
            let audio = Array(repeating: "Audio", count: event.audioCount)
            return .record(
                .userMessage(
                    CodexUserContent(
                        text: text, imageCount: event.imageCount + event.localImages.count,
                        localImagePaths: event.localImages, attachmentLabels: audio)))
        case "agent_message":
            return .record(
                .agentMessage(
                    agentContent(
                        text: event.message ?? "", phase: event.phase, delivery: event.delivery,
                        questions: event.questions)))
        case "agent_reasoning":
            return .record(.reasoning(event.text ?? ""))
        case "context_compacted":
            return .record(.contextCompacted)
        case "thread_rolled_back":
            return event.numTurns.map { .record(.rolledBack(turns: max(0, $0))) } ?? .malformed
        case "patch_apply_end":
            guard let callID = event.callID else { return .malformed }
            let summary = CodexToolSummary.fileChangeSummary(event.changes ?? [:], cwd: context.cwd)
            let status = event.status?.chatStatus ?? (event.success == false ? .failed : .succeeded)
            let snapshot = CodexToolSnapshot(
                kind: summary.kind, name: "apply_patch", title: summary.title.isEmpty ? "Patch" : summary.title,
                status: status, diff: summary.diff, callID: callID,
                preview: CodexToolSummary.preview(joinedOutput(event.stdout, event.stderr)),
                output: reference(line))
            let turn = event.turnID.flatMap { $0.isEmpty ? nil : $0 }
            return .record(.legacyItem(CodexItem(id: callID, content: .tool(snapshot)), .turnOrCurrent(turn)))
        case "mcp_tool_call_end":
            guard let callID = event.callID else { return .malformed }
            let failed = event.mcpResult?.ok == nil || event.mcpResult?.ok?.isError == true
            let snapshot = CodexToolSnapshot(
                kind: .mcp, name: mcpName(event.server, event.tool), title: mcpName(event.server, event.tool),
                status: failed ? .failed : .succeeded, callID: callID,
                preview: CodexToolSummary.mcpPreview(event.mcpResult?.ok, error: event.mcpResult?.error),
                output: reference(line))
            let turn = event.turnID.flatMap { $0.isEmpty ? nil : $0 }
            return .record(.legacyItem(CodexItem(id: callID, content: .tool(snapshot)), .turnOrCurrent(turn)))
        case "web_search_end":
            guard let callID = event.callID else { return .malformed }
            let snapshot = CodexToolSnapshot(
                kind: .web, name: "web_search",
                title: CodexToolSummary.webSearchTitle(query: event.query, action: event.action),
                status: .succeeded, callID: callID, output: reference(line))
            return .record(.legacyItem(CodexItem(id: callID, content: .tool(snapshot)), .current))
        case "image_generation_end":
            guard let callID = event.callID else { return .malformed }
            let snapshot = imageGeneration(
                id: callID, status: event.status?.rawValue, revisedPrompt: event.revisedPrompt,
                savedPath: event.savedPath, line: line, context: context)
            return .record(.legacyItem(CodexItem(id: callID, content: .tool(snapshot)), .current))
        case "sub_agent_activity":
            guard let id = event.eventID else { return .malformed }
            let snapshot = subAgentActivity(path: event.agentPath, kind: event.kind)
            return .record(.legacyItem(CodexItem(id: id, content: .tool(snapshot)), .current))
        case "entered_review_mode", "exited_review_mode":
            let entered = type == "entered_review_mode"
            let id = event.itemID ?? "review@\(line.offset)"
            let content = CodexItem.Content.review(
                title: entered ? "Review started" : "Review finished",
                detail: entered ? (event.userFacingHint ?? "Review requested.") : event.reviewExplanation)
            return .record(.legacyItem(CodexItem(id: id, content: content), .review(event.turnID)))
        default:
            return .nothing
        }
    }

    // MARK: Turn items

    private static func decodeItem(_ type: CodexItemType, _ line: ChatLine, _ context: Context) -> CodexLineOutcome {
        guard knownItemTypes.contains(type) else { return .unknown("item_completed/\(type.rawValue)") }
        if context.dialect == .legacy, !legacyItemTypes.contains(type) {
            return shapeChecked(line)
        }
        if line.isTruncated, type.isMessage {
            return .oversized
        }
        // The ids precede everything large, so a prefix without them is too
        // short to place anything.
        guard let event = envelope(line, CodexRawEvent.self)?.payload, let raw = event.item,
            let turnID = event.turnID, let id = raw.id
        else {
            return line.isTruncated ? .oversized : .invalid
        }
        var outcome = CodexLineOutcome()
        guard let content = itemContent(type, raw, event, line, context, unknownType: &outcome.unknownType) else {
            return outcome
        }
        let item = CodexItem(id: id, content: content)
        if context.dialect == .legacy {
            let placement: CodexLegacyPlacement =
                type == .enteredReviewMode || type == .exitedReviewMode ? .review(turnID) : .turn(turnID)
            outcome.record = .legacyItem(item, placement)
        } else {
            outcome.record = .item(turnID: turnID, item)
        }
        return outcome
    }

    private static func itemContent(
        _ type: CodexItemType, _ raw: CodexRawItem, _ event: CodexRawEvent, _ line: ChatLine,
        _ context: Context, unknownType: inout String?
    ) -> CodexItem.Content? {
        let complete = !line.isTruncated
        switch type {
        case .userMessage:
            return .user(userContent(raw.content ?? []))
        case .agentMessage:
            let text = (raw.content ?? []).compactMap(\.text).joined()
            let content = agentContent(text: text, phase: raw.phase, delivery: raw.delivery, questions: raw.questions)
            return content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.questions.isEmpty
                ? nil : .agent(content)
        case .reasoning:
            let text = (raw.summaryText ?? []).filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var duration: Int?
            if let start = event.startedAtMilliseconds, let end = event.completedAtMilliseconds, end >= start {
                duration = Int(end - start)
            }
            return .reasoning(text, durationMilliseconds: duration)
        case .plan:
            guard let text = raw.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return .plan(text)
        case .contextCompaction:
            return .compaction
        case .hookPrompt:
            let text = (raw.fragments ?? []).compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            return .hook(text)
        case .commandExecution:
            let argv = raw.command ?? []
            let (kind, subtitle) = CodexToolSummary.commandKind(raw.parsedCommands ?? [])
            var status = raw.status?.chatStatus
            if status == .succeeded, let code = raw.exitCode, code != 0 {
                status = .failed
            }
            return .tool(
                CodexToolSnapshot(
                    kind: kind, name: raw.source == "user_shell" ? "user_shell" : "CommandExecution",
                    title: argv.isEmpty || (!complete && raw.cwd == nil) ? "Command" : CodexToolSummary.commandTitle(argv),
                    subtitle: subtitle,
                    status: status, exitCode: raw.exitCode, callID: raw.id,
                    preview: complete ? CodexToolSummary.preview(raw.aggregatedOutput) : nil,
                    output: reference(line)))
        case .fileChange:
            // A prefix drops the diff it cut, so its counts would be short.
            let summary = CodexToolSummary.fileChangeSummary(raw.changes ?? [:], cwd: context.cwd)
            return .tool(
                CodexToolSnapshot(
                    kind: summary.kind, name: "FileChange", title: summary.title.isEmpty ? "Patch" : summary.title,
                    status: raw.status?.chatStatus, diff: complete ? summary.diff : nil, callID: raw.id,
                    preview: complete ? CodexToolSummary.preview(joinedOutput(raw.stdout, raw.stderr)) : nil,
                    output: reference(line)))
        case .mcpToolCall:
            var status = raw.status?.chatStatus
            if status == .succeeded, raw.result?.isError == true {
                status = .failed
            }
            let name = mcpName(raw.server, raw.tool)
            return .tool(
                CodexToolSnapshot(
                    kind: .mcp, name: name, title: name, status: status, callID: raw.id,
                    preview: complete ? CodexToolSummary.mcpPreview(raw.result, error: raw.errorMessage) : nil,
                    output: reference(line)))
        case .webSearch:
            return .tool(
                CodexToolSnapshot(
                    kind: .web, name: "WebSearch",
                    title: CodexToolSummary.webSearchTitle(query: raw.query, action: raw.action),
                    status: .succeeded, callID: raw.id, output: reference(line)))
        case .extension:
            switch raw.kind {
            case "image_gen.generation":
                return .tool(
                    imageGeneration(
                        id: raw.id ?? "", status: raw.status?.rawValue, revisedPrompt: raw.revisedPrompt,
                        savedPath: raw.savedPath, line: line, context: context))
            case "clock.sleep":
                return .tool(
                    CodexToolSnapshot(
                        kind: .other, name: "clock.sleep", title: sleepTitle(raw.durationMilliseconds),
                        status: .succeeded, callID: raw.id, output: reference(line)))
            case "web.search":
                return .tool(
                    CodexToolSnapshot(
                        kind: .web, name: "web.search",
                        title: CodexToolSummary.webSearchTitle(query: raw.query, action: raw.action),
                        status: .succeeded, callID: raw.id, output: reference(line)))
            default:
                unknownType = "item_completed/Extension/\(raw.kind ?? "")"
                return nil
            }
        case .dynamicToolCall:
            let name = raw.namespace.map { "\($0).\(raw.tool ?? "")" } ?? raw.tool ?? "tool"
            let text = (raw.contentItems ?? []).compactMap(\.text).joined(separator: "\n")
            var status = raw.status?.chatStatus
            if status == nil, let success = raw.success {
                status = success ? .succeeded : .failed
            }
            return .tool(
                CodexToolSnapshot(
                    kind: .other, name: name, title: name, status: status, callID: raw.id,
                    preview: complete ? CodexToolSummary.preview(raw.errorMessage ?? text) : nil,
                    output: reference(line)))
        case .functionCallOutput:
            let name = raw.namespace.map { "\($0).\(raw.name ?? "")" } ?? raw.name ?? "tool"
            return .tool(
                CodexToolSnapshot(
                    kind: .other, name: name, title: name, status: .succeeded, callID: raw.id,
                    preview: complete
                        ? CodexToolSummary.preview(raw.output?.text, imageCount: raw.output?.imageCount ?? 0) : nil,
                    output: reference(line)))
        case .imageView:
            return .tool(
                CodexToolSnapshot(
                    kind: .image, name: "ImageView",
                    title: raw.path.map { CodexToolSummary.relativePath(fileURLPath($0), cwd: context.cwd) }
                        ?? "Image",
                    status: .succeeded, callID: raw.id, output: reference(line)))
        case .imageGeneration:
            return .tool(
                imageGeneration(
                    id: raw.id ?? "", status: raw.status?.rawValue, revisedPrompt: raw.revisedPrompt,
                    savedPath: raw.savedPath, line: line, context: context))
        case .collabAgentToolCall:
            let tool = raw.tool ?? "agent"
            let prompt = raw.prompt.flatMap { firstLine($0) }
            return .tool(
                CodexToolSnapshot(
                    kind: .agent, name: tool, title: prompt ?? tool.replacingOccurrences(of: "_", with: " "),
                    subtitle: prompt == nil ? nil : tool, status: raw.status?.chatStatus, callID: raw.id,
                    output: reference(line)))
        case .subAgentActivity:
            return .tool(subAgentActivity(path: raw.agentPath, kind: raw.kind))
        case .enteredReviewMode:
            return .review(title: "Review started", detail: raw.userFacingHint ?? "Review requested.")
        case .exitedReviewMode:
            return .review(title: "Review finished", detail: raw.reviewExplanation)
        default:
            unknownType = "item_completed/\(type.rawValue)"
            return nil
        }
    }

    // MARK: Response items

    private static func decodeResponse(
        _ type: String, _ line: ChatLine, _ classification: CodexLineClassification, _ context: Context
    ) -> CodexLineOutcome {
        let legacy = context.dialect == .legacy
        switch type {
        case "function_call":
            var classification = classification
            if classification.name == nil, let whole = reclassified(line) {
                classification = whole
            }
            if classification.name == "request_user_input" {
                return decodeQuestionCall(line, context)
            }
            return legacy ? decodeCall(type, line, classification, context) : shapeChecked(line)
        case "custom_tool_call", "local_shell_call":
            return legacy ? decodeCall(type, line, classification, context) : shapeChecked(line)
        case "function_call_output":
            return decodeOutput(line, classification, context)
        case "custom_tool_call_output":
            return legacy ? decodeOutput(line, classification, context) : shapeChecked(line)
        case "message" where legacy && classification.role == "user":
            guard !line.isTruncated, line.data.range(of: Data("<hook_prompt".utf8)) != nil else {
                return shapeChecked(line)
            }
            guard let response = envelope(line, CodexRawResponse.self)?.payload else { return .invalid }
            guard let hook = hookPrompt(response.content ?? []) else { return .accepted }
            let id = response.id ?? "hook@\(line.offset)"
            return CodexLineOutcome(record: .legacyItem(CodexItem(id: id, content: .hook(hook)), .current))
        default:
            return shapeChecked(line)
        }
    }

    /// The line classified from all the bytes it has, for a field the
    /// default prefix cut off (`call_id` follows a function call's
    /// arguments). Nil when the default prefix already covered the line.
    private static func reclassified(_ line: ChatLine) -> CodexLineClassification? {
        guard line.data.count > CodexLineClassifier.prefixLimit else { return nil }
        return CodexLineClassifier.classify(line.data, limit: line.data.count)
    }

    private static func decodeQuestionCall(_ line: ChatLine, _ context: Context) -> CodexLineOutcome {
        guard !line.isTruncated else { return .oversized }
        guard let response = envelope(line, CodexRawResponse.self)?.payload else { return .invalid }
        guard let callID = response.callID else { return .accepted }
        let call = CodexQuestionCall(
            callID: callID, turnID: response.turnID, questions: syncQuestions(response.arguments))
        return CodexLineOutcome(
            record: context.dialect == .legacy
                ? .toolCall(CodexToolCall(callID: callID, role: .question(call.questions)))
                : .questionCall(call))
    }

    /// A tool output. A paginated rollout needs only question answers from
    /// outputs, so one without the word `answers` (or the cancellation text)
    /// is never decoded: it still resolves its call by id, in case that call
    /// was a question Codex closed. Legacy rollouts decode outputs for their
    /// exit code and preview, up to the context's `outputDecodeLimit`.
    private static func decodeOutput(
        _ line: ChatLine, _ classification: CodexLineClassification, _ context: Context
    ) -> CodexLineOutcome {
        let decodes =
            !line.isTruncated && line.length <= context.outputDecodeLimit
            && (context.dialect == .legacy || mayHoldAnswers(line.data))
        guard decodes else {
            guard let callID = classification.callID ?? reclassified(line)?.callID else {
                return line.isTruncated ? .oversized : shapeChecked(line)
            }
            if !line.isTruncated, !CodexJSONPrefix.isCompleteObject(line.data) {
                return .invalid
            }
            return CodexLineOutcome(record: .callOutput(CodexCallOutput(callID: callID, output: reference(line))))
        }
        guard let response = envelope(line, CodexRawResponse.self)?.payload else { return .invalid }
        guard let callID = response.callID else { return .accepted }
        let text = response.output?.text ?? ""
        var output = CodexCallOutput(callID: callID, output: reference(line))
        if let data = text.data(using: .utf8), text.hasPrefix("{"),
            let answers = try? JSONDecoder().decode(CodexRawAnswerOutput.self, from: data)
        {
            output.answers = answers.answers.compactMapValues { list in
                list.answers.isEmpty ? nil : list.answers.joined(separator: "\n")
            }
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines) == cancelledQuestionOutput {
            output.isCancelled = true
        }
        if context.dialect == .legacy {
            let parsed = CodexToolSummary.legacyOutput(text)
            output.exitCode = parsed.exitCode
            output.preview = CodexToolSummary.preview(parsed.body, imageCount: response.output?.imageCount ?? 0)
        }
        return CodexLineOutcome(record: .callOutput(output))
    }

    private static func mayHoldAnswers(_ data: Data) -> Bool {
        data.range(of: Data("answers".utf8)) != nil || data.range(of: Data(cancelledQuestionOutput.utf8)) != nil
    }

    private static func decodeCall(
        _ type: String, _ line: ChatLine, _ classification: CodexLineClassification, _ context: Context
    ) -> CodexLineOutcome {
        let name = classification.name ?? (type == "local_shell_call" ? "local_shell" : "tool")
        guard !line.isTruncated else {
            // `call_id` precedes the large field in custom and local shell
            // calls but follows `arguments` in function calls.
            guard let callID = classification.callID else { return .oversized }
            let snapshot = CodexToolSnapshot(
                kind: .other, name: name, title: name, status: nil, callID: callID, output: reference(line))
            return CodexLineOutcome(record: .toolCall(CodexToolCall(callID: callID, role: .tool(snapshot))))
        }
        guard let response = envelope(line, CodexRawResponse.self)?.payload else { return .invalid }
        guard let callID = response.callID else { return .accepted }
        if response.name == "request_user_input_async" {
            return CodexLineOutcome(record: .toolCall(CodexToolCall(callID: callID, role: .asyncQuestions)))
        }
        let snapshot = legacyCallSnapshot(type, response, callID: callID, line: line, context: context)
        return CodexLineOutcome(record: .toolCall(CodexToolCall(callID: callID, role: .tool(snapshot))))
    }

    /// A legacy call's row before its output arrives.
    private static func legacyCallSnapshot(
        _ type: String, _ response: CodexRawResponse, callID: String, line: ChatLine, context: Context
    ) -> CodexToolSnapshot {
        let name = response.name ?? (type == "local_shell_call" ? "local_shell" : "tool")
        var snapshot = CodexToolSnapshot(
            kind: .other, name: name, title: name, status: nil, callID: callID, output: reference(line))
        if type == "local_shell_call" {
            snapshot.kind = .command
            snapshot.title = CodexToolSummary.commandTitle(response.command ?? [])
            return snapshot
        }
        let arguments = (response.arguments ?? response.input).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(CodexRawCallArguments.self, from: $0) }
        switch name {
        case "shell", "container.exec", "local_shell":
            snapshot.kind = .command
            snapshot.title = CodexToolSummary.commandTitle(arguments?.command ?? [])
        case "exec_command":
            snapshot.kind = .command
            snapshot.title = arguments?.cmd ?? name
        case "apply_patch":
            let patch = type == "custom_tool_call" ? response.input : arguments?.input
            if let summary = patch.flatMap({ CodexToolSummary.patchSummary($0, cwd: context.cwd) }) {
                snapshot.kind = summary.kind
                snapshot.title = summary.title
                snapshot.diff = summary.diff
            } else {
                snapshot.kind = .fileEdit
            }
        case "update_plan":
            snapshot.kind = .todo
            snapshot.title = "Update plan"
        case "view_image":
            snapshot.kind = .image
            snapshot.title = arguments?.path.map { CodexToolSummary.relativePath($0, cwd: context.cwd) } ?? name
        default:
            break
        }
        if snapshot.title.isEmpty {
            snapshot.title = name
        }
        return snapshot
    }

    // MARK: Retained context

    private static func decodeRetained(_ type: String, _ line: ChatLine) -> CodexLineOutcome {
        guard type == "verified_answer" else { return shapeChecked(line) }
        guard !line.isTruncated else { return .oversized }
        guard let retained = envelope(line, CodexRawRetained.self)?.payload else { return .invalid }
        guard let callID = retained.callID else { return .accepted }
        let answers = (retained.questions ?? []).compactMap { question -> CodexVerifiedAnswer.Answer? in
            guard let text = question.question, let answer = question.answer else { return nil }
            return CodexVerifiedAnswer.Answer(question: text, answer: answer)
        }
        return CodexLineOutcome(
            record: .verifiedAnswer(CodexVerifiedAnswer(turnID: retained.turnID, callID: callID, answers: answers)))
    }

    // MARK: Helpers

    static func userContent(_ parts: [CodexRawPart]) -> CodexUserContent {
        var content = CodexUserContent(text: "")
        var texts: [String] = []
        for part in parts {
            switch CodexUserInputType(rawValue: part.type ?? "") {
            case .text:
                texts.append(part.text ?? "")
            case .image:
                content.imageCount += 1
            case .localImage:
                content.imageCount += 1
                if let path = part.path {
                    content.localImagePaths.append(path)
                }
            case .skill:
                if let name = part.name {
                    content.skillNames.append(name)
                }
            case .mention:
                break
            case .audio, .localAudio:
                content.attachmentLabels.append("Audio")
            default:
                content.attachmentLabels.append("Attachment")
            }
        }
        content.text = texts.joined()
        return content
    }

    private static func agentContent(
        text: String, phase: CodexMessagePhase?, delivery: String?, questions: [CodexRawAsyncQuestion]?
    ) -> CodexAgentContent {
        var content = CodexAgentContent(text: text, phase: phase)
        if delivery?.lowercased() == "async" {
            content.questions = (questions ?? []).compactMap { question in
                question.title.map { CodexAsyncQuestion(title: $0, options: question.options ?? []) }
            }
        }
        return content
    }

    private static func syncQuestions(_ arguments: String?) -> [CodexSyncQuestion] {
        guard let data = arguments?.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(CodexRawQuestionArguments.self, from: data)
        else { return [] }
        return parsed.questions.map { question in
            CodexSyncQuestion(
                id: question.id, header: question.header, text: question.question ?? "",
                options: question.options)
        }
    }

    /// A hook prompt response item: every part is `<hook_prompt
    /// hook_run_id="…">text</hook_prompt>` (`parse_hook_prompt_message`).
    private static func hookPrompt(_ parts: [CodexRawPart]) -> String? {
        var fragments: [String] = []
        for part in parts {
            guard part.type == "input_text", let text = part.text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("<hook_prompt"), trimmed.hasSuffix("</hook_prompt>"),
                trimmed.contains("hook_run_id="), let open = trimmed.firstIndex(of: ">")
            else { return nil }
            let body = trimmed[trimmed.index(after: open)...].dropLast("</hook_prompt>".count)
            fragments.append(xmlUnescaped(String(body)))
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
    }

    private static func xmlUnescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func imageGeneration(
        id: String, status: String?, revisedPrompt: String?, savedPath: String?, line: ChatLine,
        context: Context
    ) -> CodexToolSnapshot {
        let state: ChatToolActivity.Status?
        switch status {
        case "failed": state = .failed
        case "in_progress", "generating", "inProgress": state = nil
        default: state = .succeeded
        }
        return CodexToolSnapshot(
            kind: .image, name: "image_generation",
            title: revisedPrompt.flatMap { firstLine($0) } ?? "Image generation",
            subtitle: savedPath.map { CodexToolSummary.relativePath($0, cwd: context.cwd) }, status: state,
            callID: id, output: reference(line))
    }

    private static func subAgentActivity(path: String?, kind: String?) -> CodexToolSnapshot {
        let status: ChatToolActivity.Status = switch kind {
        case "completed": .succeeded
        case "interrupted": .interrupted
        default: .noResult
        }
        let name = path?.split(separator: "/").last.map(String.init)
        let title = name.map { "Subagent: \($0)" } ?? "Subagent"
        return CodexToolSnapshot(
            kind: .agent, name: "SubAgentActivity", title: title, status: status,
            subagentActivity: ChatSubagentActivity(agentPath: path, events: [kind ?? "unknown"]))
    }

    private static func sleepTitle(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "Sleep" }
        if milliseconds % 1_000 == 0 {
            return "Sleep \(milliseconds / 1_000)s"
        }
        return "Sleep \(milliseconds)ms"
    }

    private static func mcpName(_ server: String?, _ tool: String?) -> String {
        [server, tool].compactMap { $0 }.joined(separator: ".")
    }

    private static func joinedOutput(_ stdout: String?, _ stderr: String?) -> String? {
        let parts = [stdout, stderr].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return line.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A `file://` URI's path; plain paths pass through.
    static func fileURLPath(_ value: String) -> String {
        guard value.hasPrefix("file://"), let url = URL(string: value) else { return value }
        return url.path(percentEncoded: false)
    }
}

/// The arguments of legacy shell, exec and patch calls.
struct CodexRawCallArguments: Decodable {
    var command: [String]?
    var cmd: String?
    var input: String?
    var path: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        command = container.lenient("command", as: CodexLossyArray<String>.self)?.elements
        cmd = container.lenient("cmd")
        input = container.lenient("input")
        path = container.lenient("path")
    }
}
