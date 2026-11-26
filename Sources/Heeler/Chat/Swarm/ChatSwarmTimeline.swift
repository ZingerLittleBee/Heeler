import SwiftUI
import UIKit

// MARK: - Off-Main-Actor Markdown Parser

/// Parses and memoizes Swarm Markdown blocks off the main actor so scrolling
/// and 1-second live Swarm polls never run `ChatMarkdown.blocks(from:)` on the
/// UI thread.
actor ChatSwarmMarkdownParser {
    struct Entry: Sendable {
        let key: String
        let source: String
        let blocks: [ChatMarkdownBlock]
    }

    private var cache: [String: (source: String, blocks: [ChatMarkdownBlock])] = [:]

    func parseBatch(
        _ items: [(key: String, source: String)],
        onChunk: @MainActor @Sendable ([Entry]) -> Void
    ) async {
        guard !items.isEmpty else { return }
        var chunk: [Entry] = []
        chunk.reserveCapacity(min(items.count, 8))
        var firstChunkSize = 6

        for (key, source) in items {
            if Task.isCancelled { return }
            let blocks: [ChatMarkdownBlock]
            if let existing = cache[key], existing.source == source {
                blocks = existing.blocks
            } else {
                let built = ChatMarkdown.blocks(from: source)
                cache[key] = (source, built)
                blocks = built
            }
            chunk.append(Entry(key: key, source: source, blocks: blocks))
            if chunk.count >= firstChunkSize {
                let ready = chunk
                chunk.removeAll(keepingCapacity: true)
                firstChunkSize = 24
                await onChunk(ready)
            }
        }
        if !chunk.isEmpty, !Task.isCancelled {
            await onChunk(chunk)
        }
    }

    func reset() {
        cache.removeAll()
    }
}

// MARK: - Board Filter, Row & Model

enum ChatSwarmBoardFilter: Equatable, Hashable, Sendable {
    case all
    case done
    case stall
    case channel(String)
    case author(String)

    func matches(_ message: AgySwarmSnapshot.BoardMessage) -> Bool {
        switch self {
        case .all:
            return true
        case .done:
            return message.isMarkedDone
        case .stall:
            return message.isMarkedStall
        case .channel(let name):
            return message.channel == name
        case .author(let name):
            return message.agent.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    var scopeKey: String {
        switch self {
        case .all: "*"
        case .done: "done"
        case .stall: "stall"
        case .channel(let name): "ch:\(name)"
        case .author(let name): "au:\(name.lowercased())"
        }
    }

    struct Option: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case neutral
            case done
            case stall
            case archivedChannel
        }

        let filter: ChatSwarmBoardFilter
        let label: String
        let count: Int?
        let kind: Kind

        var id: ChatSwarmBoardFilter { filter }
    }

    static func options(in swarm: AgySwarmSnapshot) -> [Option] {
        var result: [Option] = [
            Option(filter: .all, label: String(localized: "All"), count: nil, kind: .neutral),
        ]

        if !swarm.channels.isEmpty {
            result.append(
                Option(
                    filter: .channel(AgySwarmParser.mainChannel),
                    label: "#\(AgySwarmParser.mainChannel)",
                    count: nil,
                    kind: .neutral))
            for channel in swarm.channels {
                result.append(
                    Option(
                        filter: .channel(channel.name),
                        label: "#\(channel.name)",
                        count: nil,
                        kind: channel.isArchived ? .archivedChannel : .neutral))
            }
        }

        let doneCount = swarm.boardPosts.count { $0.isMarkedDone }
        if doneCount > 0 {
            result.append(
                Option(
                    filter: .done,
                    label: String(localized: "Done"),
                    count: doneCount,
                    kind: .done))
        }

        let stallCount = swarm.boardPosts.count { $0.isMarkedStall }
        if stallCount > 0 {
            result.append(
                Option(
                    filter: .stall,
                    label: String(localized: "Stall"),
                    count: stallCount,
                    kind: .stall))
        }

        var postAuthors: Set<String> = []
        var authorAppearance: [String] = []
        for post in swarm.boardPosts where !post.agent.isEmpty {
            let key = post.agent.lowercased()
            if postAuthors.insert(key).inserted {
                authorAppearance.append(post.agent)
            }
        }
        if authorAppearance.count >= 2 {
            var added: Set<String> = []
            var orderedAuthors: [String] = []
            for member in swarm.members {
                let key = member.name.lowercased()
                if postAuthors.contains(key), added.insert(key).inserted {
                    orderedAuthors.append(member.name)
                }
            }
            for author in authorAppearance {
                let key = author.lowercased()
                if added.insert(key).inserted {
                    orderedAuthors.append(author)
                }
            }
            for author in orderedAuthors {
                result.append(
                    Option(
                        filter: .author(author),
                        label: "@\(author)",
                        count: nil,
                        kind: .neutral))
            }
        }

        return result.count > 1 ? result : []
    }
}

struct ChatSwarmBoardRow: Sendable, Equatable {
    let message: AgySwarmSnapshot.BoardMessage
    let citedSeqs: [Int]
    /// Whether this row truncates in the directory and advertises opening the
    /// dedicated Post Detail reader.
    let opensDetail: Bool
    let isHighlighted: Bool
    /// The feed's first post, which takes top rounded corners and no divider.
    let isFirst: Bool
    /// The feed's last post, which takes bottom rounded corners.
    let isLast: Bool

    var seq: Int { message.seq }

    /// Compact inset-grouped directory row: heading over either a short post's
    /// full text or a 2-line preview with trailing line-count badge.
    var extent: ChatRowExtent {
        let previewBytes =
            opensDetail
            ? min(message.singleLinePreview.utf8.count, 120)
            : min(message.text.utf8.count, 130)
        return ChatRowExtent(
            textBytes: previewBytes,
            blocks: 1,
            chrome: 44,
            inset: opensDetail ? 112 : 60)
    }
}

/// Keeps pre-parsed Markdown blocks, row revisions, and measured cell heights
/// for an Agent's Swarm Board across tab switches and sheet presentations.
@MainActor
@Observable
final class ChatSwarmBoardModel {
    private struct RowSource: Equatable {
        var message: AgySwarmSnapshot.BoardMessage
        var citedSeqs: [Int]
        var opensDetail: Bool
        var isHighlighted: Bool
        var isFirst: Bool
        var isLast: Bool
    }

    private struct RowMemo {
        var source: RowSource
        var revision: Int
    }

    private(set) var blocksRevision = 0

    @ObservationIgnored private var parser = ChatSwarmMarkdownParser()
    @ObservationIgnored private var trackedSwarmID: String?
    @ObservationIgnored private var warmedBoardRevision: Int?
    @ObservationIgnored private var blocksBySeq: [Int: (text: String, blocks: [ChatMarkdownBlock])] = [:]
    @ObservationIgnored private var inFlightSeqs: [Int: String] = [:]
    @ObservationIgnored private var parseTask: Task<Void, Never>?
    @ObservationIgnored private var rowMemos: [Int: RowMemo] = [:]
    @ObservationIgnored private var lastRowRevision = 0
    @ObservationIgnored private(set) var measuredHeights: [Int: ChatMeasuredHeight] = [:]
    @ObservationIgnored private var scopeGeneration = 0
    @ObservationIgnored private var lastScopeKey: String?

    /// Pre-parses Markdown off the main actor for the newest few board posts
    /// so opening recent posts in the Post Detail reader is instantaneous
    /// without eagerly parsing dozens of offscreen posts.
    func warm(swarm: AgySwarmSnapshot?) {
        guard let swarm else {
            reset()
            return
        }
        if trackedSwarmID != swarm.id {
            reset()
            trackedSwarmID = swarm.id
        }
        guard warmedBoardRevision != swarm.boardRevision else { return }
        warmedBoardRevision = swarm.boardRevision
        enqueueMissingBlocks(posts: Array(swarm.boardPosts.suffix(4)))
    }

    func ensureBlocks(
        swarmID: String,
        posts: [AgySwarmSnapshot.BoardMessage]
    ) {
        if trackedSwarmID != swarmID {
            reset()
            trackedSwarmID = swarmID
        }
        enqueueMissingBlocks(posts: posts)
    }

    func parsedBlocks(for seq: Int, text: String) -> [ChatMarkdownBlock]? {
        let _ = blocksRevision
        guard let entry = blocksBySeq[seq], entry.text == text else { return nil }
        return entry.blocks
    }

    func generation(for swarmID: String, filter: ChatSwarmBoardFilter) -> Int {
        let key = "\(swarmID)|\(filter.scopeKey)"
        if lastScopeKey != key {
            lastScopeKey = key
            scopeGeneration &+= 1
        }
        return scopeGeneration
    }

    func buildState(
        swarmID: String,
        filter: ChatSwarmBoardFilter,
        posts: [AgySwarmSnapshot.BoardMessage],
        knownSeqs: Set<Int>,
        highlightedSeq: Int?
    ) -> ChatSwarmListState<Int, ChatSwarmBoardRow> {
        if trackedSwarmID != swarmID {
            reset()
            trackedSwarmID = swarmID
        }
        let gen = generation(for: swarmID, filter: filter)
        var deduped: [AgySwarmSnapshot.BoardMessage] = []
        deduped.reserveCapacity(posts.count)
        var seen: Set<Int> = []
        for post in posts where seen.insert(post.seq).inserted {
            deduped.append(post)
        }

        var items: [ChatSwarmListItem<Int, ChatSwarmBoardRow>] = []
        items.reserveCapacity(deduped.count)
        let lastIndex = deduped.count - 1

        for (index, post) in deduped.enumerated() {
            let cited = post.citedSeqs(in: knownSeqs)
            let opensDetail = post.isLongPost || post.isBrief || !cited.isEmpty
            let isFirst = index == 0
            let isLast = index == lastIndex
            let row = ChatSwarmBoardRow(
                message: post,
                citedSeqs: cited,
                opensDetail: opensDetail,
                isHighlighted: highlightedSeq == post.seq,
                isFirst: isFirst,
                isLast: isLast)
            let source = RowSource(
                message: post,
                citedSeqs: cited,
                opensDetail: opensDetail,
                isHighlighted: highlightedSeq == post.seq,
                isFirst: isFirst,
                isLast: isLast)
            let revision: Int
            if let old = rowMemos[post.seq], old.source == source {
                revision = old.revision
            } else {
                lastRowRevision &+= 1
                revision = lastRowRevision
                rowMemos[post.seq] = RowMemo(source: source, revision: revision)
            }
            items.append(
                ChatSwarmListItem(
                    id: post.seq,
                    payload: row,
                    revision: revision,
                    topSpacing: 0,
                    seed: .assistant,
                    extent: row.extent,
                    copyText: post.text.isEmpty ? nil : post.text))
        }

        return ChatSwarmListState(generation: gen, items: items)
    }

    func recordMeasuredHeight(_ height: ChatMeasuredHeight, for seq: Int) {
        measuredHeights[seq] = height
    }

    func forgetMeasuredHeights(keeping kept: Set<Int>) {
        measuredHeights = measuredHeights.filter { kept.contains($0.key) }
    }

    func settled() async {
        await parseTask?.value
    }

    func reset() {
        parseTask?.cancel()
        parseTask = nil
        trackedSwarmID = nil
        warmedBoardRevision = nil
        blocksBySeq.removeAll()
        inFlightSeqs.removeAll()
        rowMemos.removeAll()
        measuredHeights.removeAll()
        lastScopeKey = nil
        let oldParser = parser
        Task { await oldParser.reset() }
        parser = ChatSwarmMarkdownParser()
    }

    private func enqueueMissingBlocks(posts: [AgySwarmSnapshot.BoardMessage]) {
        var missing: [(seq: Int, key: String, source: String)] = []
        var seen: Set<Int> = []
        for post in posts where seen.insert(post.seq).inserted {
            if let existing = blocksBySeq[post.seq], existing.text == post.text {
                continue
            }
            missing.append((seq: post.seq, key: "post:\(post.seq)", source: post.text))
        }
        guard !missing.isEmpty else { return }

        // Skip cancelling an active parse if it is already covering the exact same targets.
        let alreadyCovered = missing.allSatisfy { inFlightSeqs[$0.seq] == $0.source }
        if alreadyCovered, parseTask != nil { return }

        parseTask?.cancel()
        inFlightSeqs = Dictionary(missing.map { ($0.seq, $0.source) }, uniquingKeysWith: { first, _ in first })
        let swarmID = trackedSwarmID
        let parser = self.parser
        let batch = missing.map { (key: $0.key, source: $0.source) }
        let seqByKey = Dictionary(missing.map { ($0.key, $0.seq) }, uniquingKeysWith: { first, _ in first })

        parseTask = Task { [weak self] in
            await parser.parseBatch(batch) { [weak self] entries in
                guard let self, self.trackedSwarmID == swarmID else { return }
                var changed = false
                for entry in entries {
                    guard let seq = seqByKey[entry.key] else { continue }
                    if self.inFlightSeqs[seq] == entry.source {
                        self.inFlightSeqs.removeValue(forKey: seq)
                    }
                    if self.blocksBySeq[seq]?.text != entry.source {
                        self.blocksBySeq[seq] = (entry.source, entry.blocks)
                        changed = true
                    }
                }
                if changed {
                    self.blocksRevision &+= 1
                }
            }
        }
    }
}

// MARK: - Worker Sub-Conversation Model

enum ChatSwarmWorkerItemID: Hashable, Sendable {
    case header
    case assignment
    case statusNotice
    case entry(ChatEntryID)
}

enum ChatSwarmWorkerRow: Sendable, Equatable {
    case header(AgySwarmSnapshot.Member)
    case assignment(post: AgySwarmSnapshot.BoardMessage, isExpanded: Bool, blocks: [ChatMarkdownBlock]?)
    case loading
    case failure(String)
    case empty
    case entry(ChatEntry, isCollapsible: Bool, lineCount: Int, isExpanded: Bool, blocks: [ChatMarkdownBlock]?)
}

@MainActor
@Observable
final class ChatSwarmWorkerModel {
    private struct RowMemo {
        var payload: ChatSwarmWorkerRow
        var topSpacing: CGFloat
        var revision: Int
    }

    private(set) var blocksRevision = 0

    @ObservationIgnored private var parser = ChatSwarmMarkdownParser()
    @ObservationIgnored private var trackedMember: String?
    @ObservationIgnored private var blocksByKey: [String: (text: String, blocks: [ChatMarkdownBlock])] = [:]
    @ObservationIgnored private var inFlightKeys: [String: String] = [:]
    @ObservationIgnored private var parseTask: Task<Void, Never>?
    @ObservationIgnored private var rowMemos: [ChatSwarmWorkerItemID: RowMemo] = [:]
    @ObservationIgnored private var lastRowRevision = 0
    @ObservationIgnored private(set) var measuredHeights: [ChatSwarmWorkerItemID: ChatMeasuredHeight] = [:]
    @ObservationIgnored private var generation = 0

    static func collapseInfo(for text: String) -> (isCollapsible: Bool, lineCount: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, 0) }
        let lines = AgySwarmSnapshot.BoardMessage.countLines(in: trimmed)
        let collapsible = lines >= 6 || trimmed.utf8.count > 360 || trimmed.contains("```")
        return (collapsible, lines)
    }

    func settled() async {
        await parseTask?.value
    }

    func ensureBlocks(
        memberName: String,
        assignment: AgySwarmSnapshot.BoardMessage?,
        isAssignmentExpanded: Bool,
        entries: [ChatEntry],
        expandedEntries: Set<ChatEntryID>
    ) {
        if trackedMember != memberName {
            reset(to: memberName)
        }
        var missing: [(key: String, source: String)] = []
        for entry in entries.reversed() {
            switch entry.content {
            case .assistant(let msg):
                let collapse = Self.collapseInfo(for: msg.text)
                guard !collapse.isCollapsible || expandedEntries.contains(entry.id) else { continue }
                let key = "entry:\(entry.id.rawValue)"
                if blocksByKey[key]?.text != msg.text {
                    missing.append((key: key, source: msg.text))
                }
            case .reasoning(let reasoning) where expandedEntries.contains(entry.id):
                let key = "reasoning:\(entry.id.rawValue)"
                if blocksByKey[key]?.text != reasoning.text {
                    missing.append((key: key, source: reasoning.text))
                }
            default:
                break
            }
        }
        if isAssignmentExpanded, let assignment {
            let key = "assignment:\(assignment.seq)"
            if blocksByKey[key]?.text != assignment.text {
                missing.insert((key: key, source: assignment.text), at: 0)
            }
        }
        guard !missing.isEmpty else { return }
        let alreadyCovered = missing.allSatisfy { inFlightKeys[$0.key] == $0.source }
        if alreadyCovered, parseTask != nil { return }

        parseTask?.cancel()
        inFlightKeys = Dictionary(missing.map { ($0.key, $0.source) }, uniquingKeysWith: { first, _ in first })
        let targetMember = memberName
        let parser = self.parser

        parseTask = Task { [weak self] in
            await parser.parseBatch(missing) { [weak self] built in
                guard let self, self.trackedMember == targetMember else { return }
                var changed = false
                for item in built {
                    if self.inFlightKeys[item.key] == item.source {
                        self.inFlightKeys.removeValue(forKey: item.key)
                    }
                    if self.blocksByKey[item.key]?.text != item.source {
                        self.blocksByKey[item.key] = (item.source, item.blocks)
                        changed = true
                    }
                }
                if changed {
                    self.blocksRevision &+= 1
                }
            }
        }
    }

    func buildState(
        memberName: String,
        member: AgySwarmSnapshot.Member?,
        assignment: AgySwarmSnapshot.BoardMessage?,
        isAssignmentExpanded: Bool,
        isLoading: Bool,
        failureMessage: String?,
        entries: [ChatEntry]?,
        expandedEntries: Set<ChatEntryID>
    ) -> ChatSwarmListState<ChatSwarmWorkerItemID, ChatSwarmWorkerRow> {
        let _ = blocksRevision
        if trackedMember != memberName {
            reset(to: memberName)
        }
        var items: [ChatSwarmListItem<ChatSwarmWorkerItemID, ChatSwarmWorkerRow>] = []

        func append(
            id: ChatSwarmWorkerItemID,
            payload: ChatSwarmWorkerRow,
            spacing: CGFloat,
            seed: ChatRowSeed,
            extent: ChatRowExtent?,
            copyText: String?
        ) {
            let topSpacing = items.isEmpty ? 0 : spacing
            let revision: Int
            if let old = rowMemos[id], old.payload == payload, old.topSpacing == topSpacing {
                revision = old.revision
            } else {
                lastRowRevision &+= 1
                revision = lastRowRevision
                rowMemos[id] = RowMemo(payload: payload, topSpacing: topSpacing, revision: revision)
            }
            items.append(
                ChatSwarmListItem(
                    id: id,
                    payload: payload,
                    revision: revision,
                    topSpacing: topSpacing,
                    seed: seed,
                    extent: extent,
                    copyText: copyText))
        }

        if let member {
            append(
                id: .header,
                payload: .header(member),
                spacing: 14,
                seed: .user,
                extent: nil,
                copyText: nil)
        }

        if let assignment {
            let key = "assignment:\(assignment.seq)"
            let blocks = isAssignmentExpanded ? blocks(forKey: key, text: assignment.text) : nil
            let extent =
                isAssignmentExpanded
                ? ChatRowExtent(
                    textBytes: assignment.text.utf8.count,
                    blocks: max(1, blocks?.count ?? 2),
                    chrome: 72,
                    inset: 60)
                : ChatRowExtent(textBytes: min(assignment.text.utf8.count, 140), blocks: 1, chrome: 60, inset: 88)
            append(
                id: .assignment,
                payload: .assignment(post: assignment, isExpanded: isAssignmentExpanded, blocks: blocks),
                spacing: 14,
                seed: .assistant,
                extent: extent,
                copyText: assignment.text)
        }

        if isLoading, entries == nil {
            append(id: .statusNotice, payload: .loading, spacing: 14, seed: .system, extent: nil, copyText: nil)
        } else if let failureMessage, entries == nil {
            append(
                id: .statusNotice,
                payload: .failure(failureMessage),
                spacing: 14,
                seed: .assistant,
                extent: nil,
                copyText: failureMessage)
        } else if let entries, !entries.isEmpty {
            // A run of tool calls reads as one list, so its rows stand
            // closer than a row does to prose.
            var followsTool = false
            for (idx, entry) in entries.enumerated() {
                guard Self.rendersEntry(entry) else { continue }
                let isExpanded = expandedEntries.contains(entry.id)
                let blocks: [ChatMarkdownBlock]?
                let seed: ChatRowSeed
                let extent: ChatRowExtent?
                let copyText: String?
                var isCollapsible = false
                var lineCount = 0

                switch entry.content {
                case .user(let msg):
                    let collapse = Self.collapseInfo(for: msg.displayText)
                    isCollapsible = collapse.isCollapsible
                    lineCount = collapse.lineCount
                    blocks = nil
                    seed = .user
                    if isCollapsible, !isExpanded {
                        extent = ChatRowExtent(
                            textBytes: min(msg.displayText.utf8.count, 160),
                            blocks: 1,
                            chrome: 46,
                            inset: 64)
                    } else {
                        extent = ChatRowExtent(
                            textBytes: msg.displayText.utf8.count,
                            blocks: 1,
                            chrome: isCollapsible ? 42 : 20,
                            inset: 64)
                    }
                    copyText = msg.displayText
                case .assistant(let msg):
                    let collapse = Self.collapseInfo(for: msg.text)
                    isCollapsible = collapse.isCollapsible
                    lineCount = collapse.lineCount
                    let key = "entry:\(entry.id.rawValue)"
                    seed = .assistant
                    if isCollapsible, !isExpanded {
                        blocks = nil
                        extent = ChatRowExtent(
                            textBytes: min(msg.text.utf8.count, 180),
                            blocks: 1,
                            chrome: 48,
                            inset: 56)
                    } else {
                        blocks = self.blocks(forKey: key, text: msg.text)
                        extent = ChatRowExtent(
                            textBytes: msg.text.utf8.count,
                            blocks: max(1, blocks?.count ?? (1 + msg.text.utf8.count / 180)),
                            chrome: isCollapsible ? 48 : 12,
                            inset: isCollapsible ? 56 : 32)
                    }
                    copyText = msg.text
                case .reasoning(let reasoning):
                    let key = "reasoning:\(entry.id.rawValue)"
                    blocks = isExpanded ? self.blocks(forKey: key, text: reasoning.text) : nil
                    seed = .reasoning
                    extent =
                        isExpanded
                        ? ChatRowExtent(
                            textBytes: reasoning.text.utf8.count,
                            blocks: max(1, blocks?.count ?? 2),
                            chrome: 46,
                            inset: 32)
                        : nil
                    copyText = reasoning.text
                case .tool(let tool):
                    blocks = nil
                    seed = .tool
                    extent = nil
                    let parts = [tool.title, tool.subtitle, tool.preview?.text, tool.fileChanges?.copyText]
                        .compactMap { $0 }.filter { !$0.isEmpty }
                    copyText = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
                case .notice(let notice):
                    blocks = nil
                    seed = .system
                    extent = nil
                    copyText = [notice.title, notice.detail].compactMap { $0 }.joined(separator: "\n")
                case .divider(let divider):
                    blocks = nil
                    seed = .system
                    extent = nil
                    copyText = divider.detail
                case .plan, .questions:
                    continue
                }

                let isTool = seed == .tool
                append(
                    id: .entry(entry.id),
                    payload: .entry(
                        entry,
                        isCollapsible: isCollapsible,
                        lineCount: lineCount,
                        isExpanded: isExpanded,
                        blocks: blocks),
                    spacing: idx == 0 ? 14 : (isTool && followsTool ? 6 : 10),
                    seed: seed,
                    extent: extent,
                    copyText: copyText?.isEmpty == true ? nil : copyText)
                followsTool = isTool
            }
        } else {
            append(id: .statusNotice, payload: .empty, spacing: 14, seed: .assistant, extent: nil, copyText: nil)
        }

        return ChatSwarmListState(generation: generation, items: items)
    }

    func recordMeasuredHeight(_ height: ChatMeasuredHeight, for id: ChatSwarmWorkerItemID) {
        measuredHeights[id] = height
    }

    func forgetMeasuredHeights(keeping kept: Set<ChatSwarmWorkerItemID>) {
        measuredHeights = measuredHeights.filter { kept.contains($0.key) }
    }

    private func blocks(forKey key: String, text: String) -> [ChatMarkdownBlock]? {
        guard let existing = blocksByKey[key], existing.text == text else { return nil }
        return existing.blocks
    }

    private func reset(to memberName: String) {
        parseTask?.cancel()
        parseTask = nil
        trackedMember = memberName
        blocksByKey.removeAll()
        inFlightKeys.removeAll()
        rowMemos.removeAll()
        measuredHeights.removeAll()
        generation &+= 1
        let oldParser = parser
        Task { await oldParser.reset() }
        parser = ChatSwarmMarkdownParser()
    }

    private static func rendersEntry(_ entry: ChatEntry) -> Bool {
        switch entry.content {
        case .reasoning(let r):
            return !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .divider(let d):
            return !(d.detail ?? "").isEmpty
        case .plan, .questions:
            return false
        case .user, .assistant, .tool, .notice:
            return true
        }
    }
}

// MARK: - Recycling Collection View Infrastructure

struct ChatSwarmListItem<ItemID: Hashable & Sendable, Payload: Sendable>: Sendable {
    let id: ItemID
    let payload: Payload
    let revision: Int
    let topSpacing: CGFloat
    let seed: ChatRowSeed
    let extent: ChatRowExtent?
    let copyText: String?
}

struct ChatSwarmListState<ItemID: Hashable & Sendable, Payload: Sendable>: Sendable {
    let generation: Int
    let items: [ChatSwarmListItem<ItemID, Payload>]
}

struct ChatSwarmScrollRequest<ItemID: Hashable & Sendable>: Equatable, Sendable {
    let nonce: Int
    let target: ItemID
}

struct ChatSwarmListView<ItemID: Hashable & Sendable, Payload: Sendable, RowContent: View>: UIViewControllerRepresentable {
    let state: ChatSwarmListState<ItemID, Payload>
    var scrollRequest: ChatSwarmScrollRequest<ItemID>? = nil
    var disclosureAnchor: ItemID? = nil
    var initialMeasuredHeights: [ItemID: ChatMeasuredHeight] = [:]
    var onMeasure: (ItemID, ChatMeasuredHeight) -> Void = { _, _ in }
    var onForgetMeasurements: (Set<ItemID>) -> Void = { _ in }
    let accessibilityIdentifier: String
    @ViewBuilder let rowContent: @MainActor (ChatSwarmListItem<ItemID, Payload>) -> RowContent

    func makeCoordinator() -> Coordinator {
        Coordinator(lastScrollNonce: scrollRequest?.nonce)
    }

    func makeUIViewController(context: Context) -> ChatSwarmListController<ItemID, Payload, RowContent> {
        let controller = ChatSwarmListController<ItemID, Payload, RowContent>(
            accessibilityIdentifier: accessibilityIdentifier,
            rowContent: rowContent)
        controller.onMeasure = onMeasure
        controller.onForgetMeasurements = onForgetMeasurements
        controller.disclosureAnchor = disclosureAnchor
        if !initialMeasuredHeights.isEmpty {
            controller.seedMeasurements(initialMeasuredHeights)
        }
        controller.apply(state)
        if let req = scrollRequest {
            context.coordinator.lastScrollNonce = req.nonce
            controller.scrollToItem(req.target, animated: false)
        }
        return controller
    }

    func updateUIViewController(
        _ controller: ChatSwarmListController<ItemID, Payload, RowContent>,
        context: Context
    ) {
        controller.rowContent = rowContent
        controller.onMeasure = onMeasure
        controller.onForgetMeasurements = onForgetMeasurements
        controller.disclosureAnchor = disclosureAnchor
        controller.apply(state)
        if let req = scrollRequest, context.coordinator.lastScrollNonce != req.nonce {
            context.coordinator.lastScrollNonce = req.nonce
            controller.scrollToItem(req.target, animated: true)
        }
    }

    @MainActor
    final class Coordinator {
        var lastScrollNonce: Int?

        init(lastScrollNonce: Int?) {
            self.lastScrollNonce = lastScrollNonce
        }
    }
}

/// UIKit collection view controller with true cell recycling, offscreen SwiftUI
/// teardown (`didEndDisplaying`), estimated-height stability (`ChatTimelineGeometry`),
/// and bottom follow-latching (`ChatFollowLatch`).
@MainActor
final class ChatSwarmListController<ItemID: Hashable & Sendable, Payload: Sendable, RowContent: View>:
    UIViewController, UICollectionViewDelegate
{
    var rowContent: @MainActor (ChatSwarmListItem<ItemID, Payload>) -> RowContent
    var onMeasure: (ItemID, ChatMeasuredHeight) -> Void = { _, _ in }
    var onForgetMeasurements: (Set<ItemID>) -> Void = { _ in }
    var disclosureAnchor: ItemID?

    private let listAccessibilityIdentifier: String
    private let layout = ChatSwarmCollectionLayout<ItemID>()
    private lazy var collectionView = ChatSwarmCollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, ItemID>?
    private var appliedGeneration: Int?
    private var heldState: ChatSwarmListState<ItemID, Payload>?
    private var itemsByID: [ItemID: ChatSwarmListItem<ItemID, Payload>] = [:]
    private var orderedIDs: [ItemID] = []
    private var latch = ChatFollowLatch()
    private var isUpdatingRows = false
    private var pendingScrollTarget: ItemID?

    private(set) var cellBuilds = 0
    var isFollowing: Bool { latch.isFollowing }
    var timeline: UICollectionView { collectionView }

    var visibleItemIDs: [ItemID] {
        collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .compactMap { layout.id(at: $0.item) }
    }

    private static var contentInsets: UIEdgeInsets {
        UIEdgeInsets(top: 12, left: 0, bottom: 22, right: 0)
    }

    init(
        accessibilityIdentifier: String,
        rowContent: @escaping @MainActor (ChatSwarmListItem<ItemID, Payload>) -> RowContent
    ) {
        self.listAccessibilityIdentifier = accessibilityIdentifier
        self.rowContent = rowContent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func seedMeasurements(_ saved: [ItemID: ChatMeasuredHeight]) {
        layout.seedMeasurements(saved)
    }

    override func loadView() {
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.contentInset = Self.contentInsets
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.keyboardDismissMode = .interactive
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.accessibilityIdentifier = listAccessibilityIdentifier
        collectionView.delegate = self
        collectionView.shouldPin = { [weak self] in
            guard let self else { return false }
            return self.latch.isFollowing && self.pendingScrollTarget == nil
        }

        layout.itemIDs = { [weak self] in self?.orderedIDs ?? [] }
        layout.rowInfo = { [weak self] id in
            guard let self, let item = self.itemsByID[id] else { return nil }
            var hasher = Hasher()
            hasher.combine(item.revision)
            hasher.combine(item.topSpacing)
            return (item.seed, item.extent, hasher.finalize())
        }
        layout.isFollowing = { [weak self] in self?.latch.isFollowing ?? true }
        layout.disclosureAnchor = { [weak self] in self?.disclosureAnchor }
        layout.onMeasure = { [weak self] id, measured in
            self?.onMeasure(id, measured)
        }
        layout.onForgetMeasurements = { [weak self] kept in
            self?.onForgetMeasurements(kept)
        }

        let registration = UICollectionView.CellRegistration<ChatSwarmHostingCell<ItemID>, ItemID> {
            [weak self] cell, _, id in
            guard let self, let item = self.itemsByID[id] else { return }
            self.cellBuilds += 1
            cell.itemID = id
            let builder = self.rowContent
            cell.contentConfiguration = UIHostingConfiguration {
                builder(item)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, item.topSpacing)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
                    .frame(maxWidth: .infinity)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
            cell.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        view = collectionView

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: Self, _: UITraitCollection) in
            self.layout.invalidateLayout()
        }
    }

    func apply(_ state: ChatSwarmListState<ItemID, Payload>) {
        loadViewIfNeeded()
        guard let dataSource else { return }

        if appliedGeneration == state.generation, isHoldingUpdatesForUserScroll {
            heldState = state
            return
        }
        heldState = nil

        let oldItems = itemsByID
        let newOrdered = state.items.map(\.id)
        let newMap = Dictionary(state.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if appliedGeneration == state.generation, orderedIDs == newOrdered {
            let changed = newOrdered.filter { id in
                guard let old = oldItems[id], let next = newMap[id] else { return true }
                return old.revision != next.revision || old.topSpacing != next.topSpacing
            }
            if changed.isEmpty { return }
        }

        itemsByID = newMap
        orderedIDs = newOrdered

        guard appliedGeneration == state.generation else {
            appliedGeneration = state.generation
            pendingScrollTarget = nil
            latch.reset()
            var snapshot = NSDiffableDataSourceSnapshot<Int, ItemID>()
            snapshot.appendSections([0])
            snapshot.appendItems(newOrdered)
            UIView.performWithoutAnimation {
                isUpdatingRows = true
                dataSource.applySnapshotUsingReloadData(snapshot)
                isUpdatingRows = false
                collectionView.layoutIfNeeded()
                pinToEnd()
                // Second pass ensures cells newly realized at the bottom measure
                // to their exact heights before settling at `maxOffsetY`.
                collectionView.layoutIfNeeded()
                pinToEnd()
            }
            layout.forgetMeasurements(keeping: Set(newOrdered))
            return
        }

        let anchor = captureAnchor()
        let changed = newOrdered.filter { id in
            guard let old = oldItems[id], let next = newMap[id] else { return false }
            return old.revision != next.revision || old.topSpacing != next.topSpacing
        }
        let heightsBefore = rowHeights(changed)

        var snapshot = NSDiffableDataSourceSnapshot<Int, ItemID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newOrdered)
        if !changed.isEmpty {
            snapshot.reconfigureItems(changed)
        }

        UIView.performWithoutAnimation {
            layout.updateAnchor = anchor
            isUpdatingRows = true
            dataSource.apply(snapshot, animatingDifferences: false)
            isUpdatingRows = false
            layout.updateAnchor = nil
            collectionView.layoutIfNeeded()
            restore(anchor)
            collectionView.layoutIfNeeded()
            restore(anchor)
        }

        redrawResizedRows(changed, heightsBefore: heightsBefore)
        if disclosureAnchor != nil {
            latch.disclosureSettled(
                isAtEnd: ChatFollowLatch.isAtEnd(
                    offset: collectionView.contentOffset.y,
                    maxOffset: collectionView.maxOffsetY))
        }
        layout.forgetMeasurements(keeping: Set(newOrdered))
    }

    func scrollToItem(_ id: ItemID, animated: Bool) {
        loadViewIfNeeded()
        guard let index = layout.index(of: id) else { return }
        pendingScrollTarget = id
        if index < max(0, orderedIDs.count - 1) {
            latch.disclosureSettled(isAtEnd: false)
        } else {
            latch.reset()
        }
        collectionView.layoutIfNeeded()
        let targetY = centeredOffsetY(forIndex: index)
        collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
        if !animated {
            collectionView.layoutIfNeeded()
            let refinedY = centeredOffsetY(forIndex: index)
            if abs(collectionView.contentOffset.y - refinedY) >= 1 {
                collectionView.setContentOffset(CGPoint(x: 0, y: refinedY), animated: false)
            }
            pendingScrollTarget = nil
        }
    }

    private func centeredOffsetY(forIndex index: Int) -> CGFloat {
        let minY = layout.geometry.minY(at: index)
        let height = layout.geometry.height(at: index)
        let visibleHeight = ChatSwarmCollectionLayout<ItemID>.visibleHeight(of: collectionView)
        let rawY: CGFloat
        if height >= visibleHeight * 0.85 {
            // Long cards align near their top header rather than burying `#seq` above screen.
            rawY = minY - collectionView.adjustedContentInset.top - 12
        } else {
            rawY = minY - collectionView.adjustedContentInset.top - max(0, (visibleHeight - height) / 2)
        }
        return min(max(rawY, collectionView.minOffsetY), collectionView.maxOffsetY)
    }

    private func pinToEnd() {
        collectionView.contentOffset.y = collectionView.maxOffsetY
    }

    private func captureAnchor() -> (id: ItemID, distance: CGFloat)? {
        guard !latch.isFollowing else { return nil }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if let disc = disclosureAnchor, let idx = layout.index(of: disc) {
            return (disc, layout.geometry.minY(at: idx) - visibleTop)
        }
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        guard let anchor = layout.geometry.readingAnchor(visibleTop: visibleTop, visibleBottom: visibleBottom),
            let id = layout.id(at: anchor.index)
        else { return nil }
        return (id, anchor.minY - visibleTop)
    }

    private var isHoldingUpdatesForUserScroll: Bool {
        ChatFollowLatch.shouldHoldUpdate(
            isHeldPastEnd: false,
            isHeldPastStart: false,
            sameGeneration: true,
            isHoldingTopJump: false,
            isUserScrolling: latch.isUserScrolling,
            isTracking: collectionView.isTracking,
            isDecelerating: collectionView.isDecelerating)
    }

    private func releaseHoldIfBack() {
        guard !isHoldingUpdatesForUserScroll, let state = heldState else { return }
        heldState = nil
        apply(state)
    }

    private func restore(_ anchor: (id: ItemID, distance: CGFloat)?) {
        if latch.isFollowing, pendingScrollTarget == nil {
            pinToEnd()
            return
        }
        guard let anchor, let index = layout.index(of: anchor.id) else { return }
        let targetY = layout.geometry.minY(at: index) - anchor.distance - collectionView.adjustedContentInset.top
        collectionView.contentOffset.y = min(max(targetY, collectionView.minOffsetY), collectionView.maxOffsetY)
    }

    private func rowHeights(_ ids: [ItemID]) -> [ItemID: CGFloat] {
        var heights: [ItemID: CGFloat] = [:]
        for id in ids {
            if let index = layout.index(of: id) {
                heights[id] = layout.geometry.height(at: index)
            }
        }
        return heights
    }

    private func redrawResizedRows(_ ids: [ItemID], heightsBefore: [ItemID: CGFloat]) {
        let resized = ids.filter { id in
            guard let before = heightsBefore[id], let index = layout.index(of: id) else { return false }
            return abs(layout.geometry.height(at: index) - before) >= 0.5
        }
        guard !resized.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for id in resized {
                guard let index = self.layout.index(of: id),
                    let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 0))
                else { continue }
                cell.contentView.setNeedsLayout()
                cell.contentView.layoutIfNeeded()
            }
        }
    }

    // MARK: UIScrollViewDelegate & UICollectionViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingScrollTarget = nil
        disclosureAnchor = nil
        latch.userScrollBegan()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isUpdatingRows else { return }
        let atEnd = ChatFollowLatch.isAtEnd(
            offset: collectionView.contentOffset.y,
            maxOffset: collectionView.maxOffsetY)
        latch.scrolled(isAtEnd: atEnd)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        latch.userScrollEnded(
            isAtEnd: ChatFollowLatch.isAtEnd(
                offset: collectionView.contentOffset.y,
                maxOffset: collectionView.maxOffsetY))
        releaseHoldIfBack()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        latch.userScrollEnded(
            isAtEnd: ChatFollowLatch.isAtEnd(
                offset: collectionView.contentOffset.y,
                maxOffset: collectionView.maxOffsetY) && !scrollView.isTracking)
        releaseHoldIfBack()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        pendingScrollTarget = nil
        disclosureAnchor = nil
        latch.userScrollBegan()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        latch.userScrollEnded(
            isAtEnd: ChatFollowLatch.isAtEnd(
                offset: collectionView.contentOffset.y,
                maxOffset: collectionView.maxOffsetY))
        releaseHoldIfBack()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if let target = pendingScrollTarget, let index = layout.index(of: target) {
            pendingScrollTarget = nil
            collectionView.layoutIfNeeded()
            let refinedY = centeredOffsetY(forIndex: index)
            if abs(collectionView.contentOffset.y - refinedY) >= 2 {
                collectionView.setContentOffset(CGPoint(x: 0, y: refinedY), animated: false)
            }
        }
    }

    /// Only tear down cells for items that left the data source. A cell that
    /// merely scrolled outside the viewport stays in UIKit's prepared cache
    /// and may be brought back onscreen without calling `cellForItemAt`.
    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let hosting = cell as? ChatSwarmHostingCell<ItemID>,
            let id = hosting.itemID,
            dataSource?.indexPath(for: id) == nil
        else { return }
        hosting.itemID = nil
        hosting.contentConfiguration = nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1,
            let indexPath = indexPaths.first,
            let id = dataSource?.itemIdentifier(for: indexPath),
            let text = itemsByID[id]?.copyText,
            !text.isEmpty
        else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                },
                UIAction(
                    title: String(localized: "Select Text"),
                    image: UIImage(systemName: "selection.pin.in.out")
                ) { [weak self] _ in
                    guard let self else { return }
                    TerminalTextSelectionPresenter.present(
                        text: text,
                        font: .preferredFont(
                            forTextStyle: .body,
                            compatibleWith: self.collectionView.traitCollection),
                        adjustsFontForContentSizeCategory: true,
                        accessibilityIdentifier: "chat.swarm.text-selection",
                        from: self.collectionView)
                },
            ])
        }
    }
}

final class ChatSwarmCollectionView: UICollectionView {
    var shouldPin: () -> Bool = { false }

    var minOffsetY: CGFloat { -adjustedContentInset.top }

    var maxOffsetY: CGFloat {
        max(minOffsetY, contentSize.height + adjustedContentInset.bottom - bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard shouldPin() else { return }
        let end = maxOffsetY
        if abs(contentOffset.y - end) > 0.25 {
            contentOffset.y = end
        }
    }
}

final class ChatSwarmHostingCell<ItemID: Hashable & Sendable>: UICollectionViewCell {
    var itemID: ItemID?

    override var safeAreaInsets: UIEdgeInsets {
        let insets = super.safeAreaInsets
        return UIEdgeInsets(top: 0, left: insets.left, bottom: 0, right: insets.right)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let fitted = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else {
            return layoutAttributes
        }
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        fitted.size.height = (size.height * scale).rounded(.up) / scale
        return fitted
    }
}

/// Vertical self-sizing collection view layout backed by `ChatTimelineGeometry`,
/// keeping content top-aligned when short (`visibleHeight = 0`) and anchoring
/// visible content cleanly when offscreen/above-viewport items self-size.
@MainActor
final class ChatSwarmCollectionLayout<ItemID: Hashable & Sendable>: UICollectionViewLayout {
    var itemIDs: () -> [ItemID] = { [] }
    var rowInfo: (ItemID) -> (seed: ChatRowSeed, extent: ChatRowExtent?, revision: Int)? = { _ in nil }
    var isFollowing: () -> Bool = { true }
    var disclosureAnchor: () -> ItemID? = { nil }
    var onMeasure: ((ItemID, ChatMeasuredHeight) -> Void)?
    var onForgetMeasurements: ((Set<ItemID>) -> Void)?
    var updateAnchor: (id: ItemID, distance: CGFloat)?

    private(set) var geometry = ChatTimelineGeometry()
    private var ids: [ItemID] = []
    private var indexByID: [ItemID: Int] = [:]
    private var measured: [ItemID: ChatMeasuredHeight] = [:]
    private var width: CGFloat = 0
    private var contentSizeCategory = ""
    private var textWidth: CGFloat = 0
    private var textMetrics = ChatTextMetrics.standard

    func index(of id: ItemID) -> Int? {
        indexByID[id]
    }

    func id(at index: Int) -> ItemID? {
        ids.indices.contains(index) ? ids[index] : nil
    }

    func seedMeasurements(_ saved: [ItemID: ChatMeasuredHeight]) {
        for (id, entry) in saved where measured[id] == nil {
            measured[id] = entry
        }
    }

    func forgetMeasurements(keeping kept: Set<ItemID>) {
        measured = measured.filter { kept.contains($0.key) }
        onForgetMeasurements?(kept)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let ids = itemIDs()
        let width = max(0, collectionView.bounds.width)
        let traits = collectionView.traitCollection
        let category = traits.preferredContentSizeCategory.rawValue
        if ids != self.ids || width != self.width || category != contentSizeCategory {
            self.ids = ids
            self.width = width
            contentSizeCategory = category
            textWidth = max(
                0,
                min(width, ChatTimelineMetrics.maximumContentWidth) - 2 * ChatTimelineMetrics.horizontalPadding)
            let standard = ChatTextMetrics.standard
            textMetrics = ChatTextMetrics(
                pointSize: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize,
                lineHeight: UIFontMetrics(forTextStyle: .body).scaledValue(
                    for: standard.lineHeight,
                    compatibleWith: traits))
            indexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            geometry.setHeights(ids.map(estimatedHeight))
        }
        geometry.visibleHeight = 0
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: geometry.totalHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.indices(from: rect.minY, to: rect.maxY).map(attributes(at:))
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item < geometry.count else { return nil }
        return attributes(at: indexPath.item)
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let anchor = updateAnchor, let index = indexByID[anchor.id], let collectionView else {
            return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }
        let insets = collectionView.adjustedContentInset
        let start = -insets.top
        let end = max(start, geometry.totalHeight + insets.bottom - collectionView.bounds.height)
        return CGPoint(
            x: proposedContentOffset.x,
            y: min(max(geometry.minY(at: index) - anchor.distance - insets.top, start), end))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let index = preferredAttributes.indexPath.item
        guard preferredAttributes.representedElementCategory == .cell, index < geometry.count else {
            return false
        }
        guard abs(preferredAttributes.size.height - geometry.height(at: index)) >= 0.5 else {
            record(preferredAttributes.size.height, at: index)
            return false
        }
        return true
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes)
        let index = preferredAttributes.indexPath.item
        guard let collectionView, index < geometry.count else { return context }
        let anchor = isFollowing() ? nil : stableAnchor(in: collectionView)
        record(preferredAttributes.size.height, at: index)
        let delta = geometry.setHeight(preferredAttributes.size.height, at: index)
        context.contentSizeAdjustment = CGSize(width: 0, height: delta)
        let adjustment = geometry.offsetAdjustment(restoring: anchor)
        if adjustment != 0 {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: adjustment)
        }
        return context
    }

    private func stableAnchor(in collectionView: UICollectionView) -> ChatTimelineAnchor? {
        if let id = disclosureAnchor(), let index = indexByID[id] {
            return ChatTimelineAnchor(index: index, minY: geometry.minY(at: index))
        }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return geometry.readingAnchor(visibleTop: visibleTop, visibleBottom: visibleBottom)
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = CGRect(
            x: 0,
            y: geometry.minY(at: index),
            width: width,
            height: geometry.height(at: index))
        return attributes
    }

    private func record(_ height: CGFloat, at index: Int) {
        guard let id = id(at: index), let info = rowInfo(id) else { return }
        let entry = ChatMeasuredHeight(
            height: height,
            width: width,
            contentSizeCategory: contentSizeCategory,
            revision: info.revision)
        measured[id] = entry
        onMeasure?(id, entry)
    }

    private func estimatedHeight(for id: ItemID) -> CGFloat {
        guard let info = rowInfo(id) else { return ChatRowSeed.system.height }
        return ChatHeightEstimate(
            cached: measured[id],
            seed: info.seed,
            extent: info.extent,
            textWidth: textWidth,
            metrics: textMetrics,
            width: width,
            contentSizeCategory: contentSizeCategory,
            revision: info.revision
        ).height
    }

    static func visibleHeight(of collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(0, collectionView.bounds.height - insets.top - insets.bottom)
    }
}
