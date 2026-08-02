import Foundation

/// Serializes every test that rewrites the host user's real
/// `~/.ssh/authorized_keys`. Swift Testing's `.serialized` only orders tests
/// within one suite, and both the auth e2e and the pairing e2e edit the same
/// file, so cross-suite mutual exclusion has to be explicit — interleaved
/// snapshot/restore would clobber each other's byte-exact restoration.
actor AuthorizedKeysTestLock {
    static let shared = AuthorizedKeysTestLock()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isHeld = false
        }
    }
}
