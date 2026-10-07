import Foundation

/// Every line of one Claude Code transcript folded so far, keyed so the
/// order lines arrive in never matters.
///
/// The follower feeds a tail window first and older pages later, and may
/// re-feed lines after a rewrite. Records are keyed by `uuid` and metadata
/// is last-wins by byte offset, so appending, prepending and re-feeding all
/// converge on the state one read of the whole file would give. Relations
/// between records (children, message groups, tool results) are derived per
/// projection instead, because compaction relinking rewrites parents and an
/// older page can land anywhere in them.
struct ClaudeTranscriptIndex: Sendable {
    /// Chain records by `uuid`. When a uuid occurs twice, the later line
    /// wins, as in the SDK reader.
    private(set) var records: [String: ClaudeRecord] = [:]
    /// Queue operations by byte offset.
    private(set) var queueOperations: [UInt64: QueueOperation] = [:]
    private(set) var unknownRecordTypes: Set<String> = []

    private var customTitle = Latest<String>()
    private var aiTitle = Latest<String>()
    private var summaryTitle = Latest<String>()
    private var permissionModeValue = Latest<String>()
    private var relocatedCwd = Latest<String>()
    private var continuedIn = Latest<String>()
    /// Where the newest assistant record of the session itself starts.
    private var lastAssistantOffset: UInt64?
    /// Offsets rather than counts, so a line fed twice counts once.
    private var invalidOffsets: Set<UInt64> = []
    private var oversizedOffsets: Set<UInt64> = []

    struct QueueOperation: Sendable, Equatable {
        var offset: UInt64
        var operation: String
        var content: String?
        var timestamp: String?
    }

    /// `system` subtypes this adapter knows, including the ones the CLI's
    /// own renderer handles (`zm`); others are reported.
    static let knownSystemSubtypes: Set<String> = [
        "turn_duration", "compact_boundary", "local_command", "away_summary", "informational",
        "scheduled_task_fire", "model_refusal_fallback", "model_fallback", "model_consent_fallback",
        "agents_killed", "memory_saved", "api_error", "permission_retry", "stop_hook_summary",
    ]

    mutating func apply(_ line: ChatLine) {
        guard !line.isTruncated else {
            oversizedOffsets.insert(line.offset)
            return
        }
        switch ClaudeLine.decode(line) {
        case .invalid:
            invalidOffsets.insert(line.offset)
        case .record(let record):
            insert(record)
        case .metadata(let metadata):
            fold(metadata, at: line.offset)
        }
    }

    private mutating func insert(_ record: ClaudeRecord) {
        if let existing = records[record.uuid], existing.byteOffset > record.byteOffset { return }
        records[record.uuid] = record
        if record.kind == .assistant, !record.isSidechain {
            lastAssistantOffset = max(lastAssistantOffset ?? 0, record.byteOffset)
        }
        switch record.kind {
        case .unknown(let type):
            unknownRecordTypes.insert(type)
        case .system(let subtype) where !Self.knownSystemSubtypes.contains(subtype):
            unknownRecordTypes.insert("system/\(subtype)")
        default:
            break
        }
    }

    private mutating func fold(_ metadata: ClaudeMetadata, at offset: UInt64) {
        switch metadata {
        case .customTitle(let title): customTitle.offer(title, at: offset)
        case .aiTitle(let title): aiTitle.offer(title, at: offset)
        case .summary(let title): summaryTitle.offer(title, at: offset)
        case .permissionMode(let mode): permissionModeValue.offer(mode, at: offset)
        case .relocated(let cwd): relocatedCwd.offer(cwd, at: offset)
        case .continuedIn(let sessionID): continuedIn.offer(sessionID, at: offset)
        case .queueOperation(let operation, let content, let timestamp):
            queueOperations[offset] = QueueOperation(
                offset: offset, operation: operation, content: content, timestamp: timestamp)
        case .other(let type):
            if !ClaudeMetadata.knownTypes.contains(type) {
                unknownRecordTypes.insert(type)
            }
        }
    }

    /// `custom-title` over `ai-title` over the legacy `summary`.
    var title: String? { customTitle.value ?? aiTitle.value ?? summaryTitle.value }

    var permissionMode: String? { permissionModeValue.value }

    /// The newest `relocated` and `continued-in`. A hand-off the session
    /// wrote assistant messages after is history, not where the
    /// conversation went (docs/research/claude-code-transcript-format.md,
    /// "Location").
    var links: ChatTranscriptLinks {
        var continuedInSessionID = continuedIn.value
        if let lastAssistantOffset, lastAssistantOffset > continuedIn.offset {
            continuedInSessionID = nil
        }
        return ChatTranscriptLinks(relocatedCwd: relocatedCwd.value, continuedInSessionID: continuedInSessionID)
    }

    var diagnostics: ChatTranscriptDiagnostics {
        ChatTranscriptDiagnostics(
            invalidLines: invalidOffsets.count, oversizedLines: oversizedOffsets.count,
            unknownRecordTypes: unknownRecordTypes)
    }

    /// Chain records in file order.
    var recordsByPosition: [ClaudeRecord] {
        records.values.sorted { $0.byteOffset < $1.byteOffset }
    }
}

/// A value where the line furthest into the file wins.
private struct Latest<Value: Sendable & Equatable>: Sendable, Equatable {
    private(set) var value: Value?
    private(set) var offset: UInt64 = 0

    mutating func offer(_ candidate: Value, at candidateOffset: UInt64) {
        guard value == nil || candidateOffset >= offset else { return }
        value = candidate
        offset = candidateOffset
    }
}
