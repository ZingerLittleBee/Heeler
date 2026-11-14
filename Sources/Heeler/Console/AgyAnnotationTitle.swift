import Foundation

/// Reads Antigravity CLI (`agy`) conversation titles from `<configRoot>/annotations/<id>.pbtxt`
/// (`ConversationAnnotations.title`) without modifying any Host files or `settings.json`.
enum AgyAnnotationTitle {
    static let maximumAnnotationBytes = 16 * 1024

    enum ReadOutcome: Equatable, Sendable {
        case titled(root: String, rootID: String, title: String)
        case untitled(root: String, rootID: String)
        case unresolved
    }

    struct ResolvedConversation: Equatable, Sendable {
        let root: String
        let rootID: String
        let isVerifiedRoot: Bool
    }

    static func annotationPath(in root: String, id: String) -> String {
        RemoteFilePath.join(root, "annotations", "\(id).pbtxt")
    }

    static func sanitize(_ raw: String) -> String? {
        var normalized = ""
        normalized.reserveCapacity(raw.count)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        for scalar in raw.unicodeScalars {
            if scalar == "\r" || scalar == "\n" || scalar == "\t" {
                normalized.append(" ")
            } else if !forbidden.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            }
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses top-level `title` from Antigravity CLI's Go `prototext` (`ConversationAnnotations`).
    /// Fails closed (returns `nil`) when truncated or syntactically malformed.
    static func parse(_ data: Data) -> String? {
        guard data.count <= maximumAnnotationBytes else { return nil }
        var parser = PrototextParser(bytes: Array(data))
        return parser.parseTitle()
    }

    static func readAnnotation(
        in root: String, rootID: String, files: ChatHostFiles
    ) async throws -> ReadOutcome {
        let path = annotationPath(in: root, id: rootID)
        guard RemoteFilePath.isAcceptable(root), RemoteFilePath.isAcceptable(path) else {
            return .unresolved
        }
        let slice = try await files.read(
            RemoteFileRange(path: path, offset: 0, maxBytes: maximumAnnotationBytes + 1))
        guard let length = slice.length else {
            return .untitled(root: root, rootID: rootID)
        }
        if length > UInt64(maximumAnnotationBytes) {
            return .untitled(root: root, rootID: rootID)
        }
        guard UInt64(slice.data.count) == length else {
            throw TransportError.channelFailed(detail: "incomplete annotation read")
        }
        return parse(slice.data).map { .titled(root: root, rootID: rootID, title: $0) }
            ?? .untitled(root: root, rootID: rootID)
    }

    /// Resolves `sessionID` (including subagent hook IDs via `AgyTranscriptLocator`) to the
    /// top-level conversation's config root and canonical lowercase UUID.
    static func resolveRootConversation(
        sessionID: String, files: ChatHostFiles
    ) async throws -> ResolvedConversation? {
        guard let id = ConversationReference.canonicalUUID(sessionID) else { return nil }
        switch try await AgyTranscriptLocator(files: files).locate(sessionID: id) {
        case .success(let transcriptPath):
            guard let rootID = AgyTranscriptLocator.sessionID(ofTranscript: transcriptPath) else {
                return nil
            }
            let root = AgyTranscriptLocator.root(ofTranscript: transcriptPath)
            guard RemoteFilePath.isAcceptable(root) else { return nil }
            return ResolvedConversation(root: root, rootID: rootID, isVerifiedRoot: true)
        case .failure(.notWritten), .failure(.notFound):
            let home = try await files.home()
            let roots = try await files.configRoots(
                for: .antigravity,
                defaultRoot: RemoteFilePath.join(home, AgyTranscriptLocator.defaultRoot))
            if let root = try await ChatHostFiles.firstAnswer(across: roots, { root -> String? in
                let path = annotationPath(in: root, id: id)
                guard RemoteFilePath.isAcceptable(root), RemoteFilePath.isAcceptable(path),
                    let status = try await files.status(path), status.kind != .directory
                else { return nil }
                return root
            }) {
                return ResolvedConversation(root: root, rootID: id, isVerifiedRoot: true)
            }
            if let root = try await ChatHostFiles.firstAnswer(across: roots, { root -> String? in
                let folder = AgyTranscriptLocator.folder(in: root, id: id)
                guard RemoteFilePath.isAcceptable(root), RemoteFilePath.isAcceptable(folder),
                    let status = try await files.status(folder),
                    status.kind == nil || status.kind == .directory
                else { return nil }
                return root
            }) {
                return ResolvedConversation(root: root, rootID: id, isVerifiedRoot: false)
            }
            return nil
        }
    }
}

private extension AgyAnnotationTitle {
    struct PrototextParser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseTitle() -> String? {
            var foundTitle: String?
            while true {
                skipTrivia()
                if index >= bytes.count {
                    return foundTitle.flatMap(sanitize)
                }
                guard let fieldName = readFieldName() else { return nil }
                skipTrivia()
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x7B || bytes[index] == 0x3C {
                    // Colon-less message block: invalid for string `title`.
                    guard fieldName != "title" else { return nil }
                    guard skipBalancedBlock() else { return nil }
                } else if bytes[index] == 0x3A {
                    index += 1
                    skipTrivia()
                    guard index < bytes.count else { return nil }
                    let byte = bytes[index]
                    if byte == 0x7B || byte == 0x3C {
                        guard fieldName != "title" else { return nil }
                        guard skipBalancedBlock() else { return nil }
                    } else if byte == 0x5B {
                        guard fieldName != "title" else { return nil }
                        guard skipBalancedList() else { return nil }
                    } else if byte == 0x22 || byte == 0x27 {
                        var buffer: [UInt8]? = fieldName == "title" ? [] : nil
                        guard readAdjacentStringLiterals(into: &buffer) else { return nil }
                        if let buffer {
                            guard let decoded = String(bytes: buffer, encoding: .utf8) else {
                                return nil
                            }
                            foundTitle = decoded
                        }
                    } else {
                        guard fieldName != "title" else { return nil }
                        guard skipScalarToken() else { return nil }
                    }
                } else {
                    return nil
                }
                skipTrivia()
                if index < bytes.count, bytes[index] == 0x2C || bytes[index] == 0x3B {
                    index += 1
                }
            }
        }

        private mutating func skipTrivia() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B
                    || byte == 0x0C
                {
                    index += 1
                } else if byte == 0x23 {
                    index += 1
                    while index < bytes.count, bytes[index] != 0x0A {
                        index += 1
                    }
                } else {
                    break
                }
            }
        }

        private mutating func readFieldName() -> String? {
            if bytes[index] == 0x5B {
                guard skipBalancedList() else { return nil }
                return ""
            }
            guard isIdentifierStart(bytes[index]) else { return nil }
            let start = index
            index += 1
            while index < bytes.count, isIdentifierContinue(bytes[index]) {
                index += 1
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        private mutating func skipBalancedBlock() -> Bool {
            let open = bytes[index]
            let expectedClose: UInt8 = open == 0x7B ? 0x7D : 0x3E
            return skipBalanced(opening: open, closing: expectedClose)
        }

        private mutating func skipBalancedList() -> Bool {
            skipBalanced(opening: 0x5B, closing: 0x5D)
        }

        private mutating func skipBalanced(opening: UInt8, closing: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == opening else { return false }
            var stack: [UInt8] = [closing]
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 || byte == 0x27 {
                    var ignored: [UInt8]?
                    guard consumeStringLiteral(into: &ignored) else { return false }
                } else if byte == 0x23 {
                    index += 1
                    while index < bytes.count, bytes[index] != 0x0A {
                        index += 1
                    }
                } else if byte == 0x7B {
                    stack.append(0x7D)
                    index += 1
                } else if byte == 0x3C {
                    stack.append(0x3E)
                    index += 1
                } else if byte == 0x5B {
                    stack.append(0x5D)
                    index += 1
                } else if byte == 0x7D || byte == 0x3E || byte == 0x5D {
                    guard let top = stack.popLast(), top == byte else { return false }
                    index += 1
                    if stack.isEmpty { return true }
                } else {
                    index += 1
                }
            }
            return false
        }

        private mutating func readAdjacentStringLiterals(into buffer: inout [UInt8]?) -> Bool {
            guard index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 else {
                return false
            }
            while index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                guard consumeStringLiteral(into: &buffer) else { return false }
                let checkpoint = index
                skipTrivia()
                if index >= bytes.count || (bytes[index] != 0x22 && bytes[index] != 0x27) {
                    index = checkpoint
                    break
                }
            }
            return true
        }

        private mutating func consumeStringLiteral(into buffer: inout [UInt8]?) -> Bool {
            guard index < bytes.count else { return false }
            let quote = bytes[index]
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == quote {
                    index += 1
                    return true
                }
                if byte == 0x0A || byte == 0x0D || byte == 0x00 {
                    return false
                }
                if byte == 0x5C {
                    guard parseEscape(into: &buffer) else { return false }
                } else {
                    buffer?.append(byte)
                    index += 1
                }
            }
            return false
        }

        private mutating func parseEscape(into buffer: inout [UInt8]?) -> Bool {
            index += 1
            guard index < bytes.count else { return false }
            let escaped = bytes[index]
            switch escaped {
            case 0x61: buffer?.append(0x07); index += 1; return true
            case 0x62: buffer?.append(0x08); index += 1; return true
            case 0x66: buffer?.append(0x0C); index += 1; return true
            case 0x6E: buffer?.append(0x0A); index += 1; return true
            case 0x72: buffer?.append(0x0D); index += 1; return true
            case 0x74: buffer?.append(0x09); index += 1; return true
            case 0x76: buffer?.append(0x0B); index += 1; return true
            case 0x5C: buffer?.append(0x5C); index += 1; return true
            case 0x27: buffer?.append(0x27); index += 1; return true
            case 0x22: buffer?.append(0x22); index += 1; return true
            case 0x3F: buffer?.append(0x3F); index += 1; return true
            case 0x30...0x37:
                var value = 0
                var count = 0
                while index < bytes.count, count < 3, (0x30...0x37).contains(bytes[index]) {
                    value = (value * 8) + Int(bytes[index] - 0x30)
                    index += 1
                    count += 1
                }
                guard value <= 0xFF else { return false }
                buffer?.append(UInt8(value))
                return true
            case 0x78:
                index += 1
                guard let value = readHex(minDigits: 1, maxDigits: 2) else { return false }
                buffer?.append(UInt8(value))
                return true
            case 0x75:
                index += 1
                guard let codeUnit = readHex(exactDigits: 4) else { return false }
                if (0xD800...0xDBFF).contains(codeUnit) {
                    guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                        return false
                    }
                    index += 2
                    guard let lowUnit = readHex(exactDigits: 4), (0xDC00...0xDFFF).contains(lowUnit) else {
                        return false
                    }
                    let combined = 0x10000 + ((codeUnit - 0xD800) << 10) + (lowUnit - 0xDC00)
                    guard let scalar = UnicodeScalar(combined) else { return false }
                    buffer?.append(contentsOf: String(scalar).utf8)
                    return true
                }
                guard let scalar = UnicodeScalar(codeUnit) else { return false }
                buffer?.append(contentsOf: String(scalar).utf8)
                return true
            case 0x55:
                index += 1
                guard let value = readHex(exactDigits: 8), let scalar = UnicodeScalar(value) else {
                    return false
                }
                buffer?.append(contentsOf: String(scalar).utf8)
                return true
            default:
                return false
            }
        }

        private mutating func readHex(exactDigits count: Int) -> UInt32? {
            readHex(minDigits: count, maxDigits: count)
        }

        private mutating func readHex(minDigits: Int, maxDigits: Int) -> UInt32? {
            var value: UInt32 = 0
            var digits = 0
            while index < bytes.count, digits < maxDigits, let digit = hexValue(bytes[index]) {
                value = (value << 4) | digit
                index += 1
                digits += 1
            }
            guard digits >= minDigits else { return nil }
            return value
        }

        private mutating func skipScalarToken() -> Bool {
            let start = index
            while index < bytes.count, isScalarByte(bytes[index]) {
                index += 1
            }
            return index > start
        }

        private func isIdentifierStart(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
        }

        private func isIdentifierContinue(_ byte: UInt8) -> Bool {
            isIdentifierStart(byte) || (0x30...0x39).contains(byte)
        }

        private func isScalarByte(_ byte: UInt8) -> Bool {
            isIdentifierContinue(byte) || byte == 0x2E || byte == 0x2B || byte == 0x2D
        }

        private func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30...0x39: UInt32(byte - 0x30)
            case 0x41...0x46: UInt32(byte - 0x41 + 10)
            case 0x61...0x66: UInt32(byte - 0x61 + 10)
            default: nil
            }
        }
    }
}

/// Owns read-only per-Host and per-Pane Antigravity CLI annotation title resolution
/// for `ConsoleStore` without adding file reads to `ChatConversationEngine`.
@MainActor
final class AgyAnnotationTitleStore {
    private struct PaneIdentity: Equatable {
        let terminalID: String
        let workspaceID: String
        let tabID: String

        init(_ agent: Agent) {
            terminalID = agent.terminalID
            workspaceID = agent.workspaceID
            tabID = agent.tabID
        }
    }

    private struct BoundConversation: Equatable {
        let root: String
        let rootID: String
    }

    private enum KnownState: Equatable {
        case unknown
        case untitled(root: String, rootID: String)
        case titled(root: String, rootID: String, title: String)

        var rootID: String? {
            switch self {
            case .unknown: nil
            case .untitled(_, let rootID), .titled(_, let rootID, _): rootID
            }
        }
    }

    private struct Entry {
        var identity: PaneIdentity
        var generation: UInt64
        var boundByChat: BoundConversation?
        var sessionFamily: Set<String> = []
        var known: KnownState = .unknown
        var lastReadKey: String?
        var retries: (key: String, count: Int)?
    }

    private struct ResolvedSession {
        let root: String
        let rootID: String
    }

    private let retryDelay: Duration
    private let onChange: @MainActor () -> Void
    private var entries: [ConsoleAgent.ID: Entry] = [:]
    private var resolvedSessionsByHost: [Host.ID: (generation: UInt64, map: [String: ResolvedSession])] = [:]
    private var refreshEpoch: [Host.ID: UInt64] = [:]
    private var tasks: [Host.ID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(retryDelay: Duration, onChange: @escaping @MainActor () -> Void) {
        self.retryDelay = retryDelay
        self.onChange = onChange
    }

    func applying(to row: ConsoleAgent) -> ConsoleAgent {
        let updated = applying(to: row.agent, id: row.id)
        guard updated != row.agent else { return row }
        var copy = row
        copy.agent = updated
        return copy
    }

    func applying(to agent: Agent, id: ConsoleAgent.ID) -> Agent {
        guard agent.kind == ChatProgram.agy.rawValue,
            let entry = entries[id],
            entry.identity == PaneIdentity(agent),
            case .titled(_, let rootID, let title) = entry.known
        else { return agent }
        if agent.agentSession == nil && entry.boundByChat == nil {
            return agent
        }
        if let rawSession = agent.agentSession?.value {
            guard let reportedID = ConversationReference.canonicalUUID(rawSession) else {
                return agent
            }
            let matchesKnownConversation = entry.sessionFamily.contains(reportedID)
                || resolvedSessionsByHost[id.hostID]?.map[reportedID]?.rootID == rootID
            guard matchesKnownConversation else {
                return agent
            }
        }
        return agent.applyingConversationTitle(title)
    }

    func isKnownUntitled(for row: ConsoleAgent) -> Bool {
        guard row.agent.kind == ChatProgram.agy.rawValue,
            let entry = entries[row.id],
            entry.identity == PaneIdentity(row.agent),
            case .untitled = entry.known
        else { return false }
        return true
    }

    func noteChatBinding(
        for id: ConsoleAgent.ID, agent: Agent, generation: UInt64, root: String?, rootID: String?
    ) {
        guard agent.kind == ChatProgram.agy.rawValue else { return }
        let identity = PaneIdentity(agent)
        var entry = entries[id].flatMap { existing in
            existing.identity == identity ? existing : nil
        } ?? Entry(identity: identity, generation: generation)
        entry.generation = generation

        if let root, RemoteFilePath.isAcceptable(root),
            let rawID = rootID, let canonical = ConversationReference.canonicalUUID(rawID)
        {
            let nextBound = BoundConversation(root: root, rootID: canonical)
            let changedBound = entry.boundByChat != nextBound
            entry.boundByChat = nextBound
            if let knownRootID = entry.known.rootID, knownRootID != canonical {
                let hadTitle: Bool = if case .titled = entry.known { true } else { false }
                entry.known = .unknown
                entry.sessionFamily = [canonical]
                entry.lastReadKey = nil
                entry.retries = nil
                entries[id] = entry
                if hadTitle { onChange() }
                return
            }
            entry.sessionFamily.insert(canonical)
            if changedBound || entry.known == .unknown {
                entry.lastReadKey = nil
                entry.retries = nil
            }
            entries[id] = entry
            return
        }

        let hadTitle: Bool = if case .titled = entry.known { true } else { false }
        entry.boundByChat = nil
        if agent.agentSession == nil {
            entry.known = .unknown
            entry.sessionFamily = []
            entry.lastReadKey = nil
            entry.retries = nil
            entries[id] = entry
            if hadTitle { onChange() }
        } else {
            entries[id] = entry
        }
    }

    func bumpRefreshEpoch(for hostID: Host.ID? = nil) {
        if let hostID {
            refreshEpoch[hostID, default: 0] &+= 1
            return
        }
        let hostIDs = Set(entries.keys.map(\.hostID)).union(refreshEpoch.keys)
        for id in hostIDs {
            refreshEpoch[id, default: 0] &+= 1
        }
    }

    func invalidateHost(_ hostID: Host.ID) {
        tasks[hostID]?.task.cancel()
        tasks[hostID] = nil
        entries = entries.filter { $0.key.hostID != hostID }
        resolvedSessionsByHost[hostID] = nil
        refreshEpoch[hostID] = nil
    }

    func suspendAll() {
        for running in tasks.values { running.task.cancel() }
        tasks.removeAll()
    }

    func readLive(
        for agent: Agent, paneID: String, hostID: Host.ID, generation: UInt64, files: ChatHostFiles,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws -> AgyAnnotationTitle.ReadOutcome {
        guard agent.kind == ChatProgram.agy.rawValue else { return .unresolved }
        let id = ConsoleAgent.ID(hostID: hostID, paneID: paneID)
        let identity = PaneIdentity(agent)

        let reportedID = agent.agentSession.flatMap { ConversationReference.canonicalUUID($0.value) }
        let resolved: AgyAnnotationTitle.ResolvedConversation?
        if let reportedID {
            if let cached = cachedResolution(for: reportedID, on: hostID, generation: generation) {
                resolved = AgyAnnotationTitle.ResolvedConversation(
                    root: cached.root, rootID: cached.rootID, isVerifiedRoot: true)
            } else {
                let located = try await AgyAnnotationTitle.resolveRootConversation(
                    sessionID: reportedID, files: files)
                guard !Task.isCancelled, isCurrent() else { return .unresolved }
                if let located, located.isVerifiedRoot {
                    storeResolution(
                        ResolvedSession(root: located.root, rootID: located.rootID),
                        for: reportedID, on: hostID, generation: generation)
                }
                resolved = located
            }
        } else if agent.agentSession == nil,
            let entry = entries[id], entry.identity == identity, let bound = entry.boundByChat
        {
            resolved = AgyAnnotationTitle.ResolvedConversation(
                root: bound.root, rootID: bound.rootID, isVerifiedRoot: true)
        } else {
            return .unresolved
        }

        guard let resolved else { return .unresolved }
        let outcome = try await AgyAnnotationTitle.readAnnotation(
            in: resolved.root, rootID: resolved.rootID, files: files)
        guard !Task.isCancelled, isCurrent() else { return .unresolved }

        var entry = entries[id].flatMap { existing in
            existing.identity == identity ? existing : nil
        } ?? Entry(identity: identity, generation: generation)
        entry.generation = generation
        let previousFamily = entry.sessionFamily
        if entry.known.rootID != resolved.rootID {
            entry.sessionFamily = [resolved.rootID]
        } else {
            entry.sessionFamily.insert(resolved.rootID)
        }
        if let reportedID {
            entry.sessionFamily.insert(reportedID)
        }

        let nextKnown: KnownState = switch outcome {
        case .titled(let root, let rootID, let title):
            .titled(root: root, rootID: rootID, title: title)
        case .untitled(let root, let rootID):
            .untitled(root: root, rootID: rootID)
        case .unresolved:
            entry.known
        }
        let familyChangedForTitled: Bool = if case .titled = nextKnown {
            entry.sessionFamily != previousFamily
        } else {
            false
        }
        let changed = nextKnown != entry.known || familyChangedForTitled
        entry.known = nextKnown
        entries[id] = entry
        if changed { onChange() }
        return outcome
    }

    func reconcile(
        projections: [Host.ID: any ConsoleHostProjection],
        isActive: Bool,
        hostPlatforms: [Host.ID: HostPlatform],
        offersAgyChat: (Host.ID) -> Bool,
        files: (Host.ID) -> ChatHostFiles,
        isProjectionCurrent: @escaping @MainActor (
            _ hostID: Host.ID, _ expected: any ConsoleHostProjection, _ generation: UInt64
        ) -> Bool,
        onReconcileNeeded: @escaping @MainActor () -> Void
    ) {
        for projection in projections.values {
            let hostID = projection.host.id
            guard offersAgyChat(hostID), isActive,
                projection.status == .connected, !projection.isAwaitingSnapshot,
                hostPlatforms[hostID] == .posix
            else {
                tasks[hostID]?.task.cancel()
                tasks[hostID] = nil
                continue
            }

            let generation = projection.transportGeneration
            if resolvedSessionsByHost[hostID]?.generation != generation {
                resolvedSessionsByHost[hostID] = (generation, [:])
            }

            let allRows = Dictionary(
                (Array(projection.agentsByPane.values) + Array(projection.departedAgentsByPane.values))
                    .map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            let epoch = refreshEpoch[hostID, default: 0]

            var prunedEntries = false
            for (id, entry) in entries where id.hostID == hostID {
                guard let row = allRows[id],
                    row.agent.kind == ChatProgram.agy.rawValue,
                    PaneIdentity(row.agent) == entry.identity
                else {
                    entries[id] = nil
                    prunedEntries = true
                    continue
                }
                if entry.generation != generation {
                    var updated = entry
                    updated.generation = generation
                    updated.lastReadKey = nil
                    updated.retries = nil
                    entries[id] = updated
                }
            }
            if prunedEntries { onChange() }

            var candidates: [(agent: ConsoleAgent, key: String)] = []
            for row in projection.agentsByPane.values
            where row.agent.kind == ChatProgram.agy.rawValue {
                let id = row.id
                let identity = PaneIdentity(row.agent)
                var entry = entries[id] ?? Entry(identity: identity, generation: generation)
                entry.generation = generation
                entries[id] = entry

                let reported = row.agent.agentSession.flatMap {
                    ConversationReference.canonicalUUID($0.value)
                }
                let token = reported ?? entry.boundByChat?.rootID
                guard let token, !token.isEmpty else {
                    if entry.boundByChat == nil, entry.known != .unknown {
                        let hadTitle: Bool = if case .titled = entry.known { true } else { false }
                        entries[id]?.known = .unknown
                        entries[id]?.sessionFamily = []
                        entries[id]?.lastReadKey = nil
                        entries[id]?.retries = nil
                        if hadTitle { onChange() }
                    }
                    continue
                }
                let key = "\(generation):\(row.agent.terminalID):\(token):\(row.agent.status.rawValue):\(row.agent.stateChangeSeq ?? 0):\(epoch)"
                if entry.lastReadKey != key {
                    candidates.append((row, key))
                }
            }

            guard tasks[hostID] == nil, !candidates.isEmpty else { continue }
            let hostFiles = files(hostID)
            let taskToken = UUID()
            let task = Task { [weak self, weak projection] in
                guard let self, let projection else { return }
                var needsRetry = false
                for candidate in candidates {
                    guard !Task.isCancelled, isProjectionCurrent(hostID, projection, generation)
                    else { break }

                    let agentID = candidate.agent.id
                    let key = candidate.key
                    self.entries[agentID]?.lastReadKey = key
                    let priorRetries = self.entries[agentID]?.retries.flatMap {
                        $0.key == key ? $0.count : nil
                    } ?? 0

                    let outcome: AgyAnnotationTitle.ReadOutcome
                    do {
                        outcome = try await self.readLive(
                            for: candidate.agent.agent,
                            paneID: candidate.agent.agent.paneID,
                            hostID: hostID,
                            generation: generation,
                            files: hostFiles,
                            isCurrent: { isProjectionCurrent(hostID, projection, generation) })
                    } catch {
                        outcome = .unresolved
                    }
                    guard !Task.isCancelled, isProjectionCurrent(hostID, projection, generation) else {
                        break
                    }

                    switch outcome {
                    case .titled:
                        self.entries[agentID]?.retries = nil
                    case .untitled, .unresolved:
                        if priorRetries < 3 {
                            self.entries[agentID]?.retries = (key, priorRetries + 1)
                            self.entries[agentID]?.lastReadKey = nil
                            needsRetry = true
                        } else {
                            self.entries[agentID]?.retries = nil
                        }
                    }
                }
                if needsRetry { try? await Task.sleep(for: self.retryDelay) }
                guard !Task.isCancelled else { return }
                if self.tasks[hostID]?.token == taskToken {
                    self.tasks[hostID] = nil
                }
                if isProjectionCurrent(hostID, projection, generation) {
                    onReconcileNeeded()
                }
            }
            tasks[hostID] = (taskToken, task)
        }
    }

    private func cachedResolution(
        for sessionID: String, on hostID: Host.ID, generation: UInt64
    ) -> ResolvedSession? {
        guard let cached = resolvedSessionsByHost[hostID], cached.generation == generation else {
            return nil
        }
        return cached.map[sessionID]
    }

    private func storeResolution(
        _ resolution: ResolvedSession, for sessionID: String, on hostID: Host.ID, generation: UInt64
    ) {
        if resolvedSessionsByHost[hostID]?.generation != generation {
            resolvedSessionsByHost[hostID] = (generation, [sessionID: resolution])
        } else {
            resolvedSessionsByHost[hostID]?.map[sessionID] = resolution
        }
    }
}
