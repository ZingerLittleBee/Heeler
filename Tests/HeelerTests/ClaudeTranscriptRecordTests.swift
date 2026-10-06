import Foundation
import Testing

@testable import Heeler

@Suite("Claude transcript records")
struct ClaudeTranscriptRecordTests {
    private static let probe = "claude/probe2-transcript.jsonl"

    private static func record(_ json: String, offset: UInt64 = 0) throws -> ClaudeRecord {
        guard case .record(let record) = ClaudeLine.decode(ChatLine(offset: offset, data: Data(json.utf8))) else {
            throw DecodeFailure(json: json)
        }
        return record
    }

    private struct DecodeFailure: Error, CustomStringConvertible {
        let json: String
        var description: String { "not a record: \(json)" }
    }

    @Test("Every line of the second probe decodes: 119 records and 47 metadata lines")
    func decodeAll() throws {
        let lines = try ChatFixture.lines(Self.probe)
        var records = 0
        var metadata = 0
        var invalid = 0
        for line in lines {
            switch ClaudeLine.decode(line) {
            case .record: records += 1
            case .metadata: metadata += 1
            case .invalid: invalid += 1
            }
        }
        #expect(lines.count == 166)
        #expect(records == 119)
        #expect(metadata == 47)
        #expect(invalid == 0)

        var reducer = ClaudeTranscriptReducer()
        reducer.append(lines)
        #expect(reducer.index.records.count == 119)
        #expect(reducer.index.title == "create-and-verify-probe-file")
        #expect(reducer.index.permissionMode == "default")
        #expect(reducer.index.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("Metadata is last-wins by file position, whatever order lines arrive in")
    func metadataLastWins() throws {
        let lines = try ChatFixture.lines(Self.probe)
        // Through L87 the latest title is L63's and plan mode is on (L65).
        var head = ClaudeTranscriptReducer()
        head.append(Array(lines.prefix(87)))
        #expect(head.index.title == "c1.txt 文件创建")
        #expect(head.index.permissionMode == "plan")

        var reversed = ClaudeTranscriptReducer()
        reversed.append(Array(lines.dropFirst(87)))
        reversed.prepend(Array(lines.prefix(87)))
        #expect(reversed.index.title == "create-and-verify-probe-file")
        #expect(reversed.index.permissionMode == "default")
    }

    @Test("A typed prompt keeps its provenance and position")
    func typedPrompt() throws {
        let line = try #require(try ChatFixture.lines(Self.probe).first { $0.offset == 391 })
        guard case .record(let record) = ClaudeLine.decode(line) else {
            Issue.record("L5 is not a record")
            return
        }
        #expect(record.uuid == "e6fda38c-45bf-49c6-b0a2-5e1cf39cbef9")
        #expect(record.parentUUID == nil)
        #expect(record.kind == .user)
        #expect(record.byteOffset == 391)
        #expect(record.byteLength == line.length)
        #expect(record.promptSource == "typed")
        #expect(record.originKind == "human")
        #expect(record.sessionID == "e951205e-24af-4a5e-baa7-3ccbebd2de2c")
        #expect(record.texts == ["Use the Bash tool to run: touch c1.txt"])
    }

    @Test("Blocks of one API message are separate records sharing its id (L74, L76)")
    func splitMessage() throws {
        let lines = try ChatFixture.lines(Self.probe)
        let write = try #require(lines.first { $0.offset == 35529 })
        let search = try #require(lines.first { $0.offset == 38558 })
        guard case .record(let first) = ClaudeLine.decode(write), case .record(let second) = ClaudeLine.decode(search)
        else {
            Issue.record("L74 or L76 is not a record")
            return
        }
        #expect(first.messageID != nil)
        #expect(first.messageID == second.messageID)
        #expect(first.apiBlockIndex == 0)
        #expect(second.apiBlockIndex == 1)
        #expect(first.toolUses.map(\.name) == ["Write"])
        #expect(second.toolUses.map(\.name) == ["ToolSearch"])
        // L76 hangs off the result of L74's call, not off L74.
        #expect(second.parentUUID == "2791fe96-4b8f-4838-9796-2265181ea0bf")
    }

    @Test("A decline keeps its kind and the user's feedback (L26)")
    func declineFields() throws {
        let line = try #require(try ChatFixture.lines(Self.probe).first { $0.offset == 7319 })
        guard case .record(let record) = ClaudeLine.decode(line) else {
            Issue.record("L26 is not a record")
            return
        }
        let result = try #require(record.toolResults.first)
        #expect(result.toolUseID == "toolu_01TbgUciZNfX5qWyWVahrgJY")
        #expect(result.isError)
        #expect(record.toolResult?.denialKind == "user-rejected")
        #expect(record.toolResult?.userFeedback == "Do not create it; reply with the single word skipped")
    }

    @Test("A write keeps line counts and a capped patch, never the file")
    func writeReduction() throws {
        let big = String(repeating: "line of a large file\n", count: 5_000)
        let json = """
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_w","content":"The file has been updated."}]},"toolUseResult":{"type":"update",\
            "filePath":"/w/big.txt","content":\(Self.quoted(big)),"originalFile":\(Self.quoted(big)),\
            "structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":3,"lines":[" keep","-old","+new","+added"]}]}}
            """
        let record = try Self.record(json)
        let result = try #require(record.toolResult?.result)
        #expect(result.diff == ChatDiffStats(added: 2, removed: 1))
        #expect(result.diffPreview == ChatToolPreview(text: "@@ -3,2 +3,3 @@\n keep\n-old\n+new\n+added", isTruncated: false))
        #expect(result.filePath == "/w/big.txt")
        #expect(record.blocks.count == 1)

        let created = try Self.record(
            """
            {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_c","content":"File created"}]},"toolUseResult":{"type":"create","filePath":"/w/new.txt",\
            "content":\(Self.quoted(big)),"structuredPatch":[]}}
            """)
        let creation = try #require(created.toolResult?.result)
        #expect(creation.diff == ChatDiffStats(added: 5_000, removed: 0))
        let preview = try #require(creation.diffPreview)
        #expect(preview.isTruncated)
        #expect(preview.text.utf8.count <= ChatToolPreview.rowLimits.bytes)
        #expect(preview.text.split(separator: "\n", omittingEmptySubsequences: false).count <= ChatToolPreview.rowLimits.lines + 1)
    }

    @Test("Images keep only their count")
    func imagesAreCounted() throws {
        let data = String(repeating: "iVBORw0KGgo", count: 2_000)
        let prompt = try Self.record(
            """
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"What is this?"},\
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(data)"}}]},"promptSource":"typed"}
            """)
        #expect(prompt.blocks == [.text("What is this?"), .image])
        #expect(prompt.imageCount == 1)

        let result = try Self.record(
            """
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_r","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(data)"}}]}]}}
            """)
        #expect(result.toolResults == [
            ClaudeToolResult(toolUseID: "toolu_r", isError: false, content: ChatToolPreview(text: "", isTruncated: false, imageCount: 1))
        ])
    }

    @Test("A field of an unexpected type reads as absent")
    func lenientFields() throws {
        let record = try Self.record(
            """
            {"type":"user","uuid":"u1","parentUuid":7,"isMeta":"yes","promptSource":["typed"],"origin":"human",\
            "message":{"role":"user","content":[{"type":"text","text":"hi"},42,"loose",{"type":"tool_use","input":[]}]},\
            "toolDenialUnanswered":"stream-closed"}
            """)
        #expect(record.parentUUID == nil)
        #expect(!record.isMeta)
        #expect(record.promptSource == nil)
        #expect(record.originKind == nil)
        #expect(record.texts == ["hi"])
        #expect(record.blocks.count == 4)
        #expect(record.toolUses == [ClaudeToolUse(id: "", name: "", input: ClaudeToolInput())])
    }

    @Test("Unreadable lines are counted once each, never fatal")
    func diagnostics() {
        let texts = [
            #"not json"#,
            #"["an","array"]"#,
            #"{"no":"type"}"#,
            #"{"type":"user","parentUuid":null}"#,
            #"{"type":"brand-new-metadata","sessionId":"s"}"#,
            #"{"type":"future-record","uuid":"f1","parentUuid":null}"#,
            #"{"type":"system","subtype":"future_subtype","uuid":"y1","parentUuid":"f1"}"#,
        ]
        var offset: UInt64 = 0
        var lines: [ChatLine] = []
        for text in texts {
            lines.append(ChatLine(offset: offset, data: Data(text.utf8)))
            offset += UInt64(text.utf8.count + 1)
        }
        // A line longer than the framer keeps arrives as a prefix.
        lines.append(ChatLine(offset: offset, length: 20_000_000, data: Data(#"{"type":"user","uuid":"#.utf8)))

        var reducer = ClaudeTranscriptReducer()
        reducer.append(lines)
        reducer.append(lines)
        #expect(
            reducer.index.diagnostics
                == ChatTranscriptDiagnostics(
                    invalidLines: 4, oversizedLines: 1,
                    unknownRecordTypes: ["brand-new-metadata", "future-record", "system/future_subtype"]))
        // The unknown record stays on the tree so records below it are reachable.
        #expect(reducer.index.records["f1"]?.kind == .unknown("future-record"))
        #expect(reducer.index.records["y1"]?.parentUUID == "f1")
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
