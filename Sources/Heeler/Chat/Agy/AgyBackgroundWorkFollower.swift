import Foundation

/// Follows SFTP side files of an Antigravity CLI conversation's running
/// Background Work (`agy:task:*` task logs and `agy:subagent:*` transcripts)
/// so active long-running work keeps fresh `lastSeenAt` timestamps and
/// subagents whose parent turn was interrupted settle once their own
/// transcript finishes.
struct AgyBackgroundWorkFollower: Sendable {
    struct Limits: Sendable, Equatable {
        var subagentFollower = WorkflowJournalFollower.Limits(
            lineCap: 256 << 10, prefixCap: 16 << 10, maximumBytes: 16 << 20)
        var subagentBudget = 128 << 10
        var callBudget = 256 << 10
        var subagentsPerCall = 2
        var taskLogsPerCall = 4
        /// How long a subagent's own transcript stays idle after its final
        /// reply before standing in for a missing parent `SYSTEM_MESSAGE`.
        var subagentIdleSettle: TimeInterval = 5
        var unchangedSideFileInterval: TimeInterval = 2
        var backoff: [TimeInterval] = [2, 4, 8, 16, 30]
    }

    private struct FollowedTaskLog: Sendable {
        let path: String
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        var isUnreadable = false
        var previousStat: (size: UInt64?, modificationTime: UInt32?)?
        var lastSeenAt: Date?
    }

    private struct FollowedSubagent: Sendable {
        var follower: WorkflowJournalFollower
        var state = AgySubagentState()
        var lastLook = 0
        var failures = 0
        var nextLook: Date?
        var isUnreadable = false
        var hasCaughtUpOnce = false
        var lastSeenAt: Date?
        var idleSince: Date?
        var revivalFloorOffset: UInt64 = 0
        var latestObservedParentActivity: Date?
    }

    private var trackedRoot: String?
    private var taskLogs: [String: FollowedTaskLog] = [:]
    private var subagents: [String: FollowedSubagent] = [:]
    private var pollCount = 0
    private var lastPollDate: Date?

    mutating func poll(
        root: String,
        items: [ChatBackgroundWorkItem],
        files: ChatHostFiles,
        limits: Limits,
        at date: Date,
        isCancellation: (any Error) -> Bool
    ) async -> [String: ChatBackgroundWorkEvidence] {
        if trackedRoot != root {
            trackedRoot = root
            taskLogs = [:]
            subagents = [:]
            lastPollDate = nil
        }

        let runningItems = items.filter { $0.state == .running }
        var runningTasks: [String: String] = [:]
        var runningSubagents: [String: (path: String, item: ChatBackgroundWorkItem)] = [:]
        for item in runningItems {
            if let logPath = Self.taskLogPath(forWorkID: item.id, in: root) {
                runningTasks[item.id] = logPath
            } else if let subagentPath = Self.subagentTranscriptPath(forWorkID: item.id, in: root) {
                runningSubagents[item.id] = (subagentPath, item)
            }
        }

        taskLogs = taskLogs.filter { runningTasks[$0.key] == $0.value.path }
        for (id, path) in runningTasks where taskLogs[id] == nil {
            taskLogs[id] = FollowedTaskLog(path: path)
        }

        subagents = subagents.filter { runningSubagents[$0.key]?.path == $0.value.follower.path }
        for (id, entry) in runningSubagents {
            let parentActivity = [entry.item.launchedAt, entry.item.lastActivityAt].compactMap(\.self).max()
            if var existing = subagents[id] {
                if let parentActivity,
                    existing.latestObservedParentActivity.map({ parentActivity > $0 }) ?? true,
                    existing.idleSince != nil,
                    parentActivity > (existing.state.latestStepAt ?? .distantPast)
                {
                    // The parent revived or re-confirmed the subagent after an
                    // earlier idle spell: wait for new steps past this offset.
                    existing.revivalFloorOffset = existing.follower.readOffset
                    existing.idleSince = nil
                }
                existing.latestObservedParentActivity = parentActivity
                subagents[id] = existing
            } else {
                subagents[id] = FollowedSubagent(
                    follower: WorkflowJournalFollower(path: entry.path, limits: limits.subagentFollower),
                    latestObservedParentActivity: parentActivity)
            }
        }

        let clockAdvanced = lastPollDate.map { date > $0 } ?? false
        lastPollDate = date
        pollCount += 1

        let dueTaskLogs = taskLogs
            .filter { !$0.value.isUnreadable && ($0.value.nextLook.map { date >= $0 } ?? true) }
            .sorted { ($0.value.lastLook, $0.key) < ($1.value.lastLook, $1.key) }
            .prefix(limits.taskLogsPerCall)

        for (id, var followed) in dueTaskLogs {
            followed.lastLook = pollCount
            do {
                if let status = try await files.status(followed.path) {
                    followed.failures = 0
                    let hadPreviousStat = followed.previousStat != nil
                    let mtimeDate = status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    let grew =
                        followed.previousStat.map {
                            status.size != $0.size || status.modificationTime != $0.modificationTime
                        } ?? false
                    followed.previousStat = (status.size, status.modificationTime)
                    if hadPreviousStat, !grew, clockAdvanced {
                        followed.nextLook = date.addingTimeInterval(limits.unchangedSideFileInterval)
                    } else {
                        followed.nextLook = nil
                    }
                    followed.lastSeenAt =
                        [followed.lastSeenAt, mtimeDate, grew ? date : nil].compactMap(\.self).max()
                } else {
                    Self.backOff(
                        failures: &followed.failures, nextLook: &followed.nextLook, delays: limits.backoff, at: date)
                }
            } catch {
                if isCancellation(error) { return snapshotEvidence(at: date, limits: limits) }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    Self.backOff(
                        failures: &followed.failures, nextLook: &followed.nextLook, delays: limits.backoff, at: date)
                }
            }
            taskLogs[id] = followed
        }

        let dueSubagents = subagents
            .filter { !$0.value.isUnreadable && ($0.value.nextLook.map { date >= $0 } ?? true) }
            .sorted { ($0.value.lastLook, $0.key) < ($1.value.lastLook, $1.key) }
            .prefix(limits.subagentsPerCall)

        var budget = limits.callBudget
        for (id, var followed) in dueSubagents where budget > 0 {
            followed.lastLook = pollCount
            var follower = followed.follower
            let before = follower.readOffset
            do {
                let change = try await follower.poll(files, budget: min(budget, limits.subagentBudget))
                budget -= Int(follower.readOffset >= before ? follower.readOffset - before : follower.readOffset)
                followed.follower = follower
                var changed = false
                switch change {
                case .unchanged:
                    break
                case .appended(let lines):
                    followed.state.apply(lines)
                    changed = true
                case .restarted(let lines):
                    followed.state = AgySubagentState()
                    followed.state.apply(lines)
                    followed.revivalFloorOffset = 0
                    followed.idleSince = nil
                    changed = true
                case .missing:
                    Self.backOff(
                        failures: &followed.failures, nextLook: &followed.nextLook, delays: limits.backoff, at: date)
                    subagents[id] = followed
                    continue
                case .tooLarge:
                    followed.isUnreadable = true
                }
                followed.failures = 0
                if !changed, followed.hasCaughtUpOnce, clockAdvanced, followed.idleSince == nil {
                    followed.nextLook = date.addingTimeInterval(limits.unchangedSideFileInterval)
                } else {
                    followed.nextLook = nil
                }
                let mtimeDate = follower.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let grewAfterCatchUp = followed.hasCaughtUpOnce && changed
                followed.lastSeenAt = [
                    followed.lastSeenAt, followed.state.latestStepAt, mtimeDate, grewAfterCatchUp ? date : nil,
                ].compactMap(\.self).max()
                if follower.isCaughtUp {
                    followed.hasCaughtUpOnce = true
                    let postdatesParent =
                        followed.latestObservedParentActivity.map { start in
                            (followed.state.latestStepAt ?? .distantPast) >= start
                        } ?? true
                    let readyForIdle =
                        followed.revivalFloorOffset == 0
                        ? postdatesParent
                        : follower.readOffset > followed.revivalFloorOffset
                    if followed.state.isIdle, readyForIdle {
                        if followed.idleSince == nil {
                            // Measure settle time on the polling clock (`date`),
                            // never on the step's `created_at`, so a subagent that
                            // wrote its final step 6 s ago and is about to deliver
                            // its parent `SYSTEM_MESSAGE` still gets the full
                            // settle window before standing in.
                            followed.idleSince = date
                        }
                    } else {
                        followed.idleSince = nil
                    }
                }
            } catch {
                if isCancellation(error) { return snapshotEvidence(at: date, limits: limits) }
                if case .hostFileUnreadable? = error as? TransportError {
                    followed.isUnreadable = true
                } else {
                    Self.backOff(
                        failures: &followed.failures, nextLook: &followed.nextLook, delays: limits.backoff, at: date)
                }
            }
            subagents[id] = followed
        }

        return snapshotEvidence(at: date, limits: limits)
    }

    func snapshotEvidence(at date: Date, limits: Limits) -> [String: ChatBackgroundWorkEvidence] {
        var result: [String: ChatBackgroundWorkEvidence] = [:]
        for (id, followed) in taskLogs {
            guard let lastSeenAt = followed.lastSeenAt else { continue }
            result[id] = ChatBackgroundWorkEvidence(lastSeenAt: lastSeenAt)
        }
        for (id, followed) in subagents {
            if let idleSince = followed.idleSince,
                date.timeIntervalSince(idleSince) >= limits.subagentIdleSettle
            {
                let endedAt = [followed.state.latestStepAt, followed.latestObservedParentActivity]
                    .compactMap(\.self).max() ?? idleSince
                result[id] = ChatBackgroundWorkEvidence(
                    lastSeenAt: followed.lastSeenAt, endedState: .completed, endedAt: endedAt)
            } else if let lastSeenAt = followed.lastSeenAt {
                result[id] = ChatBackgroundWorkEvidence(lastSeenAt: lastSeenAt)
            }
        }
        return result
    }

    static func taskLogPath(forWorkID workID: String, in root: String) -> String? {
        let prefix = "agy:task:"
        guard workID.hasPrefix(prefix) else { return nil }
        let taskID = String(workID.dropFirst(prefix.count))
        guard let slash = taskID.firstIndex(of: "/") else { return nil }
        let rawConv = String(taskID[..<slash])
        let taskName = String(taskID[taskID.index(after: slash)...])
        guard let convID = ConversationReference.canonicalUUID(rawConv),
            taskName.wholeMatch(of: #/task-\d+/#) != nil
        else { return nil }
        let path = RemoteFilePath.join(
            AgyTranscriptLocator.folder(in: root, id: convID), ".system_generated", "tasks", "\(taskName).log")
        return RemoteFilePath.isAcceptable(path) ? path : nil
    }

    static func subagentTranscriptPath(forWorkID workID: String, in root: String) -> String? {
        let prefix = "agy:subagent:"
        guard workID.hasPrefix(prefix) else { return nil }
        let rawID = String(workID.dropFirst(prefix.count))
        guard let subagentID = ConversationReference.canonicalUUID(rawID) else { return nil }
        let path = AgyTranscriptLocator.transcriptPath(
            inFolder: AgyTranscriptLocator.folder(in: root, id: subagentID))
        return RemoteFilePath.isAcceptable(path) ? path : nil
    }

    private static func backOff(
        failures: inout Int, nextLook: inout Date?, delays: [TimeInterval], at date: Date
    ) {
        let delay = delays.isEmpty ? 0 : delays[min(failures, delays.count - 1)]
        failures += 1
        nextLook = date.addingTimeInterval(delay)
    }
}

/// Minimal state of a subagent's own `transcript_full.jsonl` needed to tell
/// when it last stepped and whether its current turn has finished with no
/// child tasks or subagents left running.
struct AgySubagentState: Sendable {
    private struct ActiveSchedule: Sendable {
        let isCron: Bool
        let maxIterations: Int?
        let timerCondition: String?
        var firedCount = 0
    }

    private var seenSteps: Set<Int> = []
    private(set) var hasPlannerResponse = false
    private(set) var hasReply = false
    private var isCompact = false
    private var pendingCalls: [AgyStep.Call] = []
    private(set) var runningTasks: Set<String> = []
    private var runningSchedules: [String: ActiveSchedule] = [:]
    private var spawnedSubagents: Set<String> = []
    private(set) var runningSubagents: Set<String> = []
    private(set) var latestStepAt: Date?

    var isIdle: Bool {
        hasPlannerResponse && hasReply && pendingCalls.isEmpty && runningTasks.isEmpty
            && runningSchedules.isEmpty && runningSubagents.isEmpty
    }

    mutating func apply(_ lines: [ChatLine]) {
        for line in lines {
            guard let step = AgyStep.decode(line) else { continue }
            if let index = step.stepIndex, !seenSteps.insert(index).inserted { continue }
            latestStepAt = [latestStepAt, step.createdAt, step.systemMessage?.timestamp].compactMap(\.self).max()
            switch step.kind {
            case .userInput:
                pendingCalls.removeAll()
                hasReply = false
                isCompact = step.request?.text == "/compact"
            case .plannerResponse:
                hasPlannerResponse = true
                pendingCalls = step.calls
                isCompact = false
                hasReply = !step.isTruncated && step.calls.isEmpty
            case .toolResult:
                readResult(step)
            case .systemMessage:
                readSystemMessage(step)
            case .checkpoint:
                if isCompact { hasReply = true }
            case .errorMessage:
                hasReply = false
            case .ephemeral, .unknown:
                break
            }
        }
    }

    private mutating func readResult(_ step: AgyStep) {
        guard !pendingCalls.isEmpty else { return }
        let call = pendingCalls.removeFirst()
        if step.status == .running {
            guard call.args?["IsDaemon"] != .bool(true),
                let taskID = AgyTranscriptReducer.backgroundTaskID(in: step.resultBody)
            else { return }
            if call.name == "schedule" {
                let isCron = call.args?["CronExpression"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } != nil
                let maxIterations: Int? =
                    if case .number(let n)? = call.args?["MaxIterations"], let int = Int(exactly: n), int > 0 {
                        int
                    } else {
                        nil
                    }
                let condition = call.args?["TimerCondition"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                runningSchedules[taskID] = ActiveSchedule(
                    isCron: isCron, maxIterations: maxIterations, timerCondition: condition)
            } else {
                runningTasks.insert(taskID)
            }
            return
        }
        guard step.status == .done else { return }
        switch call.name {
        case "invoke_subagent":
            if let subID = AgyTranscriptReducer.launchedSubagentID(in: step.resultBody) {
                spawnedSubagents.insert(subID)
                runningSubagents.insert(subID)
            }
        case "send_message":
            if let recipient = call.args?["Recipient"]?.stringValue, spawnedSubagents.contains(recipient) {
                runningSubagents.insert(recipient)
            }
        case "manage_subagents":
            switch call.args?["Action"]?.stringValue {
            case "kill":
                if case .array(let ids)? = call.args?["ConversationIds"] {
                    for id in ids.compactMap(\.stringValue) { runningSubagents.remove(id) }
                }
            case "kill_all":
                runningSubagents.removeAll()
            case "list":
                for entry in AgyTranscriptReducer.jsonArray(in: step.resultBody) {
                    guard let id = entry["conversationId"]?.stringValue, !id.isEmpty else { continue }
                    spawnedSubagents.insert(id)
                    switch entry["state"]?.stringValue {
                    case "running", "waiting_for_dependents":
                        runningSubagents.insert(id)
                    case "idle", "errored":
                        runningSubagents.remove(id)
                    default:
                        break
                    }
                }
            default:
                break
            }
        case "manage_task":
            if call.args?["Action"]?.stringValue == "kill",
                let taskID = call.args?["TaskId"]?.stringValue, !taskID.isEmpty
            {
                runningTasks.remove(taskID)
                runningSchedules.removeValue(forKey: taskID)
            }
        default:
            break
        }
    }

    private mutating func readSystemMessage(_ step: AgyStep) {
        if let end = AgyTranscriptReducer.taskEnd(in: step) {
            runningTasks.remove(end.taskID)
            runningSchedules.removeValue(forKey: end.taskID)
            cancelTimers(triggeredBy: [end.taskID, step.systemMessage?.sender].compactMap(\.self), excluding: end.taskID)
            hasReply = false
            isCompact = false
            return
        }
        if let error = AgyTranscriptReducer.subagentError(in: step) {
            runningSubagents.remove(error.subagentID)
            cancelTimers(triggeredBy: [error.subagentID, step.systemMessage?.sender].compactMap(\.self))
            hasReply = false
            isCompact = false
            return
        }
        if let text = step.systemMessageText, text.hasPrefix(AgyTranscriptReducer.restartNotice) {
            runningTasks.removeAll()
            runningSchedules.removeAll()
            runningSubagents.removeAll()
            return
        }
        if let sender = step.systemMessage?.sender {
            cancelTimers(triggeredBy: [sender], excluding: sender)
            if var active = runningSchedules[sender] {
                if active.isCron {
                    active.firedCount += 1
                    if let maxIterations = active.maxIterations, active.firedCount >= maxIterations {
                        runningSchedules.removeValue(forKey: sender)
                    } else {
                        runningSchedules[sender] = active
                    }
                } else {
                    runningSchedules.removeValue(forKey: sender)
                }
            }
            if spawnedSubagents.contains(sender) {
                runningSubagents.remove(sender)
            }
            hasReply = false
            isCompact = false
        }
    }

    private mutating func cancelTimers(triggeredBy senders: [String], excluding selfTaskID: String? = nil) {
        guard !runningSchedules.isEmpty, !senders.isEmpty else { return }
        let senderSet = Set(senders)
        for (taskID, active) in runningSchedules {
            guard !active.isCron, taskID != selfTaskID,
                let condition = active.timerCondition, condition != "never"
            else { continue }
            if condition == "any" || senderSet.contains(condition) {
                runningSchedules.removeValue(forKey: taskID)
            }
        }
    }
}
