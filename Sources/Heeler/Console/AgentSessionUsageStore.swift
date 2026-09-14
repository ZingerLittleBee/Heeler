import Foundation
import Observation

/// Follows one Agent's session file for the terminal usage strip (#325).
///
/// The file reaches tens of megabytes and only ever grows, so this keeps the
/// bytes it has already folded and reads from there: a refresh fetches the
/// appended tail instead of the whole file again. Nothing is persisted — the
/// offset and the totals live here for as long as the screen does, which is
/// enough because a reconnect re-reads from zero once.
@MainActor
@Observable
final class AgentSessionUsageStore {
    /// What the strip renders; empty until a billed entry has been folded.
    private(set) var usage = AgentSessionUsage()

    /// How much one refresh may download. A screen opened mid-session catches
    /// up in a single pass for every realistic file, and a file larger than
    /// this finishes catching up over the following refreshes.
    static let catchUpBytes = 16 * 1_024 * 1_024
    /// One ranged read's size: small enough that folding a chunk stays
    /// imperceptible on the main actor, large enough that catching up is not
    /// thousands of round trips.
    static let chunkBytes = 512 * 1_024

    /// The file the offset below belongs to. Read activity never observes the
    /// store, so it is excluded from observation.
    @ObservationIgnored private var followedPath: String?
    @ObservationIgnored private var offset: UInt64 = 0
    /// Bytes after the last newline: a line is folded only once it is complete,
    /// so a refresh never parses half of a line another process is still
    /// writing.
    @ObservationIgnored private var pending = Data()

    /// Reads whatever was appended since the last refresh and folds every
    /// complete line among it. `read` is the caller's transport borrow,
    /// resolved per call so a reconnect cannot leave a stale one behind.
    func refresh(
        path: String,
        read: (RemoteFileRange) async throws -> RemoteFileSlice
    ) async {
        if path != followedPath {
            clear()
            followedPath = path
        }
        var budget = Self.catchUpBytes
        while budget > 0 {
            let maxBytes = min(budget, Self.chunkBytes)
            let slice: RemoteFileSlice
            do {
                slice = try await read(
                    RemoteFileRange(path: path, offset: offset, maxBytes: maxBytes))
            } catch {
                // A failed read says nothing about the file: keep the totals
                // and the offset, and try again on the next refresh.
                return
            }
            guard let length = slice.length else {
                // The session file is gone. Its figures were never Heeler's to
                // invent, so the strip goes back to showing nothing.
                clear()
                return
            }
            if length < offset {
                // The path now holds a shorter file than the one the offset
                // addresses — replaced or rotated. Start over from its head.
                clear()
                continue
            }
            offset += UInt64(slice.data.count)
            budget -= slice.data.count
            pending.append(slice.data)
            foldCompleteLines()
            // A short read is the end of the file: stop here instead of issuing
            // another round trip that could only return nothing.
            if slice.data.count < maxBytes { return }
        }
    }

    /// Drops the followed file and its totals. The screen calls this when the
    /// focused Agent has no session path, so a previous Agent's figures cannot
    /// outlive the switch.
    func clear() {
        followedPath = nil
        offset = 0
        pending = Data()
        usage = AgentSessionUsage()
    }

    private func foldCompleteLines() {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty {
                usage.fold(line: Data(line))
            }
            pending.removeSubrange(pending.startIndex...newline)
        }
    }
}
