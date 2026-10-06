import Foundation

@testable import Heeler

/// A stand-in program format for Chat's plumbing tests. Each `{"n":k}`
/// line becomes one user entry `n-k`; the conversation is titled with the
/// first line it was seeded with; `{"format":"old"}` is a format it does
/// not read; `{"continued":"<id>"}` links to another session;
/// `{"prompt":"<text>"}` is a typed prompt the file records,
/// `{"compacted":true}` a compaction, and `{"tool":k,"output":"<text>"}`
/// tool row `t-k`, which references its line for the output instead of
/// keeping a preview, as a saved entry does.
struct NumberedChatReducer: ChatTranscriptReducer {
    private struct Record: Codable {
        var n: Int?
        var format: String?
        var continued: String?
        var prompt: String?
        var compacted: Bool?
        var tool: Int?
        var output: String?
    }

    let seed: ChatReducerSeed
    private(set) var lines: [ChatLine] = []

    init(seed: ChatReducerSeed) {
        self.seed = seed
    }

    static func adapter(
        revision: Int = 1, limits: TranscriptFollower.Limits = TranscriptFollower.Limits(),
        wantsFirstLine: Bool = false
    ) -> ChatTranscriptAdapter {
        ChatTranscriptAdapter(
            revision: revision, limits: limits, wantsFirstLine: wantsFirstLine,
            makeReducer: { NumberedChatReducer(seed: $0) })
    }

    static func line(_ n: Int) -> String { #"{"n":\#(n)}"# + "\n" }

    static func lines(_ range: Range<Int>) -> String {
        range.map(line).joined()
    }

    /// Where line `n` starts in a file of `lines(0..<k)`.
    static func offset(of n: Int) -> UInt64 {
        UInt64(lines(0..<n).utf8.count)
    }

    static func ids(_ range: Range<Int>) -> [String] {
        range.map { "n-\($0)" }
    }

    static func prompt(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(["prompt": text])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static let compaction = #"{"compacted":true}"# + "\n"

    static func tool(_ n: Int, output: String) -> String {
        let data = (try? JSONEncoder().encode(Record(tool: n, output: output))) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    mutating func append(_ lines: [ChatLine]) { self.lines += lines }
    mutating func prepend(_ lines: [ChatLine]) { self.lines = lines + self.lines }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        let records = lines.map { (line: $0, record: Self.record($0)) }
        return ChatTranscript(
            entries: records.compactMap { line, record in
                if let prompt = record?.prompt {
                    return ChatEntry(
                        id: ChatEntryID("p-\(line.offset)"), sourceOffset: line.offset,
                        content: .user(ChatUserMessage(text: prompt)))
                }
                if record?.compacted == true {
                    return ChatEntry(
                        id: ChatEntryID("c-\(line.offset)"), sourceOffset: line.offset,
                        content: .divider(ChatDivider(kind: .compaction)))
                }
                if let tool = record?.tool {
                    return ChatEntry(
                        id: ChatEntryID("t-\(tool)"), sourceOffset: line.offset,
                        content: .tool(
                            ChatToolActivity(
                                kind: .command, name: "Bash", title: "step \(tool)", status: .succeeded,
                                callID: "call-\(tool)",
                                output: ChatOutputReference(offset: line.offset, length: line.length))))
                }
                guard let n = record?.n else { return nil }
                return ChatEntry(
                    id: ChatEntryID("n-\(n)"), sourceOffset: line.offset,
                    content: .user(ChatUserMessage(text: "\(n)")))
            },
            title: seed.firstLine.map { String(decoding: $0.data, as: UTF8.self) },
            needsOlderHistory: context.windowStart > 0,
            recordedPrompts: records.compactMap { line, record in
                record?.prompt.map {
                    ChatRecordedPrompt(offset: line.offset, text: $0, entryID: ChatEntryID("p-\(line.offset)"))
                }
            },
            links: ChatTranscriptLinks(
                continuedInSessionID: records.lazy.compactMap { $0.record?.continued }.last))
    }

    var unsupportedFormat: String? {
        lines.lazy.compactMap { Self.record($0)?.format }.first
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard let record = Self.record(line), let n = record.tool, tool.callID == "call-\(n)" else { return nil }
        return .preview(record.output.map { ChatToolPreview(capping: $0) })
    }

    private static func record(_ line: ChatLine) -> Record? {
        try? JSONDecoder().decode(Record.self, from: line.data)
    }
}
