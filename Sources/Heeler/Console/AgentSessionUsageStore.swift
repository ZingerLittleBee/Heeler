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
    /// Whether omp shows its own `tok/s` readout (`composer.tokenRate`), read
    /// from the config beside the session file. The strip shows the rate
    /// exactly when the Agent would.
    private(set) var showsTokenRate = false
    /// The current model's context window as omp on the Host reports it,
    /// nil until asked or when omp does not know. Looked up once per model
    /// selector for the store's life; a model omp cannot size stays unsized
    /// rather than being asked about on every tick.
    private(set) var contextWindow: Int?
    @ObservationIgnored private var contextWindows: [String: Int?] = [:]
    @ObservationIgnored private var resolvingSelector: String?

    /// `11.0%/272K` once the window is known, `30K` until then.
    var contextText: String? { usage.contextText(window: contextWindow) }

    /// How long a config read stays good for. The setting is toggled by hand
    /// and rarely, so a minute of lag costs nothing; re-reading on every tick
    /// would double the strip's round trips.
    static let configInterval: Duration = .seconds(60)
    /// omp's config is a few hundred bytes; a file this large is not it.
    static let configBytes = 256 * 1_024

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
    /// Counts refreshes so one that resumes from a read after a newer refresh
    /// began can tell, and drop its bytes: `.task(id:)` cancels the previous
    /// follower on a path change but does not wait for it, and its read may
    /// still land after the new path's totals are in place.
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    /// When the config was last read, nil until it has been.
    @ObservationIgnored private var configReadAt: ContinuousClock.Instant?

    /// Reads whatever was appended since the last refresh and folds every
    /// complete line among it. `read` is the caller's transport borrow,
    /// resolved per call so a reconnect cannot leave a stale one behind.
    func refresh(
        path: String,
        read: (RemoteFileRange) async throws -> RemoteFileSlice,
        resolveContextWindow: ((String) async throws -> Int?)? = nil
    ) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if path != followedPath {
            clear()
            followedPath = path
        }
        await refreshConfigIfDue(sessionPath: path, generation: generation, read: read)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        await follow(path: path, generation: generation, read: read)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        if let resolveContextWindow {
            await resolveContextWindowIfNeeded(generation: generation, resolve: resolveContextWindow)
        }
    }

    /// Reads the appended tail and folds its complete lines.
    private func follow(
        path: String,
        generation: UInt64,
        read: (RemoteFileRange) async throws -> RemoteFileSlice
    ) async {
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
            // A newer refresh owns the store now — another path, or the same
            // one re-followed. These bytes belong to the read that was current
            // when they were asked for, not to whatever is followed now.
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            guard let length = slice.length else {
                // The session file is gone. Its figures were never Heeler's to
                // invent, so the strip goes back to showing nothing.
                clear()
                return
            }
            if length < offset {
                // The path now holds a shorter file than the one the offset
                // addresses — replaced or rotated. Start over from its head,
                // still following it: dropping the path too would make the
                // next refresh start over a second time.
                restart()
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
        showsTokenRate = false
        configReadAt = nil
        restart()
    }

    /// Asks the Host once per model. A failed lookup is not remembered, so
    /// the next refresh asks again; an answer of "unknown" is, so a model omp
    /// cannot size is not asked about every five seconds.
    private func resolveContextWindowIfNeeded(
        generation: UInt64,
        resolve: (String) async throws -> Int?
    ) async {
        guard let selector = usage.modelSelector else {
            contextWindow = nil
            return
        }
        if let known = contextWindows[selector] {
            contextWindow = known
            return
        }
        guard resolvingSelector != selector else { return }
        resolvingSelector = selector
        defer { resolvingSelector = nil }
        let window: Int?
        do {
            window = try await resolve(selector)
        } catch {
            return
        }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        contextWindows[selector] = window
        if usage.modelSelector == selector { contextWindow = window }
    }

    /// Reads omp's config once a minute. A failed read keeps the last answer;
    /// an absent config, or a session stored where no config sits beside it,
    /// means the readout is off.
    private func refreshConfigIfDue(
        sessionPath: String,
        generation: UInt64,
        read: (RemoteFileRange) async throws -> RemoteFileSlice
    ) async {
        if let configReadAt, ContinuousClock.now < configReadAt.advanced(by: Self.configInterval) {
            return
        }
        guard let configPath = AgentSessionConfig.configPath(forSessionFile: sessionPath) else {
            showsTokenRate = false
            configReadAt = .now
            return
        }
        let slice: RemoteFileSlice
        do {
            slice = try await read(
                RemoteFileRange(path: configPath, offset: 0, maxBytes: Self.configBytes))
        } catch {
            return
        }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        showsTokenRate = slice.length != nil && AgentSessionConfig.showsTokenRate(in: slice.data)
        configReadAt = .now
    }

    /// Forgets what was read of the followed file, keeping the path.
    private func restart() {
        offset = 0
        pending = Data()
        usage = AgentSessionUsage()
        contextWindow = nil
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
