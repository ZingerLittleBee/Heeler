import Foundation

/// What a program's session check reads besides the screen
/// (`ChatTranscriptAdapter.sessionCheck`): the conversation Chat follows,
/// and how fresh Chat's reading of it is.
struct ChatSessionCheckInput: Sendable {
    var sessionID: String
    var transcript: ChatTranscript
    var activity: ChatAgentActivity
    /// A transcript poll that started after herdr last reported idle has
    /// been applied, so a prompt typed in the terminal has had its read.
    var polledSinceIdle: Bool
    /// Echo keys of Chat's sends delivered in the last echo timeout that
    /// the transcript has not recorded yet, which may already show.
    var unrecordedSendKeys: Set<String>
    /// Echo keys of Chat's sends the prompt log says another session took,
    /// however old: that session's screen keeps showing them, and one may
    /// read the same as a message of this conversation.
    var misdirectedSendKeys: Set<String> = []
}

/// What the Agent's screen says about the session it shows.
enum ChatScreenSessionVerdict: Equatable, Sendable {
    case thisSession
    /// The screen shows another session; why, as the hold.
    case otherSession(String)
    case unknown
}

/// Where a send's witness starts reading: the log's size when the send
/// first showed, before its text was pasted.
struct ChatSendWitnessMark: Equatable, Sendable {
    var path: String
    var size: UInt64
}

enum ChatSendWitnessVerdict: Equatable, Sendable {
    /// The log names the session Chat follows for the send's text.
    case here
    /// The log names one other session for it, and nothing else does.
    case elsewhere
    case unknown
}

/// A log beside the transcript where the program writes every prompt it
/// submits, naming the session that took it. Chat reads only what was
/// appended after a send's mark, compares it in memory, and keeps nothing.
struct ChatSendWitness: Sendable {
    var logPath: @Sendable (_ transcriptPath: String) -> String
    /// The prompt and session one complete line records; nil skips the line.
    var entry: @Sendable (_ line: Data) -> (prompt: String, sessionID: String)?
    /// The most one read takes past the mark.
    var readLimit = 64 << 10

    /// The log's size now, the mark for a send about to be pasted: 0 for a
    /// log the program has not written yet, nil when the Host gives no size.
    func mark(forTranscript path: String, files: ChatHostFiles) async throws -> ChatSendWitnessMark? {
        let log = logPath(path)
        guard let status = try await files.status(log) else { return ChatSendWitnessMark(path: log, size: 0) }
        return status.size.map { ChatSendWitnessMark(path: log, size: $0) }
    }

    /// The complete lines appended since `mark`, and whether they are all
    /// of them. Nil when the log is gone or shorter than the mark: the
    /// program rewrote it, and offsets say nothing any more.
    func appended(
        since mark: ChatSendWitnessMark, files: ChatHostFiles
    ) async throws -> (lines: [Data], isWholeAppend: Bool)? {
        guard let size = try await files.status(mark.path)?.size, size >= mark.size else { return nil }
        // One byte before the mark tells whether it fell between lines.
        let start = max(mark.size, 1) - 1
        let end = min(size, mark.size + UInt64(readLimit))
        guard end > start else { return ([], true) }
        guard let data = try await files.read(path: mark.path, from: start, to: end, chunk: readLimit + 1) else {
            return nil
        }
        return (Self.completeLines(data, startsBeforeMark: mark.size > 0), size <= mark.size + UInt64(readLimit))
    }

    /// The complete lines in `data`, read from one byte before a mark (or
    /// from 0). That byte is a newline when the mark fell between lines;
    /// otherwise the mark split a line written before it, which is dropped.
    /// A line still being written at the end is dropped too.
    static func completeLines(_ data: Data, startsBeforeMark: Bool) -> [Data] {
        var bytes = data[...]
        if startsBeforeMark {
            guard let newline = bytes.firstIndex(of: 0x0A) else { return [] }
            bytes = bytes[bytes.index(after: newline)...]
        }
        guard let last = bytes.lastIndex(of: 0x0A) else { return [] }
        return bytes[..<last].split(separator: 0x0A).map { Data($0) }
    }

    /// Which session took the send whose echo key is `key`. One line naming
    /// the followed session settles it here. Only a read that holds every
    /// line appended since the mark, with exactly one line for the text,
    /// says elsewhere: the same text may go to two sessions.
    func verdict(
        lines: [Data], key: String, sessionID: String, isWholeAppend: Bool, echoKey: (String) -> String
    ) -> ChatSendWitnessVerdict {
        let sessions = lines.compactMap { line -> String? in
            guard let entry = entry(line), echoKey(entry.prompt) == key else { return nil }
            return entry.sessionID.lowercased()
        }
        if sessions.contains(sessionID.lowercased()) { return .here }
        return isWholeAppend && sessions.count == 1 ? .elsewhere : .unknown
    }
}

/// A send the program's own log says went into another session, which
/// holds every later send until the user is back in this conversation.
struct ChatSessionConcern: Equatable, Sendable {
    var reason: String
    /// The misdirected send.
    var raisedBy: UUID
    /// How far the transcript had been read when it was raised: a prompt
    /// recorded at or after this offset is newer than the concern.
    var promptFloor: UInt64
    var generation: Int
}
