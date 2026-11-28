import Foundation

@MainActor
protocol AmpChatProjection: AnyObject {
    func ampPluginLocation(in pane: String) async throws -> AmpPluginLocation
    func chatHostFiles() -> ChatHostFiles
    func exchangeAmp(_ request: AmpChatRequest, record: AmpPluginRecord, at place: AmpPluginLocation, in pane: String) async throws -> AmpChatReply
    func installAmp(at place: AmpPluginLocation, replacing previous: Data?, in pane: String) async throws
}

/// Follows the socket published by the current foreground CLI's own plugin.
@MainActor
final class AmpChatConnection {
    typealias Projection = @MainActor () throws -> any AmpChatProjection
    let pane: String
    let isReadOnly: Bool
    private let projection: Projection
    private(set) var current: AmpChatTarget?
    private(set) var location: AmpPluginLocation?
    private var inspection: UInt64 = 0

    init(pane: String, readOnly: Bool = false, projection: @escaping Projection) {
        self.pane = pane
        isReadOnly = readOnly
        self.projection = projection
    }

    func evidence() async throws -> ChatSessionEvidence {
        inspection &+= 1
        let check = inspection
        do {
            let place = try await projection().ampPluginLocation(in: pane)
            let files = try projection().chatHostFiles()
            let record: AmpPluginRecord?
            do {
                let slice = try await files.read(.init(path: place.recordPath, offset: 0, maxBytes: 4096))
                record = try? JSONDecoder().decode(AmpPluginRecord.self, from: slice.data)
            } catch TransportError.hostFileUnreadable(let status) where status == 2 || status == 10 {
                record = nil
            }
            guard check == inspection else { throw CancellationError() }
            location = place
            guard let record, record.pid == place.pid, record.start == place.start else {
                throw try await place.installation(files).problem
            }
            guard record.version == 1 else { throw AmpChatProblem.incompatible }
            guard (record.contentRevision ?? 1) >= 2 else { throw try await place.installation(files).problem }
            let reply = try await exchange(AmpChatRequest("binding"), record: record)
            guard check == inspection else { throw CancellationError() }
            guard let binding = reply.binding, binding.version == 1, binding.instance == record.instance,
                binding.pid == place.pid, binding.start == place.start, binding.revision >= 0
            else { throw AmpChatProblem.incompatible }
            guard let thread = binding.thread else { throw AmpChatProblem.noThread }
            guard Self.threadID(thread) != nil else { throw AmpChatProblem.incompatible }
            current = AmpChatTarget(record: record, binding: binding)
            return .bound(sessionID: thread, transcriptRoot: nil, directory: nil)
        } catch let problem as AmpChatProblem {
            guard check == inspection else { throw CancellationError() }
            current = nil
            if problem == .unidentified { location = nil }
            return .unavailable(.amp(problem))
        } catch {
            if check == inspection { current = nil }
            throw error
        }
    }

    nonisolated static func threadID(_ value: String) -> String? {
        guard value.hasPrefix("T-"), ConversationReference.canonicalUUID(String(value.dropFirst(2))) != nil else { return nil }
        return value
    }

    func install(_ place: AmpPluginLocation, updating: Bool = false) async throws {
        guard try await projection().ampPluginLocation(in: pane) == place else { throw AmpChatProblem.changed }
        let previous: Data?
        if updating {
            let state = try await place.installation(projection().chatHostFiles())
            guard state.problem == .update || state.problem == .reload else { throw state.problem }
            previous = state.previous
        } else { previous = nil }
        try await projection().installAmp(at: place, replacing: previous, in: pane)
    }

    private func exchange(_ request: AmpChatRequest, record: AmpPluginRecord) async throws -> AmpChatReply {
        guard let place = location, place.pid == record.pid, place.start == record.start else { throw AmpChatProblem.changed }
        return try await projection().exchangeAmp(request, record: record, at: place, in: pane)
    }

    func page(
        thread: String, expected: AmpChatTarget?, offset: Int?, limit: Int, expandedCall: String? = nil
    ) async throws -> (AmpChatTarget, AmpChatPage) {
        guard let target = current, target.binding.thread == thread, expected == nil || expected == target else {
            throw ChatSourceUnavailable(reason: .amp(.changed))
        }
        var request = AmpChatRequest("page", target: target)
        request.offset = offset
        request.limit = limit
        request.fullText = true
        request.expandedCall = expandedCall
        let reply: AmpChatReply
        do {
            reply = try await exchange(request, record: target.record)
        } catch let problem as AmpChatProblem {
            throw ChatSourceUnavailable(reason: .amp(problem))
        }
        guard current == target, reply.error != "stale" else { throw ChatSourceUnavailable(reason: .amp(.changed)) }
        guard let page = reply.page, page.total >= 0, page.offset >= 0, page.rows.count <= limit,
            page.offset <= Int.max - page.rows.count,
            page.rows.isEmpty || page.offset + page.rows.count <= page.total,
            offset == nil || offset == page.offset
        else { throw ChatSourceUnavailable(reason: .amp(.unreachable)) }
        return (target, page)
    }

    func send(id: UUID, text: String, target: AmpChatTarget?) async -> CheckedSendOutcome {
        guard !isReadOnly else { return .refused(.inputNotReady(AmpChatProblem.readOnly.explanation)) }
        guard text.utf8.count <= 96 * 1024 else {
            return .refused(.inputNotReady(String(localized: "This message is too long for Amp Chat.")))
        }
        guard let target, let thread = target.binding.thread, current == target else {
            return .refused(.inputNotReady(AmpChatProblem.changed.explanation))
        }
        do {
            guard case .bound(let live, _, _) = try await evidence(), live == thread, current == target else {
                return .refused(.inputNotReady(AmpChatProblem.changed.explanation))
            }
        } catch { return .refused(.inputNotReady(AmpChatProblem.unreachable.explanation)) }
        var request = AmpChatRequest("send", target: target)
        request.requestID = id
        request.text = text
        guard let envelope = try? JSONEncoder().encode(request), envelope.count < 128 * 1024 else {
            return .refused(.inputNotReady(String(localized: "This message is too long for Amp Chat.")))
        }
        do {
            let reply = try await exchange(request, record: target.record)
            if reply.sent == true { return .submitted }
            if reply.error == "stale" { return .refused(.inputNotReady(AmpChatProblem.changed.explanation)) }
            if reply.error == "invalid" || reply.error == "reload" {
                return .refused(.inputNotReady(String(localized: "Amp could not accept this message. Check its size or reload the plugin.")))
            }
            return .outcomeUnknown
        } catch { return .outcomeUnknown }
    }
}

extension HostConsoleProjection: AmpChatProjection {
    func ampPluginLocation(in pane: String) async throws -> AmpPluginLocation {
        guard let pid = AmpPluginLocation.foreground(try await processInfo(paneID: pane)) else {
            throw AmpChatProblem.unidentified
        }
        let key = String(pid)
        let facts = try await withHostServices {
            try await $0.readProcesses(.init(pids: [key], readsStart: true, valuesOf: ["HOME", "XDG_CONFIG_HOME"]))
        }
        guard let fact = facts[key], let place = AmpPluginLocation(pid: pid, facts: fact),
            AmpPluginLocation.foreground(try await processInfo(paneID: pane)) == pid
        else { throw AmpChatProblem.unidentified }
        return place
    }

    func exchangeAmp(_ request: AmpChatRequest, record: AmpPluginRecord, at place: AmpPluginLocation, in pane: String) async throws -> AmpChatReply {
        try await session.withTransportOnce { try await $0.exchangeAmpChat(request, record: record) }
    }

    func installAmp(at place: AmpPluginLocation, replacing previous: Data?, in pane: String) async throws {
        try await session.withTransportOnce { try await $0.installAmpChatPlugin(in: place.directory, replacing: previous) }
    }
}
