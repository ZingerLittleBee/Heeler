import Foundation

/// Whether the adapter can read a rollout, decided by its first line
/// (docs/research/codex-rollout-format.md, "Dialect detection").
enum CodexRolloutSupport: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable, Codable {
        /// Codex 0.30 or older: line 1 is `{id, instructions}`, not an envelope.
        case preEnvelope
        /// Line 1 is not a `session_meta` record.
        case noSessionMeta
        /// `history_mode` holds a value this adapter (and Codex) rejects.
        case unknownHistoryMode
    }

    /// The `session_meta` line has not arrived yet.
    case pending
    case supported(CodexRolloutDialect)
    case unsupported(Reason)
}

/// One decoded line, kept in place of its bytes: the transcript is rebuilt
/// from these, so a window never holds tool output in memory.
struct CodexStoredLine: Equatable, Sendable {
    var offset: UInt64
    var length: Int
    var ordinal: UInt64?
    var outcome: CodexLineOutcome

    var end: UInt64 { offset + UInt64(length) + 1 }
}

/// One rollout file's share of the conversation.
struct CodexSegment: Equatable, Sendable {
    var rolloutID: String
    /// The file, or nil for the live rollout.
    var path: String?
    var meta: CodexSessionMeta
    var lines: [CodexStoredLine]
    /// For a base segment: ordinals from here on belong to the rollout that
    /// continues it.
    var endOrdinalExclusive: UInt64?
}

/// A projection plus what tests and pending-echo matching need beyond the
/// shared transcript.
struct CodexProjection: Equatable, Sendable {
    var transcript: ChatTranscript
    var turns: [CodexTurnSummary]
    /// The live rollout's prompts and compactions, in transcript order.
    var echoCandidates: [CodexEchoCandidate]
    var ordinals: CodexOrdinalDiagnostics
}

/// Turns a Codex rollout's lines into Chat entries.
///
/// The reducer keeps one decoded record per line and rebuilds the timeline
/// from them whenever lines arrive, so feeding a file in any batches, or a
/// tail first and older pages after, gives the same transcript as one pass.
/// Nothing is decoded until the `session_meta` line names the dialect:
/// lines that arrive earlier wait whole.
///
/// A reverted paginated rollout continues history kept in older files
/// (docs/research/codex-rollout-format.md, "Revert"). The reducer cannot
/// read files, so it names the base it needs in `pendingHistoryBase` and
/// takes that file's lines through `setBaseSegment(rolloutID:path:lines:)`,
/// one base at a time.
struct CodexRolloutReducer: ChatTranscriptReducer {
    /// Bumped when the normalization changes, so entries cached by an
    /// older build are dropped instead of mixed with new ones.
    static let revision = 4

    let rolloutID: String
    private(set) var support: CodexRolloutSupport = .pending
    private var meta: CodexSessionMeta?
    /// Lines received while `support` is pending, in file order.
    private var undecided: [ChatLine] = []
    private var lines: [CodexStoredLine] = []
    /// Base segments, nearest first.
    private var bases: [CodexSegment] = []
    /// The rollout whose base could not be read, when one could not.
    private var unavailableBaseOf: String?
    private var timeline = CodexTimeline()
    private var ordinals = CodexOrdinalDiagnostics()
    private var diagnostics = ChatTranscriptDiagnostics()

    init(rolloutID: String) {
        self.rolloutID = rolloutID
    }

    /// Names a rollout this reducer does not read, for Chat to explain.
    var unsupportedFormat: String? {
        guard case .unsupported(let reason) = support else { return nil }
        return switch reason {
        case .preEnvelope: "a rollout from Codex 0.30 or earlier"
        case .noSessionMeta: "a rollout that does not start with its session record"
        case .unknownHistoryMode: "a rollout with a history mode Chat does not know"
        }
    }

    var dialect: CodexRolloutDialect? {
        if case .supported(let dialect) = support {
            return dialect
        }
        return nil
    }

    /// The live rollout's `history_base`, set when it continues a reverted
    /// history.
    var historyBase: CodexHistoryBase? { meta?.historyBase }

    /// The base the lineage needs next: the oldest loaded segment's base,
    /// until the chain ends or a base cannot be read.
    var pendingHistoryBase: CodexHistoryBase? {
        guard dialect == .paginated, unavailableBaseOf == nil else { return nil }
        return (bases.last?.meta ?? meta)?.historyBase
    }

    /// Reads the dialect from line 1 when a tail window does not include
    /// it. The first `session_meta` seen, here or at offset 0, wins.
    mutating func setSessionMeta(_ line: ChatLine) {
        guard support == .pending else { return }
        adopt(line)
        rebuild()
    }

    /// Lines already fed are ignored, so a caller may resend an overlap.
    mutating func append(_ newLines: [ChatLine]) {
        let end = lines.last?.end ?? undecided.last?.end ?? 0
        receive(newLines.filter { $0.offset >= end }, atEnd: true)
    }

    mutating func prepend(_ newLines: [ChatLine]) {
        let start = lines.first?.offset ?? undecided.first?.offset ?? .max
        receive(newLines.filter { $0.end <= start }, atEnd: false)
    }

    /// Supplies the base named by `pendingHistoryBase`: the base file's
    /// lines over `[0, end_byte_offset)`. The boundary must fall exactly
    /// after a line whose ordinal is `end_ordinal_exclusive - 1`; otherwise,
    /// or when the lines are empty because the file is gone, the lineage
    /// stops there and the transcript shows that older history is
    /// unavailable.
    mutating func setBaseSegment(rolloutID baseID: String, path: String, lines baseLines: [ChatLine]) {
        guard let base = pendingHistoryBase, base.baseRolloutID == baseID else { return }
        let known = Set([rolloutID] + bases.map(\.rolloutID))
        if !known.contains(baseID), let segment = Self.baseSegment(base, rolloutID: baseID, path: path, lines: baseLines) {
            bases.append(segment)
        } else {
            unavailableBaseOf = bases.last?.rolloutID ?? rolloutID
        }
        rebuild()
    }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        projection(context).transcript
    }

    /// The call's output from its item, end event or response line, decoded
    /// whatever its size: the caller already bounded the line.
    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard let dialect else { return nil }
        var context = CodexRecordDecoder.Context(dialect: dialect, cwd: meta?.cwd)
        context.outputDecodeLimit = .max
        switch Self.decode(line, context: context).outcome.record {
        case .item(_, let item)?, .legacyItem(let item, _)?:
            guard case .tool(let snapshot) = item.content, snapshot.callID == tool.callID else { return nil }
            return .preview(snapshot.preview)
        case .callOutput(let output)?:
            return output.callID == tool.callID ? .preview(output.preview) : nil
        default:
            return nil
        }
    }

    func projection(_ context: ChatProjectionContext) -> CodexProjection {
        var timeline = timeline
        if context.windowStart > 0 {
            // Older history sits above lines the window has not loaded yet.
            timeline = Self.liveOnly(timeline, rolloutID: rolloutID)
        }
        let output = CodexTimelineProjector.project(timeline, context: context, liveRolloutID: rolloutID)
        let transcript = ChatTranscript(
            entries: output.entries, needsOlderHistory: context.windowStart > 0 || pendingHistoryBase != nil,
            pendingRequests: output.pendingRequests, recordedPrompts: output.recordedPrompts,
            diagnostics: diagnostics, turns: output.chatTurns, precedingTurnEnd: output.precedingTurnEnd)
        return CodexProjection(
            transcript: transcript, turns: output.turns, echoCandidates: output.echoCandidates, ordinals: ordinals)
    }

    // MARK: Lines

    private mutating func receive(_ newLines: [ChatLine], atEnd: Bool) {
        let newLines = newLines.sorted { $0.offset < $1.offset }
        guard !newLines.isEmpty else { return }
        if support == .pending, let head = newLines.first(where: { $0.offset == 0 }) {
            adopt(head)
        }
        switch support {
        case .pending:
            undecided = atEnd ? undecided + newLines : newLines + undecided
            return
        case .unsupported:
            return
        case .supported:
            let decoded = newLines.map(decode)
            lines = atEnd ? lines + decoded : decoded + lines
        }
        rebuild()
    }

    /// Reads the dialect from a `session_meta` line and decodes whatever
    /// waited for it.
    private mutating func adopt(_ line: ChatLine) {
        let (support, meta) = Self.detect(line)
        self.support = support
        self.meta = meta
        let waiting = undecided
        undecided = []
        if case .supported = support {
            lines = waiting.map(decode) + lines
        }
    }

    private func decode(_ line: ChatLine) -> CodexStoredLine {
        guard let dialect else {
            return CodexStoredLine(offset: line.offset, length: line.length, ordinal: nil, outcome: .invalid)
        }
        return Self.decode(line, context: CodexRecordDecoder.Context(dialect: dialect, cwd: meta?.cwd))
    }

    private static func decode(_ line: ChatLine, context: CodexRecordDecoder.Context) -> CodexStoredLine {
        var classification = CodexLineClassifier.classify(line.data)
        if classification.kind == .unclassified, line.data.count > CodexLineClassifier.prefixLimit {
            classification = CodexLineClassifier.classify(line.data, limit: line.data.count)
        }
        return CodexStoredLine(
            offset: line.offset, length: line.length, ordinal: classification.ordinal,
            outcome: CodexRecordDecoder.decode(line, as: classification, in: context))
    }

    /// The dialect line 1 declares (docs/research/codex-rollout-format.md,
    /// "Dialect detection").
    static func detect(_ line: ChatLine) -> (support: CodexRolloutSupport, meta: CodexSessionMeta?) {
        let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
        guard let data, let first = try? JSONDecoder().decode(CodexFirstLine.self, from: data) else {
            return (.unsupported(.noSessionMeta), nil)
        }
        if first.isPreEnvelope {
            return (.unsupported(.preEnvelope), nil)
        }
        guard first.type == "session_meta", let meta = first.payload else {
            return (.unsupported(.noSessionMeta), nil)
        }
        guard !meta.hasMalformedHistoryMode else { return (.unsupported(.unknownHistoryMode), meta) }
        switch meta.historyMode {
        case CodexHistoryMode.paginated?:
            return (.supported(.paginated), meta)
        case CodexHistoryMode.legacy?:
            return (.supported(.legacy), meta)
        case nil:
            // `history_mode` follows the large base instructions, so a cut
            // line may have lost it; only paginated lines carry ordinals.
            if line.isTruncated, CodexLineClassifier.classify(line.data).ordinal != nil {
                return (.supported(.paginated), meta)
            }
            return (.supported(.legacy), meta)
        default:
            return (.unsupported(.unknownHistoryMode), meta)
        }
    }

    // MARK: Lineage

    /// A base file's lines as a segment, or nil when they do not end
    /// exactly at the boundary the child recorded or are not a paginated
    /// rollout from its head.
    private static func baseSegment(
        _ base: CodexHistoryBase, rolloutID: String, path: String, lines: [ChatLine]
    ) -> CodexSegment? {
        let within = lines.filter { $0.end <= base.endByteOffset }.sorted { $0.offset < $1.offset }
        guard base.endOrdinalExclusive > 0, let head = within.first, head.offset == 0,
            within.last?.end == base.endByteOffset
        else { return nil }
        guard case (.supported(.paginated), let meta?) = detect(head) else { return nil }
        let context = CodexRecordDecoder.Context(dialect: .paginated, cwd: meta.cwd)
        let stored = within.map { decode($0, context: context) }
        let lastOrdinal = stored.last { $0.outcome.isAccepted && $0.ordinal != nil }?.ordinal
        guard lastOrdinal == base.endOrdinalExclusive - 1 else { return nil }
        return CodexSegment(
            rolloutID: rolloutID, path: path, meta: meta, lines: stored, endOrdinalExclusive: base.endOrdinalExclusive)
    }

    /// The timeline without base segments' entries, for a window that has
    /// not reached the live file's head.
    private static func liveOnly(_ timeline: CodexTimeline, rolloutID: String) -> CodexTimeline {
        CodexTimeline(
            turns: timeline.turns.compactMap { turn in
                var turn = turn
                turn.entries.removeAll { $0.rolloutID != rolloutID }
                if turn.ending?.rolloutID != rolloutID {
                    turn.ending = nil
                }
                return turn.entries.isEmpty && turn.ending == nil ? nil : turn
            })
    }

    // MARK: Rebuild

    private mutating func rebuild() {
        diagnostics = ChatTranscriptDiagnostics()
        for line in lines + bases.flatMap(\.lines) {
            if line.outcome.isInvalid {
                diagnostics.invalidLines += 1
            }
            if line.outcome.isOversized {
                diagnostics.oversizedLines += 1
            }
            if let type = line.outcome.unknownType {
                diagnostics.unknownRecordTypes.insert(type)
            }
        }
        guard let dialect, let meta else {
            timeline = CodexTimeline()
            ordinals = CodexOrdinalDiagnostics()
            return
        }
        let live = CodexSegment(rolloutID: rolloutID, path: nil, meta: meta, lines: lines)
        switch dialect {
        case .paginated:
            (timeline, ordinals) = CodexPaginatedBuilder.build(bases.reversed() + [live])
        case .legacy:
            timeline = CodexLegacyBuilder.build(live)
            ordinals = CodexOrdinalDiagnostics()
        }
        if let unavailableBaseOf {
            timeline.leading = [
                CodexTimelineEntry(
                    id: ChatEntryID("codex/\(unavailableBaseOf)/~history-unavailable"), sourceOffset: 0,
                    rolloutID: unavailableBaseOf, path: bases.last?.path,
                    content: .divider(ChatDivider(kind: .historyUnavailable)))
            ]
        }
    }
}
