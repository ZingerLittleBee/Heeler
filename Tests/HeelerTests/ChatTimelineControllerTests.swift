import Foundation
import Testing

@testable import Heeler

/// Entries the timeline suites share.
enum ChatTimelineFixture {
    /// A conversation of user prompts, tool calls and answers of varied
    /// length; the same index always makes the same entry.
    static func entries(_ range: Range<Int>) -> [ChatEntry] {
        range.map { index in
            let content: ChatEntry.Content
            switch index % 4 {
            case 0:
                content = .user(ChatUserMessage(text: "Question \(index): what changed in this part?"))
            case 1:
                let output = (1...12).map { "line \($0) of output from step \(index)" }.joined(separator: "\n")
                content = .tool(
                    ChatToolActivity(
                        kind: .command, name: "Bash", title: "ls -la src/\(index)", status: .succeeded,
                        preview: ChatToolPreview(text: output, isTruncated: false)))
            default:
                content = .assistant(
                    ChatAssistantMessage(
                        text: "Answer \(index). "
                            + String(repeating: "This sentence adds a little length. ", count: 1 + index % 9)))
            }
            return ChatEntry(id: ChatEntryID("e\(index)"), sourceOffset: UInt64(index) * 100, content: content)
        }
    }
}

@MainActor
@Suite("Chat timeline model")
struct ChatTimelineModelTests {
    @Test func publishesTheNewestRequestAndNumbersConversations() async {
        let model = ChatTimelineModel()
        let entries = ChatTimelineFixture.entries(0..<5)
        model.update(conversation: 7, input: ChatTimelineInput(entries: Array(entries.prefix(2))), isReady: false)
        model.update(conversation: 7, input: ChatTimelineInput(entries: entries), isReady: true)
        await model.settled()
        #expect(model.state.rows.map(\.id) == entries.map { .entry($0.id) })
        #expect(model.state.isReady)
        let generation = model.state.generation
        let revision = model.state.revision

        model.update(conversation: 7, input: ChatTimelineInput(entries: entries), isReady: false)
        await model.settled()
        #expect(model.state.generation == generation)
        #expect(model.state.revision > revision)
        #expect(model.state.isReady, "readiness holds within one conversation")

        model.update(conversation: 8, input: ChatTimelineInput(), isReady: false)
        await model.settled()
        #expect(model.state.generation == generation + 1)
        #expect(model.state.rows.isEmpty)
        #expect(!model.state.isReady)
    }

    @Test func updateIfNeededSkipsIdenticalRequestAndUpdatesSignalsSynchronously() async {
        let model = ChatTimelineModel()
        let entries = ChatTimelineFixture.entries(0..<3)
        let input = ChatTimelineInput(entries: entries)
        let cachedSignals = ChatTurnSignals(activity: .idle, foldsFinishedTurns: true, isLive: false)
        model.updateIfNeeded(conversation: 1, input: input, signals: cachedSignals, isReady: true)
        await model.settled()

        let revisionAfterBuild = model.state.revision
        let generation = model.state.generation
        let rowID = ChatRowID.entry(entries[0].id)
        let measured = ChatMeasuredHeight(height: 84, width: 390, contentSizeCategory: "L|system", revision: 1)
        model.recordMeasuredHeight(measured, for: rowID, generation: generation)
        #expect(model.measuredHeights[rowID] == measured)

        // Identical feed on surface re-mount is a no-op.
        model.updateIfNeeded(conversation: 1, input: input, signals: cachedSignals, isReady: true)
        #expect(model.state.revision == revisionAfterBuild)

        // Signal-only change (e.g. cache confirmed live) updates synchronously on MainActor
        // without waiting on the async row builder.
        let liveSignals = ChatTurnSignals(activity: .idle, foldsFinishedTurns: true, isLive: true)
        model.updateIfNeeded(conversation: 1, input: input, signals: liveSignals, isReady: true)
        #expect(model.state.revision == revisionAfterBuild + 1)
        #expect(model.state.signals == liveSignals)
        #expect(model.measuredHeights[rowID] == measured)

        model.reset()
        #expect(model.state.rows.isEmpty)
        #expect(model.measuredHeights.isEmpty)
    }
}

@Suite("Chat row builder")
struct ChatRowBuilderTests {
    @Test func unchangedEntriesKeepTheirRevisionAndChangedOnesMove() async {
        let builder = ChatRowBuilder()
        var entries = ChatTimelineFixture.entries(0..<4)
        let first = await builder.rows(for: ChatTimelineInput(entries: entries))
        if case .assistant(var message) = entries[2].content {
            message.text += " Edited."
            entries[2].content = .assistant(message)
        }
        let second = await builder.rows(for: ChatTimelineInput(entries: entries))
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first[0].revision == second[0].revision)
        #expect(first[1].revision == second[1].revision)
        #expect(first[2].revision != second[2].revision)
        #expect(first[3].revision == second[3].revision)
        guard case .assistant(let source, let blocks) = second[2].content else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(source.hasSuffix("Edited."))
        #expect(!blocks.isEmpty)
    }

    @Test func aRowWhoseSpacingChangesIsANewRevision() async {
        let builder = ChatRowBuilder()
        let entries = ChatTimelineFixture.entries(0..<4)
        let first = await builder.rows(for: ChatTimelineInput(entries: Array(entries.dropFirst())))
        let second = await builder.rows(for: ChatTimelineInput(entries: entries))
        // The tool row led the list; now a prompt sits above it.
        #expect(first[0].topSpacing != second[1].topSpacing)
        #expect(first[0].revision != second[1].revision)
        #expect(first[1].revision == second[2].revision)
    }

    @Test func olderHistoryLeadsAndPendingEchoesTrail() async {
        let builder = ChatRowBuilder()
        let echo = ChatPendingEcho(id: UUID(), text: "Ship it", state: .sending)
        let entries = ChatTimelineFixture.entries(0..<2)
        let rows = await builder.rows(
            for: ChatTimelineInput(entries: entries, pending: [echo], older: .available))
        #expect(rows.map(\.id) == [.olderHistory] + entries.map { .entry($0.id) } + [.pending(echo.id)])
        #expect(rows[0].topSpacing == 8)
        #expect(rows[1].topSpacing == 24)

        let atStart = await builder.rows(for: ChatTimelineInput(entries: entries, older: .reachedStart))
        #expect(atStart.first?.id == .entry(entries[0].id))
    }

    @Test func stepsOfOneTurnSitCloserThanTurns() {
        let tool = ChatRow.Content.tool(ChatToolActivity(kind: .command, name: "Bash", title: "ls", status: .succeeded))
        let user = ChatRow.Content.user(ChatUserMessage(text: "Hi"))
        #expect(ChatRowBuilder.spacing(before: tool, after: tool) < ChatRowBuilder.spacing(before: tool, after: user))
        #expect(ChatRowBuilder.spacing(before: user, after: tool) > ChatRowBuilder.spacing(before: tool, after: user))
        #expect(ChatRowBuilder.spacing(before: user, after: nil) == 8)
    }
}

@MainActor
@Suite("Chat row view")
struct ChatRowViewTests {
    /// A notice that shows a readable form of its text copies the text as
    /// recorded.
    @Test func aNoticeCopiesItsRawDetail() async throws {
        let notice = ChatNotice(
            kind: .error, title: "Turn failed", detail: "Not supported.", rawDetail: #"{"message":"Not supported."}"#)
        let plain = ChatNotice(kind: .error, title: "Turn failed", detail: "Disconnected")
        let entries = [notice, plain].enumerated().map { index, notice in
            ChatEntry(id: ChatEntryID("n\(index)"), sourceOffset: UInt64(index), content: .notice(notice))
        }
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: entries))
        let copied = entries.map { entry in rows.first { $0.id == .entry(entry.id) }?.copyText }
        #expect(copied == ["Turn failed\n{\"message\":\"Not supported.\"}", "Turn failed\nDisconnected"])
    }
}

