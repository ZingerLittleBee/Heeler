import Foundation

/// One read of one OpenCode session from OpenCode's own database on the
/// Host (ADR 0025). `OpenCodeProbe` turns it into a fixed, read-only script
/// and parses what that script prints.
struct OpenCodeQuery: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The newest rows that fit `budget` bytes of slimmed JSON, with the
        /// session, its inbox and the names of other stores.
        case tail(budget: Int)
        /// What changed since the cursor's read, or only the event counter
        /// when nothing did.
        case poll(OpenCodePollCursor)
        /// The rows below `before`, newest first within `budget`, printed
        /// oldest first.
        case older(before: Int64, budget: Int)
        /// One row again, its tool output cut at `outputLimit` characters
        /// rather than the usual 16 Ki.
        case row(seq: Int64, outputLimit: Int)
    }

    var session: OpenCodeSessionID
    var kind: Kind
}

/// What a poll already holds, so the query reads only what changed.
struct OpenCodePollCursor: Equatable, Sendable {
    /// The session's event counter at the last read; nil always reads as
    /// changed.
    var eventSeq: Int64?
    /// The window the source holds: the oldest and newest row it read.
    var lowSeq: Int64
    var highSeq: Int64
    /// Rows the source holds in `lowSeq...highSeq`. A store that counts a
    /// different number has deleted rows, as a committed revert does.
    var knownInWindow: Int
    /// Rows still running, read again on every changed poll. At most 64;
    /// the source reads the tail instead when more are open.
    var openRows: [Int64]
    /// Milliseconds: the newest `time_updated` seen, minus 2 s, so a row
    /// updated in the same millisecond as the last read is read again.
    var updatedSince: Int64
    var budget: Int
}

enum OpenCodeQueryResponse: Equatable, Sendable {
    /// The event counter has not moved since the cursor's read.
    case unchanged(eventSeq: Int64?)
    case records(OpenCodeRecords)
    /// The store has no such session. `otherStores` names the store files
    /// beside the default one (`opencode-<channel>.db`), on tail reads only.
    case sessionMissing(otherStores: [String])
    case unavailable(OpenCodeStoreProblem)
}

/// Everything one query printed between its markers, as lines for the
/// reducer (`{"k":"session",…}`, `{"k":"inbox",…}` and `{"k":"row",…}`).
struct OpenCodeRecords: Equatable, Sendable {
    var sqliteVersion: String?
    var eventSeq: Int64?
    var sessionLine: Data?
    var inboxLine: Data?
    /// Ascending `seq`.
    var rows: [OpenCodeRowLine]
    /// The session's oldest row, on tail, poll and older reads.
    var firstSeq: Int64?
    /// Rows the store holds in the poll cursor's window, on polls only.
    var windowCount: Int?
    /// The poll found more than its budget, or the output was cut before the
    /// reader's exit line: read the tail instead.
    var overflow: Bool
    /// Blank or untagged lines between the markers, such as a row cut at
    /// the output cap.
    var ignoredLines: Int
}

struct OpenCodeRowLine: Equatable, Sendable {
    var id: String
    var seq: Int64
    var timeUpdated: Int64
    /// The row cannot change any more: a completed step, compaction or shell
    /// command, or a row type OpenCode never updates.
    var isFinal: Bool
    var line: Data
}

/// Why a Host's OpenCode store cannot answer, before any session is read.
enum OpenCodeStoreProblem: Equatable, Sendable {
    /// No database at the default path, shown with `~` for the home directory.
    case noStore(path: String)
    /// The Host has neither `sqlite3` nor a usable `python3`.
    case noReader
    /// The reader's SQLite is older than 3.25, lacks JSON1, or cannot parse
    /// the statements on its parser stack.
    case readerTooOld(String)
    /// The database's `-wal` or `-shm` file is missing: OpenCode is not
    /// running, and a read-only open would create them or fail.
    case storeClosed
    /// Only OpenCode 1.x tables exist.
    case olderOpenCode
    /// Tables or columns Chat reads are missing (`table.column`).
    case layout(missing: [String])
}
