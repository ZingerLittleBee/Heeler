import Foundation
import Testing

@testable import Heeler

@Suite("Claude teammate transcripts")
struct ClaudeTeammateTranscriptTests {
    private static let prompt =
        #"{"type":"user","timestamp":"2026-11-24T11:00:16.000Z","message":{"role":"user","content":"<teammate-message teammate_id=\"team-lead\" summary=\"Build it\">\nBuild the tab.\n</teammate-message>"}}"#
    private static let reminder =
        #"{"type":"user","isMeta":true,"timestamp":"2026-11-24T11:00:16.100Z","message":{"role":"user","content":"<system-reminder>Other agents: main.</system-reminder>"}}"#
    private static let toolCall =
        #"{"type":"assistant","timestamp":"2026-11-24T11:00:20.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make"}}]}}"#
    private static let toolResult =
        #"{"type":"user","timestamp":"2026-11-24T11:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private static let answer =
        #"{"type":"assistant","timestamp":"2026-11-24T11:05:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#

    private static func turn(_ lines: [String], cutFirst: Bool = false) -> ClaudeTeammateTurn? {
        let text = (cutFirst ? "\"cut\":1}\n" : "") + lines.joined(separator: "\n") + "\n"
        return ClaudeTeammateTurn.latest(in: Data(text.utf8), startsAtFileStart: !cutFirst)
    }

    private static func date(_ text: String) -> Date? { ClaudeTranscriptProjection.date(text) }

    @Test("A named agent's meta file says whether it is a teammate")
    func meta() {
        #expect(ClaudeTeammateFiles.agentID(metaFileName: "agent-agh-t1-074cdf21c9a8b630.meta.json") == "agh-t1-074cdf21c9a8b630")
        // A Subagent without a name, and names that are no agent's.
        #expect(ClaudeTeammateFiles.agentID(metaFileName: "agent-a1b2c3d4e5f607182.meta.json") == nil)
        #expect(ClaudeTeammateFiles.agentID(metaFileName: "agent-a/../b-1.meta.json") == nil)
        #expect(ClaudeTeammateFiles.agentID(metaFileName: "agent-agh-t1-074cdf21c9a8b630.jsonl") == nil)

        let teammate = #"{"agentType":"gh-t1","description":"GitHub tab: read-only foundation","name":"gh-t1","taskKind":"in_process_teammate","teamName":"session-653bd3db"}"#
        #expect(
            ClaudeTeammateFiles.teammate(meta: Data(teammate.utf8))
                == ClaudeTeammateFiles.Meta(name: "gh-t1", description: "GitHub tab: read-only foundation"))
        let other = #"{"agentType":"general-purpose","description":"Find it","name":"finder"}"#
        #expect(ClaudeTeammateFiles.teammate(meta: Data(other.utf8)) == nil)
    }

    @Test("A teammate's transcript end says whether its turn runs, since its prompt, or ended")
    func latestTurn() {
        #expect(Self.turn([Self.prompt, Self.reminder, Self.toolCall, Self.toolResult]) == .running(since: Self.date("2026-11-24T11:00:16.000Z")))
        #expect(Self.turn([Self.prompt, Self.toolCall, Self.answer]) == .ended(at: Self.date("2026-11-24T11:05:00.000Z"), state: .completed))
        // The next message from its mailbox opens the next turn.
        let next = Self.prompt.replacingOccurrences(of: "11:00:16", with: "11:09:00")
        #expect(Self.turn([Self.prompt, Self.answer, next]) == .running(since: Self.date("2026-11-24T11:09:00.000Z")))
        // A tail that starts inside a turn, and a line still being written.
        #expect(Self.turn([Self.toolCall, Self.toolResult, #"{"type":"assistant","timest"#], cutFirst: true) == .running(since: nil))
        #expect(Self.turn([], cutFirst: true) == nil)

        let apiError =
            #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-24T11:06:00.000Z","message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: 529"}]}}"#
        #expect(Self.turn([Self.prompt, apiError]) == .ended(at: Self.date("2026-11-24T11:06:00.000Z"), state: .failed))
        let interrupted =
            #"{"type":"user","timestamp":"2026-11-24T11:07:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        #expect(Self.turn([Self.prompt, Self.toolCall, interrupted]) == .ended(at: Self.date("2026-11-24T11:07:00.000Z"), state: .stopped))
        // Approving a shutdown request is the last record it writes.
        let shutdown =
            #"{"type":"user","timestamp":"2026-11-24T11:08:00.000Z","message":{"role":"user","content":"<teammate-message teammate_id=\"team-lead\">\n{\"type\":\"shutdown_request\",\"requestId\":\"shutdown-1@w\"}\n</teammate-message>"}}"#
        let approval =
            #"{"type":"assistant","timestamp":"2026-11-24T11:08:02.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t2","name":"SendMessage","input":{"to":"team-lead","message":{"type":"shutdown_response","request_id":"shutdown-1@w","approve":true}}}]}}"#
        #expect(Self.turn([Self.answer, shutdown, approval]) == .ended(at: Self.date("2026-11-24T11:08:02.000Z"), state: .stopped))
        let refusal = approval.replacingOccurrences(of: #""approve":true"#, with: #""approve":false"#)
        #expect(Self.turn([Self.answer, shutdown, refusal]) == .running(since: Self.date("2026-11-24T11:08:00.000Z")))
    }
}
