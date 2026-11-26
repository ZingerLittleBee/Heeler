import Foundation

/// Follows SFTP side files of an Antigravity CLI native Swarm
/// (`brain/<id>/.system_generated/swarm/members.json`, `board.jsonl`,
/// optional `view.json`, and each member's compact `transcript.jsonl`)
/// within bounded per-poll byte budgets.
struct AgySwarmFollower: Sendable {
    struct Limits: Sendable, Equatable {
        var boardFollower = WorkflowJournalFollower.Limits(
            lineCap: 64 << 10, prefixCap: 8 << 10, maximumBytes: 8 << 20)
        var memberFollower = WorkflowJournalFollower.Limits(
            lineCap: 256 << 10, prefixCap: 16 << 10, maximumBytes: 16 << 20)
        var rosterMaxBytes = 256 << 10
        var boardBudget = 256 << 10
        var memberBudget = 128 << 10
        var memberCallBudget = 256 << 10
        var membersPerCall = 4
        var unhintedRosterCheckInterval: TimeInterval = 30
        var hintedMissingInterval: TimeInterval = 1
        var unchangedSideFileInterval: TimeInterval = 2
        var viewCheckInterval: TimeInterval = 3
        var backoff: [TimeInterval] = [2, 4, 8, 16, 30]
    }

    private struct StatFingerprint: Equatable, Sendable {
        var path: String
        var size: UInt64?
        var modificationTime: UInt32?
    }

    private struct FollowedMember: Sendable {
        let conversationID: String
        var follower: WorkflowJournalFollower
        var transcript = AgySwarmMemberTranscript()
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        var isUnreadable = false
        var hasCaughtUpOnce = false
    }

    private var trackedRoot: String?
    private var trackedCoordinatorID: String?
    private var roster: AgySwarmParser.RawRoster?
    private var settledRosterStat: StatFingerprint?
    private var rosterFailures = 0
    private var nextRosterLook: Date?
    private var sawSwarmHint = false
    private var boardFollower: WorkflowJournalFollower?
    private var rawBoardLines: [AgySwarmParser.RawBoardLine] = []
    private var boardGeneration = 0
    private var compiledBoard: AgySwarmParser.CompiledBoardHistory?
    private var compiledBoardGeneration = -1
    private var compiledLineCount = -1
    private var compiledRosterNames: [String] = []
    private var boardRevision = 0
    private var boardFailures = 0
    private var nextBoardLook: Date?
    private var boardIsUnreadable = false
    private var overview: AgySwarmSnapshot.NarratorOverview?
    private var settledViewStat: StatFingerprint?
    private var nextViewLook: Date?
    private var members: [String: FollowedMember] = [:]
    private var pollCount = 0
    private var lastPollDate: Date?

    mutating func reset() {
        trackedRoot = nil
        trackedCoordinatorID = nil
        roster = nil
        settledRosterStat = nil
        rosterFailures = 0
        nextRosterLook = nil
        sawSwarmHint = false
        boardFollower = nil
        rawBoardLines = []
        boardGeneration = 0
        compiledBoard = nil
        compiledBoardGeneration = -1
        compiledLineCount = -1
        compiledRosterNames = []
        boardRevision = 0
        boardFailures = 0
        nextBoardLook = nil
        boardIsUnreadable = false
        overview = nil
        settledViewStat = nil
        nextViewLook = nil
        members = [:]
        pollCount = 0
        lastPollDate = nil
    }

    mutating func poll(
        root: String,
        coordinatorID rawCoordinatorID: String,
        hasSwarmHint: Bool,
        files: ChatHostFiles,
        limits: Limits = Limits(),
        at date: Date,
        isCancellation: (any Error) -> Bool
    ) async -> AgySwarmSnapshot? {
        guard let coordinatorID = ConversationReference.canonicalUUID(rawCoordinatorID) else {
            reset()
            return nil
        }
        if trackedRoot != root || trackedCoordinatorID != coordinatorID {
            reset()
            trackedRoot = root
            trackedCoordinatorID = coordinatorID
        }
        if hasSwarmHint, !sawSwarmHint {
            sawSwarmHint = true
            if roster == nil, rosterFailures == 0 {
                nextRosterLook = nil
            }
        }

        guard let swarmDir = Self.swarmDirectory(in: root, coordinatorID: coordinatorID) else {
            return snapshot(isLive: true, at: date)
        }
        let membersPath = RemoteFilePath.join(swarmDir, "members.json")
        guard RemoteFilePath.isAcceptable(membersPath) else {
            return snapshot(isLive: true, at: date)
        }

        let clockAdvanced = lastPollDate.map { date > $0 } ?? false
        lastPollDate = date
        pollCount += 1

        // 1. Read or refresh `members.json`.
        if nextRosterLook.map({ date >= $0 }) ?? true {
            let ok = await pollRoster(
                atPath: membersPath, hasSwarmHint: sawSwarmHint, clockAdvanced: clockAdvanced,
                files: files, limits: limits, at: date,
                isCancellation: isCancellation)
            if !ok { return snapshot(isLive: true, at: date) }
        }

        guard let roster else { return nil }

        // 2. Follow `board.jsonl`.
        let boardPath = RemoteFilePath.join(swarmDir, "board.jsonl")
        if RemoteFilePath.isAcceptable(boardPath), !boardIsUnreadable,
            nextBoardLook.map({ date >= $0 }) ?? true
        {
            if boardFollower?.path != boardPath {
                boardFollower = WorkflowJournalFollower(path: boardPath, limits: limits.boardFollower)
                rawBoardLines = []
                boardGeneration &+= 1
            }
            if var follower = boardFollower {
                do {
                    let change = try await follower.poll(files, budget: limits.boardBudget)
                    boardFollower = follower
                    switch change {
                    case .unchanged, .missing:
                        boardFailures = 0
                        nextBoardLook = nil
                    case .appended(let lines):
                        rawBoardLines.append(contentsOf: lines.compactMap(AgySwarmParser.parseBoardLine))
                        boardFailures = 0
                        nextBoardLook = nil
                    case .restarted(let lines):
                        rawBoardLines = lines.compactMap(AgySwarmParser.parseBoardLine)
                        boardGeneration &+= 1
                        boardFailures = 0
                        nextBoardLook = nil
                    case .tooLarge:
                        boardIsUnreadable = true
                    }
                } catch {
                    if isCancellation(error) { return snapshot(isLive: true, at: date) }
                    if case .hostFileUnreadable? = error as? TransportError {
                        boardIsUnreadable = true
                    } else {
                        Self.backOff(
                            failures: &boardFailures, nextLook: &nextBoardLook, delays: limits.backoff, at: date)
                    }
                }
            }
        }

        // 3. Reconcile and round-robin member compact transcripts.
        syncMemberFollowers(roster: roster, in: root, limits: limits)
        let dueMembers = members
            .filter { name, followed in
                guard !followed.isUnreadable, followed.nextLook.map({ date >= $0 }) ?? true else { return false }
                let isKilled = roster.members[name]?.isKilled == true
                return !isKilled || !followed.hasCaughtUpOnce
            }
            .sorted { lhs, rhs in
                let lhsRole = AgySwarmParser.isRoleWorkerName(lhs.key) ? 1 : 0
                let rhsRole = AgySwarmParser.isRoleWorkerName(rhs.key) ? 1 : 0
                if lhs.value.lastLook != rhs.value.lastLook {
                    return lhs.value.lastLook < rhs.value.lastLook
                }
                if lhsRole != rhsRole { return lhsRole < rhsRole }
                return lhs.key < rhs.key
            }
            .prefix(limits.membersPerCall)

        var budget = limits.memberCallBudget
        for (name, var followed) in dueMembers where budget > 0 {
            followed.lastLook = pollCount
            var follower = followed.follower
            let before = follower.readOffset
            do {
                let change = try await follower.poll(files, budget: min(budget, limits.memberBudget))
                budget -= Int(follower.readOffset >= before ? follower.readOffset - before : follower.readOffset)
                followed.follower = follower
                var wasUnchanged = false
                switch change {
                case .unchanged:
                    wasUnchanged = true
                case .appended(let lines):
                    followed.transcript.apply(lines)
                case .restarted(let lines):
                    followed.transcript = AgySwarmMemberTranscript()
                    followed.transcript.apply(lines)
                case .missing:
                    Self.backOff(
                        failures: &followed.failures, nextLook: &followed.nextLook, delays: limits.backoff, at: date)
                    members[name] = followed
                    continue
                case .tooLarge:
                    followed.isUnreadable = true
                }
                followed.failures = 0
                if wasUnchanged, followed.hasCaughtUpOnce, clockAdvanced {
                    followed.nextLook = date.addingTimeInterval(limits.unchangedSideFileInterval)
                } else {
                    followed.nextLook = nil
                }
                followed.transcript.modificationDate = follower.modificationTime.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                if follower.isCaughtUp {
                    followed.hasCaughtUpOnce = true
                }
            } catch {
                if isCancellation(error) { return snapshot(isLive: true, at: date) }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    Self.backOff(
                        failures: &followed.failures, nextLook: &followed.nextLook, delays: limits.backoff, at: date)
                }
            }
            members[name] = followed
        }

        // 4. Optional Narrator Overview (`view.json`).
        if nextViewLook.map({ date >= $0 }) ?? true {
            await pollOverview(
                swarmDir: swarmDir, root: root, roster: roster, files: files, limits: limits, at: date,
                isCancellation: isCancellation)
        }

        refreshCompiledBoard(roster: roster)
        return snapshot(isLive: true, at: date)
    }

    private mutating func refreshCompiledBoard(roster: AgySwarmParser.RawRoster) {
        let sortedNames = roster.members.keys.sorted()
        if let existing = compiledBoard,
            compiledBoardGeneration == boardGeneration,
            compiledRosterNames == sortedNames
        {
            if compiledLineCount == rawBoardLines.count {
                return
            }
            if compiledLineCount < rawBoardLines.count {
                let appendedSlice = rawBoardLines[compiledLineCount..<rawBoardLines.count]
                let hasControlOp = appendedSlice.contains { $0.control != nil }
                if !hasControlOp {
                    var updated = existing
                    var lastSeq = updated.boardPosts.last?.seq ?? Int.min
                    for idx in compiledLineCount..<rawBoardLines.count {
                        let msg = AgySwarmParser.buildBoardMessage(
                            from: rawBoardLines[idx],
                            at: idx,
                            rosterNames: sortedNames,
                            activeChannelNames: updated.activeChannelNames,
                            postCounts: &updated.postCounts)
                        updated.messages.append(msg)
                        if !msg.isControl {
                            if msg.seq <= lastSeq {
                                updated.postsAreMonotonic = false
                            }
                            lastSeq = msg.seq
                            updated.boardPosts.append(msg)
                            updated.knownPostSeqs.insert(msg.seq)
                        }
                    }
                    compiledBoard = updated
                    compiledLineCount = rawBoardLines.count
                    boardRevision &+= 1
                    return
                }
            }
        }
        compiledBoard = AgySwarmParser.compileBoardHistory(rawLines: rawBoardLines, rosterNames: sortedNames)
        compiledBoardGeneration = boardGeneration
        compiledLineCount = rawBoardLines.count
        compiledRosterNames = sortedNames
        boardRevision &+= 1
    }

    func snapshot(isLive: Bool, at date: Date) -> AgySwarmSnapshot? {
        guard let roster, let coordinatorID = trackedCoordinatorID else { return nil }
        let transcripts = members.mapValues(\.transcript)
        let sortedNames = roster.members.keys.sorted()
        let history: AgySwarmParser.CompiledBoardHistory
        if let existing = compiledBoard,
            compiledBoardGeneration == boardGeneration,
            compiledLineCount == rawBoardLines.count,
            compiledRosterNames == sortedNames
        {
            history = existing
        } else {
            history = AgySwarmParser.compileBoardHistory(rawLines: rawBoardLines, rosterNames: sortedNames)
        }
        return AgySwarmParser.buildSnapshot(
            id: coordinatorID,
            roster: roster,
            sortedNames: sortedNames,
            compiledBoard: history,
            boardRevision: boardRevision,
            transcripts: transcripts,
            overview: overview,
            isLive: isLive,
            now: date)
    }

    // MARK: - Helpers

    static func swarmDirectory(in root: String, coordinatorID: String) -> String? {
        guard let canonical = ConversationReference.canonicalUUID(coordinatorID) else { return nil }
        let dir = RemoteFilePath.join(AgyTranscriptLocator.folder(in: root, id: canonical), ".system_generated", "swarm")
        return RemoteFilePath.isAcceptable(dir) ? dir : nil
    }

    static func compactTranscriptPath(in root: String, conversationID: String) -> String? {
        guard let canonical = ConversationReference.canonicalUUID(conversationID) else { return nil }
        let path = RemoteFilePath.join(
            AgyTranscriptLocator.folder(in: root, id: canonical), ".system_generated", "logs", "transcript.jsonl")
        return RemoteFilePath.isAcceptable(path) ? path : nil
    }

    private mutating func pollRoster(
        atPath path: String,
        hasSwarmHint: Bool,
        clockAdvanced: Bool,
        files: ChatHostFiles,
        limits: Limits,
        at date: Date,
        isCancellation: (any Error) -> Bool
    ) async -> Bool {
        do {
            guard let status = try await files.status(path) else {
                rosterFailures = 0
                if roster == nil {
                    let delay = hasSwarmHint ? limits.hintedMissingInterval : limits.unhintedRosterCheckInterval
                    nextRosterLook = date.addingTimeInterval(delay)
                } else {
                    nextRosterLook = date.addingTimeInterval(limits.hintedMissingInterval)
                }
                return true
            }
            rosterFailures = 0
            nextRosterLook = nil
            if let size = status.size, size > UInt64(limits.rosterMaxBytes) {
                return true
            }
            let currentStat = StatFingerprint(
                path: path, size: status.size, modificationTime: status.modificationTime)
            if roster != nil, settledRosterStat == currentStat {
                if clockAdvanced {
                    nextRosterLook = date.addingTimeInterval(limits.unchangedSideFileInterval)
                }
                return true
            }
            guard let data = try await files.read(
                path: path, from: 0, to: UInt64(limits.rosterMaxBytes), chunk: 64 << 10)
            else { return true }
            if let parsed = AgySwarmParser.parseRoster(data) {
                roster = parsed
                if Self.isStatSettled(status, at: date) {
                    settledRosterStat = currentStat
                } else {
                    settledRosterStat = nil
                }
            }
            return true
        } catch {
            if isCancellation(error) { return false }
            Self.backOff(
                failures: &rosterFailures, nextLook: &nextRosterLook, delays: limits.backoff, at: date)
            return true
        }
    }

    private mutating func syncMemberFollowers(
        roster: AgySwarmParser.RawRoster, in root: String, limits: Limits
    ) {
        var valid: [String: (convID: String, path: String)] = [:]
        for (name, raw) in roster.members {
            guard let convID = ConversationReference.canonicalUUID(raw.conversationID),
                let path = Self.compactTranscriptPath(in: root, conversationID: convID)
            else { continue }
            valid[name] = (convID, path)
        }
        members = members.filter { name, followed in
            guard let target = valid[name] else { return false }
            return followed.conversationID == target.convID && followed.follower.path == target.path
        }
        for (name, target) in valid where members[name] == nil {
            members[name] = FollowedMember(
                conversationID: target.convID,
                follower: WorkflowJournalFollower(path: target.path, limits: limits.memberFollower))
        }
    }

    private mutating func pollOverview(
        swarmDir: String,
        root: String,
        roster: AgySwarmParser.RawRoster,
        files: ChatHostFiles,
        limits: Limits,
        at date: Date,
        isCancellation: (any Error) -> Bool
    ) async {
        nextViewLook = date.addingTimeInterval(limits.viewCheckInterval)
        var candidatePaths: [String] = []
        let primary = RemoteFilePath.join(swarmDir, "view.json")
        if RemoteFilePath.isAcceptable(primary) {
            candidatePaths.append(primary)
        }
        for (name, raw) in roster.members
        where !raw.isKilled && AgySwarmParser.effectiveRole(name: name, storedRole: raw.role) == "narrator" {
            if let convID = ConversationReference.canonicalUUID(raw.conversationID) {
                let fallback = RemoteFilePath.join(
                    AgyTranscriptLocator.folder(in: root, id: convID), "swarm_view", "view.json")
                if RemoteFilePath.isAcceptable(fallback) {
                    candidatePaths.append(fallback)
                }
            }
        }

        for path in candidatePaths {
            do {
                guard let status = try await files.status(path) else { continue }
                if let size = status.size, size > UInt64(AgySwarmParser.viewMaxBytes) { return }
                let fingerprint = StatFingerprint(
                    path: path, size: status.size, modificationTime: status.modificationTime)
                if overview != nil, settledViewStat == fingerprint { return }
                guard let data = try await files.read(
                    path: path, from: 0, to: UInt64(AgySwarmParser.viewMaxBytes + 1), chunk: 64 << 10)
                else { continue }
                if let parsed = AgySwarmParser.parseOverview(data) {
                    overview = parsed
                    settledViewStat = Self.isStatSettled(status, at: date) ? fingerprint : nil
                }
                return
            } catch {
                if isCancellation(error) { return }
                return
            }
        }
    }

    /// Guards stat-only caching against same-second same-byte-length rewrites on
    /// filesystems reporting whole-second modification times.
    private static func isStatSettled(_ status: RemoteFileStatus, at date: Date) -> Bool {
        guard let mtime = status.modificationTime else { return false }
        let nowSeconds = max(0, Int64(date.timeIntervalSince1970))
        return Int64(mtime) + 2 <= nowSeconds
    }

    private static func backOff(
        failures: inout Int, nextLook: inout Date?, delays: [TimeInterval], at date: Date
    ) {
        let delay = delays.isEmpty ? 0 : delays[min(failures, delays.count - 1)]
        failures += 1
        nextLook = date.addingTimeInterval(delay)
    }
}
