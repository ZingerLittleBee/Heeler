import Foundation

/// The records of the conversation's current branch, ready to project.
struct ClaudeChain: Sendable, Equatable {
    /// Selected records in byte-offset order.
    var records: [ClaudeRecord] = []
    /// The newest user or assistant record of the current branch.
    var leafUUID: String?
    /// The record the walk started from: the leaf, or a record below it such
    /// as the turn's `turn_duration`.
    var terminalUUID: String?
    /// The first parent the walk needed that no fed line holds. In a tail
    /// window it is the record an older page will bring.
    var missingParent: String?
    /// Parent pointers after compaction relinking, for every indexed record.
    var parents: [String: String] = [:]
}

/// Picks the current branch out of the `parentUuid` tree (brief §2).
///
/// This ports the SDK reader (`Eu` and the intent of `cCe`) and extends it
/// past compactions so history stays visible: compaction relinks preserved
/// messages, the newest eligible terminal picks the branch, the walk goes up
/// from that terminal, and at a `compact_boundary` it continues from the
/// newest terminal written before the boundary. Records the walk leaves out
/// but that belong to it (parallel tool results, split blocks) are recovered
/// as siblings. Everything else is a rolled-back or abandoned branch and
/// stays hidden. The result is ordered by byte offset, which equals chain
/// order for a linear chain and leaves preserved records where they were
/// written.
enum ClaudeChainResolver {
    /// - Parameter bridgesMissingParents: true when the file's head is
    ///   loaded, so a missing parent is a line that could not be read (an
    ///   oversized or torn line) rather than one an older page will bring.
    ///   The walk then continues from the newest terminal before the gap, as
    ///   at a compaction, instead of losing everything above it.
    static func resolve(
        _ index: ClaudeTranscriptIndex, role: ClaudeTranscriptReducer.Role, bridgesMissingParents: Bool
    ) -> ClaudeChain {
        let ordered = index.recordsByPosition
        guard !ordered.isEmpty else { return ClaudeChain() }
        let records = index.records
        var rank: [String: Int] = [:]
        for (position, record) in ordered.enumerated() {
            rank[record.uuid] = position
        }
        var parents: [String: String] = [:]
        for record in ordered {
            if let parent = record.parentUUID { parents[record.uuid] = parent }
        }
        relinkCompactions(ordered, records: records, parents: &parents)

        func isEligible(_ record: ClaudeRecord) -> Bool {
            switch record.kind {
            case .progress, .unknown, .attachment("fork_briefing"): return false
            default: break
            }
            return role == .subagent || (!record.isSidechain && record.teamName == nil)
        }
        var parentsOfEligible: Set<String> = []
        for record in ordered where isEligible(record) {
            if let parent = parents[record.uuid] { parentsOfEligible.insert(parent) }
        }
        // Eligible records without an eligible child, newest first.
        let terminals = ordered.reversed().filter { isEligible($0) && !parentsOfEligible.contains($0.uuid) }

        /// Walks up from `start` to the first user or assistant record that
        /// neither `excluded` nor an earlier failed walk (`claimed`) holds.
        func firstMessage(
            above start: ClaudeRecord, excluded: Set<String>, claimed: inout Set<String>
        ) -> ClaudeRecord? {
            var walked: [String] = []
            var visited: Set<String> = []
            var current: ClaudeRecord? = start
            while let record = current, !claimed.contains(record.uuid), !excluded.contains(record.uuid),
                visited.insert(record.uuid).inserted
            {
                if record.isUserOrAssistant { return record }
                walked.append(record.uuid)
                current = parents[record.uuid].flatMap { records[$0] }
            }
            claimed.formUnion(walked)
            return nil
        }

        var chain = ClaudeChain(parents: parents)
        var claimed: Set<String> = []
        var terminal: ClaudeRecord?
        for candidate in terminals {
            if let leaf = firstMessage(above: candidate, excluded: [], claimed: &claimed) {
                chain.leafUUID = leaf.uuid
                terminal = candidate
                break
            }
        }
        if terminal == nil, let leaf = fallbackLeaf(ordered, records: records, parents: parents, rank: rank, role: role) {
            chain.leafUUID = leaf.uuid
            terminal = leaf
        }
        guard let terminal else { return chain }
        chain.terminalUUID = terminal.uuid

        var selected: Set<String> = []
        /// The terminal of the segment written before `record`.
        func segmentTerminal(before record: ClaudeRecord) -> ClaudeRecord? {
            guard let limit = rank[record.uuid] else { return nil }
            var claimed: Set<String> = []
            for candidate in terminals where (rank[candidate.uuid] ?? Int.max) < limit && !selected.contains(candidate.uuid) {
                if firstMessage(above: candidate, excluded: selected, claimed: &claimed) != nil {
                    return candidate
                }
            }
            return nil
        }
        var segmentStart: ClaudeRecord? = terminal
        while let start = segmentStart {
            segmentStart = nil
            var current = start
            // The walk stops at a selected record, which also guards cycles.
            while selected.insert(current.uuid).inserted {
                guard let parentID = parents[current.uuid] else {
                    if current.isCompactBoundary {
                        segmentStart = segmentTerminal(before: current)
                    }
                    break
                }
                guard let parent = records[parentID] else {
                    if chain.missingParent == nil { chain.missingParent = parentID }
                    if bridgesMissingParents {
                        segmentStart = segmentTerminal(before: current)
                    }
                    break
                }
                current = parent
            }
        }
        let walked = selected
        recoverSiblings(ordered, records: records, walked: walked, selected: &selected)
        dropDuplicateBlocks(ordered, walked: walked, selected: &selected)
        dropRetractedMessages(ordered, selected: &selected)
        chain.records = ordered.filter { selected.contains($0.uuid) }
        return chain
    }

    /// Splices preserved messages back under the compaction summary (SDK
    /// `Eu`), so the walk from after a compaction runs through them. When the
    /// listed uuids are not all present, the segment form is used instead,
    /// and only when its three records are.
    private static func relinkCompactions(
        _ ordered: [ClaudeRecord], records: [String: ClaudeRecord], parents: inout [String: String]
    ) {
        var children: [String: Set<String>] = [:]
        for (child, parent) in parents {
            children[parent, default: []].insert(child)
        }
        func reparent(_ child: String, to parent: String) {
            if let old = parents[child] { children[old]?.remove(child) }
            parents[child] = parent
            children[parent, default: []].insert(child)
        }
        for boundary in ordered where boundary.isCompactBoundary {
            guard let compaction = boundary.system?.compaction else { continue }
            if let preserved = compaction.preservedMessages, let first = preserved.uuids.first,
                let last = preserved.uuids.last, records[preserved.anchorUUID] != nil,
                !preserved.uuids.contains(preserved.anchorUUID),
                preserved.uuids.allSatisfy({ records[$0] != nil })
            {
                var previous = preserved.anchorUUID
                for uuid in preserved.uuids {
                    reparent(uuid, to: previous)
                    previous = uuid
                }
                for child in children[preserved.anchorUUID] ?? [] where child != first {
                    reparent(child, to: last)
                }
            } else if let segment = compaction.preservedSegment, records[segment.headUUID] != nil,
                records[segment.anchorUUID] != nil, records[segment.tailUUID] != nil,
                segment.headUUID != segment.anchorUUID
            {
                reparent(segment.headUUID, to: segment.anchorUUID)
                for child in children[segment.anchorUUID] ?? [] where child != segment.headUUID {
                    reparent(child, to: segment.tailUUID)
                }
            }
        }
    }

    /// The SDK fallback when no eligible terminal leads to a message: the
    /// newest user or assistant record above any childless record,
    /// preferring ones that are not meta.
    private static func fallbackLeaf(
        _ ordered: [ClaudeRecord], records: [String: ClaudeRecord], parents: [String: String],
        rank: [String: Int], role: ClaudeTranscriptReducer.Role
    ) -> ClaudeRecord? {
        let parentIDs = Set(parents.values)
        var hits: [ClaudeRecord] = []
        for record in ordered where !parentIDs.contains(record.uuid) {
            var visited: Set<String> = []
            var current: ClaudeRecord? = record
            while let candidate = current, visited.insert(candidate.uuid).inserted {
                if candidate.isUserOrAssistant {
                    hits.append(candidate)
                    break
                }
                current = parents[candidate.uuid].flatMap { records[$0] }
            }
        }
        let preferred = hits.filter {
            !$0.isMeta && (role == .subagent || (!$0.isSidechain && $0.teamName == nil))
        }
        return (preferred.isEmpty ? hits : preferred).max { (rank[$0.uuid] ?? -1) < (rank[$1.uuid] ?? -1) }
    }

    /// Adds records the walk leaves out but that belong to the selected
    /// messages (SDK `cCe`): the other blocks of a selected API message, the
    /// blocks of a message an interrupt marker names, and the result of any
    /// selected call the walk did not pass. Parallel calls produce the last:
    /// each call's result hangs off its own block and dead-ends.
    private static func recoverSiblings(
        _ ordered: [ClaudeRecord], records: [String: ClaudeRecord], walked: Set<String>,
        selected: inout Set<String>
    ) {
        func sameScope(_ lhs: ClaudeRecord, _ rhs: ClaudeRecord) -> Bool {
            lhs.isSidechain == rhs.isSidechain && lhs.agentID == rhs.agentID
        }
        var groups: [String: [ClaudeRecord]] = [:]
        var results: [String: [ClaudeRecord]] = [:]
        for record in ordered {
            if record.kind == .assistant, let messageID = record.messageID {
                groups[messageID, default: []].append(record)
            }
            for result in record.toolResults {
                results[result.toolUseID, default: []].append(record)
            }
        }
        var seeds: [(messageID: String, scope: ClaudeRecord)] = []
        for record in ordered where walked.contains(record.uuid) {
            if record.kind == .assistant, let messageID = record.messageID {
                seeds.append((messageID, record))
            }
            if let interrupted = record.interruptedMessageID {
                seeds.append((interrupted, record))
            }
        }
        for seed in seeds {
            for sibling in groups[seed.messageID] ?? [] where sameScope(sibling, seed.scope) {
                selected.insert(sibling.uuid)
            }
        }
        var answered: Set<String> = []
        for record in ordered where selected.contains(record.uuid) {
            answered.formUnion(record.toolResults.map(\.toolUseID))
        }
        for record in ordered where selected.contains(record.uuid) {
            for use in record.toolUses where !answered.contains(use.id) {
                guard
                    let result = results[use.id]?.last(where: {
                        !selected.contains($0.uuid) && sameScope($0, record)
                    })
                else { continue }
                selected.insert(result.uuid)
                answered.insert(use.id)
            }
        }
    }

    /// Keeps one record per `(message.id, apiBlockIndex)`: the walked one,
    /// else the newest.
    private static func dropDuplicateBlocks(
        _ ordered: [ClaudeRecord], walked: Set<String>, selected: inout Set<String>
    ) {
        struct BlockKey: Hashable {
            var messageID: String
            var index: Int
        }
        var keep: [BlockKey: ClaudeRecord] = [:]
        var duplicated: Set<BlockKey> = []
        for record in ordered where selected.contains(record.uuid) {
            guard let messageID = record.messageID, let index = record.apiBlockIndex else { continue }
            let key = BlockKey(messageID: messageID, index: index)
            guard let kept = keep[key] else {
                keep[key] = record
                continue
            }
            duplicated.insert(key)
            // `ordered` runs oldest first: a later record wins unless only the
            // kept one was walked.
            if walked.contains(record.uuid) || !walked.contains(kept.uuid) {
                keep[key] = record
            }
        }
        guard !duplicated.isEmpty else { return }
        for record in ordered where selected.contains(record.uuid) {
            guard let messageID = record.messageID, let index = record.apiBlockIndex else { continue }
            let key = BlockKey(messageID: messageID, index: index)
            if duplicated.contains(key), keep[key]?.uuid != record.uuid {
                selected.remove(record.uuid)
            }
        }
    }

    /// Hides messages a model refusal fallback retracted, when the file
    /// still holds them.
    private static func dropRetractedMessages(_ ordered: [ClaudeRecord], selected: inout Set<String>) {
        for record in ordered where selected.contains(record.uuid) {
            for uuid in record.system?.retractedMessageUUIDs ?? [] {
                selected.remove(uuid)
            }
        }
    }
}
