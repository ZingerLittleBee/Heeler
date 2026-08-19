import Foundation

@testable import Heeler

/// ActivityKit stand-in for `HostLiveActivityCoordinator` tests: records
/// request/update/end and lets the test push tokens and run-states.
@MainActor
final class FakeLiveActivityController: LiveActivityControlling {
    var areEnabled = true
    var requestError: (any Error)?

    private(set) var requested: [AgentActivityAttributes.ContentState] = []
    private(set) var requestedHandles: [LiveActivityHandle] = []
    private(set) var updates: [(id: String, content: AgentActivityAttributes.ContentState)] = []
    private(set) var ended: [(id: String, finalContent: AgentActivityAttributes.ContentState?, immediate: Bool)] =
        []

    private var nextID = 1
    private var records: [String: Record] = [:]

    private struct Record {
        var id: String
        var hostID: UUID
        var content: AgentActivityAttributes.ContentState?
        var lastToken: Data?
        var tokenContinuations: [AsyncStream<Data>.Continuation] = []
        var stateContinuations: [AsyncStream<LiveActivityRunState>.Continuation] = []
    }

    func seed(id: String, hostID: UUID) {
        records[id] = Record(id: id, hostID: hostID)
    }

    func emitToken(id: String, _ data: Data) {
        records[id]?.lastToken = data
        for continuation in records[id]?.tokenContinuations ?? [] {
            continuation.yield(data)
        }
    }

    func emitState(id: String, _ state: LiveActivityRunState) {
        for continuation in records[id]?.stateContinuations ?? [] {
            continuation.yield(state)
        }
    }

    func activityID(for hostID: UUID) -> String? {
        records.values.first(where: { $0.hostID == hostID })?.id
    }

    func request(
        attributes: AgentActivityAttributes,
        content: AgentActivityAttributes.ContentState
    ) throws -> LiveActivityHandle {
        if let requestError { throw requestError }
        guard areEnabled else { throw LiveActivityRequestError.requestFailed() }
        guard let hostID = UUID(uuidString: attributes.hostID) else {
            throw LiveActivityRequestError.invalidHostID
        }
        let id = "act-\(nextID)"
        nextID += 1
        requested.append(content)
        let handle = LiveActivityHandle(id: id, hostID: hostID)
        requestedHandles.append(handle)
        records[id] = Record(id: id, hostID: hostID, content: content)
        return handle
    }

    func update(id: String, content: AgentActivityAttributes.ContentState) {
        updates.append((id, content))
        records[id]?.content = content
    }

    func end(
        id: String,
        finalContent: AgentActivityAttributes.ContentState?,
        immediate: Bool
    ) {
        ended.append((id, finalContent, immediate))
        if let record = records.removeValue(forKey: id) {
            for continuation in record.tokenContinuations { continuation.finish() }
            for continuation in record.stateContinuations { continuation.finish() }
        }
    }

    func currentActivities() -> [(id: String, hostID: UUID)] {
        records.values.map { ($0.id, $0.hostID) }
    }

    func pushTokenUpdates(for handle: LiveActivityHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard var record = records[handle.id] else {
                continuation.finish()
                return
            }
            record.tokenContinuations.append(continuation)
            let replay = record.lastToken
            records[handle.id] = record
            // ActivityKit yields the current token as soon as the sequence
            // is observed, then subsequent rotations.
            if let replay { continuation.yield(replay) }
        }
    }

    func stateUpdates(for handle: LiveActivityHandle) -> AsyncStream<LiveActivityRunState> {
        stream(for: handle) { $0.stateContinuations.append($1) }
    }

    private func stream<Element>(
        for handle: LiveActivityHandle,
        register: (inout Record, AsyncStream<Element>.Continuation) -> Void
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            guard var record = records[handle.id] else {
                continuation.finish()
                return
            }
            register(&record, continuation)
            records[handle.id] = record
        }
    }
}
