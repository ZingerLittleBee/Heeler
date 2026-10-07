import CoreGraphics
import Foundation

/// Folds the timeline's rows (ADR 0020). A finished turn keeps its prompt,
/// the rows it pins and its final answer; everything between folds behind a
/// "Worked for" header. Two or more consecutive tool calls show as one
/// group header. Each header opens on its own, and opening a turn opens
/// none of the groups or rows inside it.
///
/// A pure function of the built rows, so a header toggles in the same
/// main-thread turn as the tap and keeps its top edge where it was.
enum ChatTimelineProjection {
    struct Output: Sendable {
        /// What the list shows, with spacing for its own neighbors.
        var rows: [ChatRow]
        /// Each folded row, by the shown header that holds it.
        var owners: [ChatRowID: ChatRowID]
    }

    /// Whether the newest turn runs, waits on Background Work, or is done.
    enum Phase: Equatable {
        case running
        /// Done, but Background Work it may have launched still runs, so
        /// the turn stays open.
        case held
        case settled
    }

    private struct Segment {
        /// The prompt or notice that opened the turn.
        var head: ChatRow?
        var body: [ChatRow] = []
        var record: ChatTurn?
    }

    static func project(
        _ rows: [ChatRow], turns: [ChatTurn], signals: ChatTurnSignals, open: Set<ChatRowID>
    ) -> Output {
        var output = Output(rows: [], owners: [:])
        output.rows.reserveCapacity(rows.count)
        var segments: [Segment] = []
        var pending: [ChatRow] = []
        var hasOlder = false
        let records = Dictionary(turns.map { (ChatRowID.entry($0.firstEntryID), $0) }, uniquingKeysWith: { _, last in last })
        for row in rows {
            if case .olderHistory(let older) = row.content {
                hasOlder = older != .reachedStart
                output.rows.append(row)
                continue
            }
            // A message sent from Chat opens no turn of its own: one the
            // program holds, or that never arrived, would otherwise settle
            // the turn still running above it. It follows every turn.
            if case .pending = row.content {
                pending.append(row)
            } else if let record = records[row.id] {
                segments.append(Segment(head: holdsHead(row) ? row : nil, body: holdsHead(row) ? [] : [row], record: record))
            } else if turns.isEmpty, case .user(let message) = row.content, !message.wasQueued {
                // Without the program's turns, a prompt opens one.
                segments.append(Segment(head: row))
            } else if segments.isEmpty {
                // Rows above the first loaded opener belong to a turn whose
                // start is further up.
                segments.append(Segment(body: [row]))
            } else {
                segments[segments.count - 1].body.append(row)
            }
        }
        for index in segments.indices {
            let phase = index == segments.count - 1 ? newestPhase(segments[index].record, signals: signals) : .settled
            // Rows of a turn whose start is still to load show as they
            // arrive: folded, each page would add nothing to see.
            let isPartial = index == 0 && segments[0].head == nil && segments[0].record == nil && hasOlder
            emit(segments[index], phase: phase, folds: !isPartial, signals: signals, open: open, into: &output)
        }
        output.rows.append(contentsOf: pending)
        for index in output.rows.indices {
            output.rows[index].topSpacing = ChatRowBuilder.spacing(
                before: output.rows[index].content, after: index > 0 ? output.rows[index - 1].content : nil)
        }
        return output
    }

    static func newestPhase(_ turn: ChatTurn?, signals: ChatTurnSignals) -> Phase {
        // A turn its records closed is over: any new work is a turn the
        // transcript does not show yet.
        if turn?.ending == nil, signals.activity != .idle { return .running }
        return signals.isBackgroundWorkRunning ? .held : .settled
    }

    private static func emit(
        _ segment: Segment, phase: Phase, folds: Bool, signals: ChatTurnSignals, open: Set<ChatRowID>,
        into output: inout Output
    ) {
        if let head = segment.head { output.rows.append(head) }
        // Reasoning with no text says nothing, wherever it is.
        let body = segment.body.filter { !isBlank($0) }

        if phase == .settled, folds, signals.foldsFinishedTurns, let fold = fold(of: body, record: segment.record) {
            let steps = body[..<fold.answerStart]
            for row in steps where isPinned(row) { output.rows.append(row) }
            let folded = steps.filter { !isPinned($0) }
            let id = ChatRowID.turn(fold.answerID)
            let isOpen = open.contains(id)
            let header = ChatTurnHeader(
                state: .worked(duration(of: segment.record)), isOpen: isOpen, stepCount: folded.count)
            output.rows.append(
                ChatRow(id: id, content: .turnHeader(header), revision: revision(header), topSpacing: 0))
            if isOpen {
                // The pinned rows, shown above, still end the runs they cut.
                emitGrouped(Array(steps), skipping: isPinned, isLive: false, isMuted: true, open: open, into: &output)
            } else {
                for row in folded { output.owners[row.id] = id }
            }
            output.rows.append(contentsOf: body[fold.answerStart...])
            return
        }

        if phase == .running, let start = segment.record?.startedAt {
            let header = ChatTurnHeader(state: .working(since: start), isOpen: false, stepCount: 0)
            output.rows.append(
                ChatRow(id: .liveTurn, content: .turnHeader(header), revision: revision(header), topSpacing: 0))
        }
        emitGrouped(body, skipping: { _ in false }, isLive: phase == .running, isMuted: false, open: open, into: &output)
    }

    /// Where a finished turn's final answer starts: the model's text at its
    /// end, past the rows it pins. Nil when there is none, when nothing
    /// comes before it, or when the turn was interrupted or failed.
    private static func fold(of body: [ChatRow], record: ChatTurn?) -> (answerStart: Int, answerID: ChatEntryID)? {
        if record?.ending == .interrupted || record?.ending == .failed { return nil }
        var end = body.count
        while end > 0, isPinned(body[end - 1]) { end -= 1 }
        var start = end
        while start > 0, case .assistant = body[start - 1].content { start -= 1 }
        guard start < end, case .entry(let answerID) = body[start].id,
            body[..<start].contains(where: { !isPinned($0) })
        else { return nil }
        return (start, answerID)
    }

    /// Emits `rows` with each run of two or more tool calls behind a group
    /// header. In a running turn the last run, while nothing but reasoning
    /// follows it, keeps its newest call as its own row. Rows `skip` takes
    /// are shown elsewhere: they end runs and are not emitted here.
    private static func emitGrouped(
        _ rows: [ChatRow], skipping skip: (ChatRow) -> Bool, isLive: Bool, isMuted: Bool, open: Set<ChatRowID>,
        into output: inout Output
    ) {
        func plain(_ row: ChatRow) -> ChatRow {
            var row = row
            switch row.content {
            case .assistant, .reasoning: row.isMuted = isMuted
            default: break
            }
            return row
        }

        var index = 0
        while index < rows.count {
            guard isGroupable(rows[index]) else {
                if !skip(rows[index]) { output.rows.append(plain(rows[index])) }
                index += 1
                continue
            }
            // Reasoning between calls joins their run; reasoning after the
            // last call stays outside it.
            var cursor = index
            var last = index
            while cursor < rows.count, isGroupable(rows[cursor]) || isReasoning(rows[cursor]) {
                if isGroupable(rows[cursor]) { last = cursor }
                cursor += 1
            }
            let run = Array(rows[index...last])
            let calls = run.filter(isGroupable).count
            // A call waiting on the user is the run's newest while it waits,
            // so the group keeps its identity through the dialog.
            let tail = rows[(last + 1)...]
            let isLiveRun = isLive && tail.allSatisfy { isReasoning($0) || isAwaiting($0) }
            if calls < 2 {
                output.rows.append(contentsOf: run.map(plain))
            } else if isLiveRun, tail.contains(where: isAwaiting), case .entry(let first) = run[0].id {
                emitGroup(run, id: .liveGroup(first), open: open, plain: plain, into: &output)
            } else if isLiveRun {
                let members = Array(run.dropLast())
                if case .entry(let first) = members[0].id {
                    emitGroup(members, id: .liveGroup(first), open: open, plain: plain, into: &output)
                }
                output.rows.append(plain(run[run.count - 1]))
            } else if case .entry(let lastID) = run[run.count - 1].id {
                emitGroup(run, id: .group(lastID), open: open, plain: plain, into: &output)
            }
            index = last + 1
        }
    }

    private static func emitGroup(
        _ members: [ChatRow], id: ChatRowID, open: Set<ChatRowID>, plain: (ChatRow) -> ChatRow,
        into output: inout Output
    ) {
        let tools = members.compactMap { row -> ChatToolActivity? in
            if case .tool(let tool) = row.content { tool } else { nil }
        }
        let isOpen = open.contains(id)
        let diffs = tools.compactMap(\.diff)
        let group = ChatToolGroup(
            summary: summary(of: tools), kind: tools.first?.kind ?? .other,
            added: diffs.isEmpty ? nil : diffs.reduce(0) { $0 + $1.added },
            removed: diffs.isEmpty ? nil : diffs.reduce(0) { $0 + $1.removed },
            failed: tools.filter { failedStatuses.contains($0.status) }.count,
            isRunning: tools.contains { $0.status == .running }, calls: tools.count, isOpen: isOpen)
        var hasher = Hasher()
        hasher.combine(group)
        for member in members { hasher.combine(member.revision) }
        output.rows.append(ChatRow(id: id, content: .toolGroup(group), revision: hasher.finalize(), topSpacing: 0))
        if isOpen {
            for member in members {
                var row = plain(member)
                row.isNested = true
                output.rows.append(row)
            }
        } else {
            for member in members { output.owners[member.id] = id }
        }
    }

    private static func revision(_ header: ChatTurnHeader) -> Int {
        var hasher = Hasher()
        hasher.combine(header)
        return hasher.finalize()
    }

    /// Wall time from the turn's start to its end, on the Host's clock.
    private static func duration(of turn: ChatTurn?) -> TimeInterval? {
        guard let start = turn?.startedAt, let end = turn?.endedAt else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: Rows

    private static let failedStatuses: Set<ChatToolActivity.Status> = [.failed, .declined, .interrupted, .notCompleted]

    /// Rows that open a turn and show above its fold.
    private static func holdsHead(_ row: ChatRow) -> Bool {
        switch row.content {
        case .user, .pending, .notice, .divider: true
        default: false
        }
    }

    /// Rows a fold never hides: what the user decides or must see, and what
    /// marks the turn's course.
    static func isPinned(_ row: ChatRow) -> Bool {
        switch row.content {
        case .plan, .questions, .user, .pending, .divider, .olderHistory:
            true
        case .notice(let notice):
            switch notice.kind {
            case .taskNotification, .interrupted, .stopped, .error: true
            default: false
            }
        case .tool(let tool):
            tool.status == .awaitingApproval || tool.kind == .agent || tool.kind == .question
        case .assistant, .reasoning, .turnHeader, .toolGroup:
            false
        }
    }

    /// Calls a group can hold: not Subagents, questions or calls waiting on
    /// the user, nor a command the user ran in Codex's shell.
    static func isGroupable(_ row: ChatRow) -> Bool {
        guard case .tool(let tool) = row.content, tool.status != .awaitingApproval, tool.name != "user_shell"
        else { return false }
        switch tool.kind {
        case .agent, .question: return false
        default: return true
        }
    }

    private static func isAwaiting(_ row: ChatRow) -> Bool {
        if case .tool(let tool) = row.content { tool.status == .awaitingApproval } else { false }
    }

    private static func isReasoning(_ row: ChatRow) -> Bool {
        if case .reasoning = row.content { true } else { false }
    }

    private static func isBlank(_ row: ChatRow) -> Bool {
        if case .reasoning(let reasoning) = row.content { reasoning.text.isEmpty } else { false }
    }

    // MARK: Summary

    /// "Ran 2 commands, Edited 2 files": what the calls did, in a fixed
    /// order. Files count once per path; a write over an existing file, as
    /// its recorded change says, counts as an edit.
    static func summary(of tools: [ChatToolActivity]) -> String {
        func count(_ kind: ChatToolActivity.Kind) -> Int {
            tools.filter { $0.kind == kind }.count
        }
        enum FileVerb { case edited, created, read }
        var paths: [FileVerb: Set<String>] = [:]
        var more: [FileVerb: Int] = [:]
        for (index, tool) in tools.enumerated() {
            let verb: FileVerb
            switch tool.kind {
            case .fileEdit: verb = .edited
            case .fileWrite: verb = .created
            case .fileRead: verb = .read
            default: continue
            }
            if let changes = tool.fileChanges, !changes.files.isEmpty || changes.moreFiles > 0 {
                for file in changes.files {
                    paths[verb == .created && file.kind != .created ? .edited : verb, default: []].insert(file.path)
                }
                more[verb, default: 0] += changes.moreFiles
            } else {
                paths[verb, default: []].insert(tool.title.isEmpty ? "\u{0}\(index)" : tool.title)
            }
        }
        func files(_ verb: FileVerb) -> Int {
            (paths[verb]?.count ?? 0) + (more[verb] ?? 0)
        }
        func plural(_ count: Int, _ one: String, _ many: String) -> String {
            count == 1 ? "1 \(one)" : "\(count) \(many)"
        }
        func times(_ count: Int) -> String {
            count == 1 ? "once" : "\(count) times"
        }

        var parts: [String] = []
        if case let n = count(.command), n > 0 { parts.append("Ran \(plural(n, "command", "commands"))") }
        if case let n = files(.edited), n > 0 { parts.append("Edited \(plural(n, "file", "files"))") }
        if case let n = files(.created), n > 0 { parts.append("Created \(plural(n, "file", "files"))") }
        if case let n = files(.read), n > 0 { parts.append("Read \(plural(n, "file", "files"))") }
        if case let n = count(.search), n > 0 { parts.append("Ran \(plural(n, "search", "searches"))") }
        let web = tools.filter { $0.kind == .web }.map { $0.name.lowercased() }
        let searches = web.filter { $0.contains("search") }.count
        let fetches = web.filter { !$0.contains("search") && $0.contains("fetch") }.count
        let otherWeb = web.count - searches - fetches
        if searches > 0 { parts.append("Searched the web \(times(searches))") }
        if fetches > 0 { parts.append("Fetched \(plural(fetches, "page", "pages"))") }
        if otherWeb > 0 { parts.append("Used the web \(times(otherWeb))") }
        if case let n = count(.mcp), n > 0 { parts.append("Called \(plural(n, "tool", "tools"))") }
        if case let n = count(.image), n > 0 { parts.append("Viewed \(plural(n, "image", "images"))") }
        if count(.todo) > 0 { parts.append("Updated the to-do list") }
        if case let n = count(.other), n > 0 {
            parts.append(parts.isEmpty ? "Used \(plural(n, "tool", "tools"))" : plural(n, "other tool", "other tools"))
        }
        return parts.joined(separator: ", ")
    }
}
