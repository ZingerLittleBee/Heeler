import Foundation

/// What a conversation engine follows: a transcript file on the Host, which
/// `TranscriptFollower` reads, or a program's store read by query (ADR 0025).
/// Offsets order the records a source hands on, as a file's byte offsets do.
///
/// A value type: its owner runs one operation at a time and stores the
/// result, so at most one read per conversation is in flight.
protocol ChatTranscriptSource: Sendable {
    /// What `.following(path:)` shows and the saved document is filed under.
    var path: String { get }
    /// What identifies the conversation for the cache: a file's first bytes,
    /// or the session a store names.
    var head: Data? { get }
    /// How far the conversation has been read.
    var readOffset: UInt64 { get }
    /// Where the earliest loaded record starts; 0 once the first record is
    /// loaded, nil while that is not known yet.
    var windowStart: UInt64? { get }
    /// Whether records older than the window remain.
    var hasOlder: Bool { get }
    /// The length one request for older history asks of its first page, and
    /// the largest it doubles to.
    var olderPageLengths: (first: Int, maximum: Int) { get }
    /// The most bytes a request the timeline makes by itself may read, or
    /// nil for no bound.
    var automaticOlderSearch: Int? { get }
    /// Reads the conversation's newest records. Nil when it is not there.
    mutating func open(_ files: ChatHostFiles) async throws -> [ChatLine]?
    /// One look for what changed since the last read.
    mutating func poll(_ files: ChatHostFiles) async throws -> TranscriptFollower.Change
    /// Reads the records just before the window, oldest first: at least
    /// `length` bytes when given, and never more than `limit` bytes.
    mutating func loadOlder(_ files: ChatHostFiles, length: Int?, limit: Int?) async throws
        -> TranscriptFollower.OlderPage
    /// Starts one request for older history, which `olderSearchExhausted`
    /// then measures.
    mutating func beginOlderSearch()
    /// The request begun last has read as far back as one request may.
    var olderSearchExhausted: Bool { get }
    /// One recorded line again, for an expanded tool row; nil when gone.
    /// Throws `ChatToolOutputFailure.tooLong` for a line found too long to
    /// read only once it is asked for.
    func line(at reference: ChatOutputReference, files: ChatHostFiles) async throws -> ChatLine?
}

/// Thrown by a source whose conversation cannot be read, for a reason Chat
/// explains. The engine stops following with it.
struct ChatSourceUnavailable: Error, Equatable {
    let reason: ChatUnavailableReason
}
