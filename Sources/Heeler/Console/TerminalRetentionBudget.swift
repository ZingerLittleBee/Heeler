import Foundation

/// One Host-wide retention budget shared by Agent and ordinary-terminal
/// owners. Reclaiming a slot waits for its PTY teardown before admission.
@MainActor
final class TerminalRetentionBudget {
    struct Key: Hashable {
        let hostID: Host.ID
        let terminalID: String
    }

    enum Failure: Error, LocalizedError {
        case alreadyVisible
        case allConnectionsVisible

        var errorDescription: String? {
            switch self {
            case .alreadyVisible:
                "This terminal is already open in another window."
            case .allConnectionsVisible:
                "Close another terminal view on this Host before opening this terminal."
            }
        }
    }

    private struct Registration {
        let ownerID: UUID
        let isVisible: @MainActor () -> Bool
        let onEvict: @MainActor () async -> Void
        var recency: UInt64
    }

    let maximumPerHost: Int
    private var registrations: [Key: Registration] = [:]
    private var sequence: UInt64 = 0
    private var admissionTail: Task<Void, Never>?

    init(maximumPerHost: Int = 3) {
        self.maximumPerHost = max(1, min(maximumPerHost, 3))
    }

    func admit(
        key: Key,
        ownerID: UUID,
        isVisible: @escaping @MainActor () -> Bool,
        onEvict: @escaping @MainActor () async -> Void
    ) async throws {
        try Task.checkCancellation()
        if registrations[key]?.ownerID == ownerID {
            touch(key: key, ownerID: ownerID)
            return
        }
        let previous = admissionTail
        let task = Task { @MainActor [self] in
            try await waitForAdmission(previous)
            try Task.checkCancellation()
            if let previous = registrations[key] {
                if previous.ownerID == ownerID {
                    touch(key: key, ownerID: ownerID)
                    return
                }
                guard !previous.isVisible() else { throw Failure.alreadyVisible }
                registrations.removeValue(forKey: key)
                await previous.onEvict()
                try Task.checkCancellation()
            }
            while registrations.keys.filter({ $0.hostID == key.hostID }).count >= maximumPerHost {
                let candidate = registrations.filter { $0.key.hostID == key.hostID && !$0.value.isVisible() }
                    .min { $0.value.recency < $1.value.recency }
                guard let candidate else { throw Failure.allConnectionsVisible }
                registrations.removeValue(forKey: candidate.key)
                await candidate.value.onEvict()
                try Task.checkCancellation()
            }
            sequence &+= 1
            registrations[key] = Registration(
                ownerID: ownerID, isVisible: isVisible, onEvict: onEvict, recency: sequence)
        }
        admissionTail = Task {
            // A cancelled waiter can return before its predecessor ends, but
            // the queue itself must still preserve admission order.
            await previous?.value
            _ = await task.result
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func waitForAdmission(_ predecessor: Task<Void, Never>?) async throws {
        guard let predecessor else { return }
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        Task {
            await predecessor.value
            continuation.finish()
        }
        // AsyncStream cancellation wakes this waiter immediately. Awaiting
        // predecessor.value directly would make a cancelled terminal wait
        // for the very admission that is trying to tear that terminal down.
        for await _ in signal {}
        try Task.checkCancellation()
    }

    func touch(key: Key, ownerID: UUID) {
        guard registrations[key]?.ownerID == ownerID else { return }
        sequence &+= 1
        registrations[key]?.recency = sequence
    }

    func markIdle(key: Key, ownerID: UUID) {
        touch(key: key, ownerID: ownerID)
    }

    func remove(key: Key, ownerID: UUID) {
        guard registrations[key]?.ownerID == ownerID else { return }
        registrations.removeValue(forKey: key)
    }
}
