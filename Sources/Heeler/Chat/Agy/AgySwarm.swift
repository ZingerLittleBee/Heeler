import Foundation

/// Live snapshot of an Antigravity CLI native Swarm (`brain/<id>/.system_generated/swarm`),
/// built read-only from `members.json`, `board.jsonl`, each member's compact
/// `transcript.jsonl`, and any `view.json` written by a narrator member.
struct AgySwarmSnapshot: Equatable, Sendable {
    enum MemberStatus: String, Equatable, Sendable {
        case working
        case waiting
        case error
        case killed

        var isFinished: Bool { self == .killed }
    }

    enum FailureKind: String, Equatable, Sendable {
        case quota
        case error
    }

    struct Failure: Equatable, Sendable {
        var kind: FailureKind
        var detail: String
    }

    struct Member: Identifiable, Equatable, Sendable {
        let name: String
        let conversationID: String
        var role: String
        var model: String
        var workspaceMode: String
        var wakeMode: String
        var status: MemberStatus
        var isKilled: Bool
        var isStuck: Bool
        var steps: Int
        var posts: Int
        var unread: Int
        var lastReadSeq: Int
        var lastPostSeq: Int
        var activity: String?
        var failure: Failure?
        var channels: [String]

        var id: String { name }

        var isCoordinator: Bool { role == "coordinator" || name == "coordinator" }

        /// Role observers (`narrator`, `monitor`, and `<name>-N` replacements)
        /// stay out of task-worker status counts and `Working` promotion.
        var isRoleWorker: Bool {
            if isCoordinator { return false }
            if !role.isEmpty, role != "worker", role != "coordinator" {
                return true
            }
            return AgySwarmParser.isRoleWorkerName(name)
        }

        var displayModel: String? {
            guard !model.isEmpty else { return nil }
            if let resolved = AgyModelCatalog.resolveModelSlug(model) {
                if let effort = resolved.effort {
                    return "\(resolved.model) · \(effort)"
                }
                return resolved.model
            }
            return model
        }
    }

    struct Channel: Identifiable, Equatable, Sendable {
        let name: String
        var topic: String
        var createdBy: String
        var isArchived: Bool

        var id: String { name }
    }

    struct BoardMessage: Identifiable, Equatable, Sendable {
        let seq: Int
        let agent: String
        let text: String
        let time: String
        let timestamp: Date?
        let channel: String
        let isBrief: Bool
        let isControl: Bool
        let mentions: [String]
        let channelMentions: [String]
        let mentionsAll: Bool
        let isMarkedDone: Bool
        let isMarkedStall: Bool
        let shouldCollapseBrief: Bool
        let lineCount: Int
        let isLongPost: Bool
        let displayTime: String?
        let recipientSummary: String?
        let rawCitedSeqs: [Int]

        var id: Int { seq }

        init(
            seq: Int,
            agent: String,
            text: String,
            time: String,
            timestamp: Date?,
            channel: String,
            isBrief: Bool,
            isControl: Bool,
            mentions: [String],
            channelMentions: [String],
            mentionsAll: Bool,
            rawCitedSeqs: [Int]? = nil,
            shouldCollapseBrief: Bool? = nil,
            lineCount: Int? = nil,
            isLongPost: Bool? = nil,
            isMarkedDone: Bool? = nil,
            isMarkedStall: Bool? = nil,
            displayTime: String?? = nil
        ) {
            self.seq = seq
            self.agent = agent
            self.text = text
            self.time = time
            self.timestamp = timestamp
            self.channel = channel
            self.isBrief = isBrief
            self.isControl = isControl
            self.mentions = mentions
            self.channelMentions = channelMentions
            self.mentionsAll = mentionsAll
            self.isMarkedDone = isMarkedDone ?? (!isBrief && !isControl && Self.hasLeadingTag("[done]", in: text))
            self.isMarkedStall = isMarkedStall ?? (!isBrief && !isControl && Self.hasLeadingTag("[stall]", in: text))
            self.shouldCollapseBrief =
                shouldCollapseBrief
                ?? (isBrief && Self.exceedsBriefPreviewLimits(text))
            let computedLines = lineCount ?? Self.countLines(in: text)
            self.lineCount = computedLines
            self.isLongPost = isLongPost ?? Self.exceedsCompactPreviewLimits(text, lineCount: computedLines)
            if let explicitTime = displayTime {
                self.displayTime = explicitTime
            } else {
                self.displayTime = Self.formatClockTime(time)
            }
            self.recipientSummary = Self.buildRecipientSummary(
                agent: agent, mentions: mentions, channelMentions: channelMentions, mentionsAll: mentionsAll)
            self.rawCitedSeqs =
                rawCitedSeqs
                ?? (isControl ? [] : AgySwarmParser.extractBoardTokens(in: text).citedSeqs)
        }

        static func == (lhs: BoardMessage, rhs: BoardMessage) -> Bool {
            lhs.seq == rhs.seq
                && lhs.isControl == rhs.isControl
                && lhs.isBrief == rhs.isBrief
                && lhs.mentionsAll == rhs.mentionsAll
                && lhs.channel == rhs.channel
                && lhs.agent == rhs.agent
                && lhs.time == rhs.time
                && lhs.mentions == rhs.mentions
                && lhs.channelMentions == rhs.channelMentions
                && lhs.text == rhs.text
        }

        var mentionsCoordinator: Bool {
            mentions.contains { $0.caseInsensitiveCompare("coordinator") == .orderedSame }
        }

        func citedSeqs(in knownSeqs: Set<Int>) -> [Int] {
            guard !rawCitedSeqs.isEmpty else { return [] }
            var resolved: [Int] = []
            resolved.reserveCapacity(min(6, rawCitedSeqs.count))
            for n in rawCitedSeqs where n != seq && knownSeqs.contains(n) {
                resolved.append(n)
                if resolved.count == 6 { break }
            }
            return resolved
        }

        static func hasLeadingTag(_ tag: String, in text: String) -> Bool {
            var rest = text.drop(while: \.isWhitespace)
            while rest.first == "@" {
                rest = rest.dropFirst().drop { !$0.isWhitespace }
                rest = rest.drop(while: \.isWhitespace)
            }
            return rest.prefix(tag.count).caseInsensitiveCompare(tag) == .orderedSame
        }

        static func exceedsBriefPreviewLimits(_ text: String) -> Bool {
            if text.utf8.count > 1_440 || text.count > 360 { return true }
            var newlines = 0
            for byte in text.utf8 where byte == UInt8(ascii: "\n") {
                newlines += 1
                if newlines >= 6 { return true }
            }
            return false
        }

        /// Logical lines in a board post, ignoring trailing blank newlines.
        static func countLines(in text: String) -> Int {
            let trimmed = text.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { return 0 }
            var count = 1
            for byte in trimmed.utf8 where byte == UInt8(ascii: "\n") {
                count += 1
            }
            return count
        }

        /// Whether a post exceeds the 2-line compact directory preview and should
        /// advertise opening the dedicated Post Detail reader.
        static func exceedsCompactPreviewLimits(_ text: String, lineCount: Int? = nil) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let lines = lineCount ?? countLines(in: trimmed)
            if lines >= 3 { return true }
            if trimmed.utf8.count > 130 || trimmed.count > 100 { return true }
            if trimmed.contains("```") { return true }
            return false
        }

        static func formatClockTime(_ time: String) -> String? {
            guard !time.isEmpty else { return nil }
            if let space = time.lastIndex(of: " ") {
                let clock = time[time.index(after: space)...]
                return String(clock.prefix(5))
            }
            return time
        }

        private static func buildRecipientSummary(
            agent: String, mentions: [String], channelMentions: [String], mentionsAll: Bool
        ) -> String? {
            var targets = mentions.filter { $0.caseInsensitiveCompare(agent) != .orderedSame }.map { "@\($0)" }
            targets.append(contentsOf: channelMentions.map { "@#\($0)" })
            if mentionsAll { targets.append("@all") }
            guard !targets.isEmpty else { return nil }
            return targets.joined(separator: " ")
        }

        var singleLinePreview: String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    struct SystemAlert: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case quota
            case error
            case stuck
        }

        let id: String
        let kind: Kind
        let member: String
        let conversationID: String
        let detail: String
    }

    struct NarratorOverview: Equatable, Sendable {
        struct Phase: Equatable, Sendable {
            var label: String
            var index: Int
            var total: Int
        }

        struct AttentionItem: Identifiable, Equatable, Sendable {
            let id: String
            var kind: String
            var severity: String
            var title: String
            var why: String
        }

        struct Workstream: Identifiable, Equatable, Sendable {
            let id: String
            var title: String
            var owners: [String]
            var state: String
            var note: String
        }

        struct Milestone: Identifiable, Equatable, Sendable {
            let id: String
            var text: String
        }

        var headline: String
        var phase: Phase?
        var attention: [AttentionItem]
        var workstreams: [Workstream]
        var milestones: [Milestone]
        var risks: [Milestone]
        var asOfSeq: Int?
    }

    let id: String
    var title: String
    var head: Int
    var members: [Member]
    var messages: [BoardMessage] {
        didSet {
            rebuildBoardIndex()
        }
    }
    private(set) var boardPosts: [BoardMessage]
    private(set) var knownPostSeqs: Set<Int>
    var boardRevision: Int
    var channels: [Channel]
    var systemAlerts: [SystemAlert]
    var overview: NarratorOverview?
    var isLive: Bool

    init(
        id: String,
        title: String,
        head: Int,
        members: [Member],
        messages: [BoardMessage],
        boardPosts: [BoardMessage]? = nil,
        knownPostSeqs: Set<Int>? = nil,
        boardRevision: Int = 0,
        channels: [Channel],
        systemAlerts: [SystemAlert],
        overview: NarratorOverview?,
        isLive: Bool
    ) {
        self.id = id
        self.title = title
        self.head = head
        self.members = members
        self.messages = messages
        let posts = boardPosts ?? messages.filter { !$0.isControl }
        self.boardPosts = posts
        self.knownPostSeqs = knownPostSeqs ?? Set(posts.map(\.seq))
        self.boardRevision = boardRevision
        self.channels = channels
        self.systemAlerts = systemAlerts
        self.overview = overview
        self.isLive = isLive
    }

    private mutating func rebuildBoardIndex() {
        let posts = messages.filter { !$0.isControl }
        boardPosts = posts
        knownPostSeqs = Set(posts.map(\.seq))
        boardRevision &+= 1
    }

    static func == (lhs: AgySwarmSnapshot, rhs: AgySwarmSnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.isLive == rhs.isLive
            && lhs.head == rhs.head
            && lhs.title == rhs.title
            && lhs.members == rhs.members
            && lhs.channels == rhs.channels
            && lhs.systemAlerts == rhs.systemAlerts
            && lhs.overview == rhs.overview
            && lhs.messages == rhs.messages
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Swarm") : trimmed
    }

    var postCount: Int {
        boardPosts.count
    }

    var taskWorkers: [Member] {
        members.filter { !$0.isCoordinator && !$0.isRoleWorker }
    }

    var nonKilledMembers: [Member] {
        members.filter { !$0.isKilled }
    }

    var killedMembers: [Member] {
        members.filter(\.isKilled)
    }

    var activeTaskWorkers: [Member] {
        taskWorkers.filter { $0.status == .working }
    }

    var waitingTaskWorkers: [Member] {
        taskWorkers.filter { $0.status == .waiting }
    }

    var hasActiveWorkers: Bool {
        !activeTaskWorkers.isEmpty
    }

    var hasSystemAlerts: Bool {
        !systemAlerts.isEmpty
    }

    /// Keeps Chat polling at its active 1-second pace and promotes an Idle/Done
    /// Antigravity CLI Agent's displayed status to Working while task workers
    /// actively run.
    var holdsActivePace: Bool {
        isLive && activeTaskWorkers.contains { !$0.isStuck }
    }

    var latestPost: BoardMessage? {
        boardPosts.last
    }

    /// Single-line live ticker shown on the second row of `ChatSwarmLiveBar`.
    var tickerText: String? {
        if let alert = systemAlerts.first {
            switch alert.kind {
            case .quota:
                return String(localized: "@\(alert.member) hit model limit · \(alert.detail)")
            case .error:
                return String(localized: "@\(alert.member) step failed · \(alert.detail)")
            case .stuck:
                return String(localized: "@\(alert.member) has shown no recent progress")
            }
        }
        let latest = latestPost
        if (latest == nil || latest?.isBrief == true),
            let active = activeTaskWorkers.first(where: { !($0.activity ?? "").isEmpty }),
            let activity = active.activity
        {
            return "@\(active.name) · \(activity)"
        }
        if let latest {
            let body = Self.stripLeadingMentions(latest.singleLinePreview)
            if let to = latest.recipientSummary {
                return "#\(latest.seq) \(latest.agent) → \(to): \(body)"
            }
            return "#\(latest.seq) \(latest.agent): \(body)"
        }
        if let active = activeTaskWorkers.first, let activity = active.activity, !activity.isEmpty {
            return "@\(active.name) · \(activity)"
        }
        return nil
    }

    private static func stripLeadingMentions(_ text: String) -> String {
        var words = text.split(separator: " ")[...]
        while let first = words.first, first.hasPrefix("@"), first.count > 1 {
            words.removeFirst()
        }
        let cleaned = words.joined(separator: " ")
        return cleaned.isEmpty ? text : cleaned
    }
}

// MARK: - Parsers & Rules

enum AgySwarmParser {
    static let mainChannel = "main"
    static let viewMaxBytes = 64 * 1_024
    static let stuckInterval: TimeInterval = 10 * 60
    static let stepErrorSettleInterval: TimeInterval = 60

    struct RawMember: Sendable {
        var conversationID: String
        var role: String
        var model: String
        var workspaceMode: String
        var wakeMode: String
        var waitSince: Int
        var lastReadSeq: Int
        var isKilled: Bool
        var channels: [String]?
    }

    struct RawRoster: Sendable {
        var title: String
        var members: [String: RawMember]
    }

    struct RawControl: Equatable, Sendable {
        var op: String
        var channel: String
        var topic: String
        var members: [String]
    }

    struct ExtractedBoardTokens: Equatable, Sendable {
        var mentionTokens: Set<String> = []
        var channelMentions: [String] = []
        var citedSeqs: [Int] = []
    }

    struct RawBoardLine: Equatable, Sendable {
        var seq: Int
        var agent: String
        var text: String
        var time: String
        var kind: String?
        var channel: String
        var control: RawControl?
        var tokens: ExtractedBoardTokens
        var parsedTimestamp: Date?
        var isMarkedDone: Bool
        var isMarkedStall: Bool
        var shouldCollapseBrief: Bool
        var lineCount: Int
        var isLongPost: Bool
        var displayTime: String?

        init(
            seq: Int,
            agent: String,
            text: String,
            time: String,
            kind: String?,
            channel: String,
            control: RawControl?
        ) {
            self.seq = seq
            self.agent = agent
            self.text = text
            self.time = time
            self.kind = kind
            self.channel = channel
            self.control = control
            let isControl = control != nil
            let isBrief = kind == "brief"
            self.tokens = isControl ? ExtractedBoardTokens() : AgySwarmParser.extractBoardTokens(in: text)
            self.parsedTimestamp = AgySwarmParser.parseBoardTimestamp(time)
            self.isMarkedDone = !isControl && !isBrief && AgySwarmSnapshot.BoardMessage.hasLeadingTag("[done]", in: text)
            self.isMarkedStall = !isControl && !isBrief && AgySwarmSnapshot.BoardMessage.hasLeadingTag("[stall]", in: text)
            self.shouldCollapseBrief = isBrief && AgySwarmSnapshot.BoardMessage.exceedsBriefPreviewLimits(text)
            let computedLines = isControl ? 0 : AgySwarmSnapshot.BoardMessage.countLines(in: text)
            self.lineCount = computedLines
            self.isLongPost = !isControl && AgySwarmSnapshot.BoardMessage.exceedsCompactPreviewLimits(text, lineCount: computedLines)
            self.displayTime = AgySwarmSnapshot.BoardMessage.formatClockTime(time)
        }
    }

    static func isRoleWorkerName(_ name: String) -> Bool {
        name.wholeMatch(of: #/^(?:narrator|monitor)(?:-\d+)?$/#) != nil
    }

    static func effectiveRole(name: String, storedRole: String) -> String {
        if !storedRole.isEmpty, storedRole != "worker" {
            return storedRole
        }
        if let match = name.wholeMatch(of: #/^(narrator|monitor)(?:-\d+)?$/#) {
            return String(match.1)
        }
        return storedRole.isEmpty ? "worker" : storedRole
    }

    static func parseRoster(_ data: Data) -> RawRoster? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let top) = root
        else { return nil }
        let title = top["title"]?.stringValue ?? ""
        var members: [String: RawMember] = [:]
        if case .object(let rawMembers)? = top["members"] {
            for (name, value) in rawMembers {
                guard case .object(let fields) = value else { continue }
                let conv = fields["conversation_id"]?.stringValue ?? ""
                let role = fields["role"]?.stringValue ?? ""
                let model =
                    fields["model"]?.stringValue
                    ?? fields["applied_model"]?.stringValue
                    ?? fields["desired_model"]?.stringValue
                    ?? ""
                let ws = fields["workspace_mode"]?.stringValue ?? "inherit"
                let wake = fields["wake_mode"]?.stringValue ?? ""
                let waitSince = intValue(fields["wait_since"]) ?? 0
                let lastRead = intValue(fields["last_read_seq"]) ?? 0
                let killed =
                    fields["killed"] == .bool(true)
                    || fields["desired_state"]?.stringValue == "KILLED"
                    || fields["phase"]?.stringValue == "KILLED"
                var chans: [String]?
                if case .array(let items)? = fields["channels"] {
                    chans = items.compactMap(\.stringValue)
                }
                members[name] = RawMember(
                    conversationID: conv, role: role, model: model, workspaceMode: ws, wakeMode: wake,
                    waitSince: waitSince, lastReadSeq: lastRead, isKilled: killed, channels: chans)
            }
        }
        return RawRoster(title: title, members: members)
    }

    static func parseBoardLine(_ line: ChatLine) -> RawBoardLine? {
        guard !line.isTruncated,
            let json = try? JSONDecoder().decode(JSONValue.self, from: line.data),
            case .object(let fields) = json
        else { return nil }
        let seq = intValue(fields["seq"]) ?? 0
        let agent = fields["agent"]?.stringValue ?? ""
        let text = fields["text"]?.stringValue ?? ""
        let time = fields["time"]?.stringValue ?? ""
        let kind = fields["kind"]?.stringValue
        let rawChannel = fields["channel"]?.stringValue ?? ""
        let channel = rawChannel.isEmpty ? mainChannel : rawChannel
        var control: RawControl?
        if case .object(let ctrl)? = fields["control"] {
            let op = ctrl["op"]?.stringValue ?? ""
            let ctrlChannel = ctrl["channel"]?.stringValue ?? ""
            let topic = ctrl["topic"]?.stringValue ?? ""
            let ctrlMembers: [String]
            if case .array(let arr)? = ctrl["members"] {
                ctrlMembers = arr.compactMap(\.stringValue)
            } else {
                ctrlMembers = []
            }
            control = RawControl(op: op, channel: ctrlChannel, topic: topic, members: ctrlMembers)
        }
        return RawBoardLine(
            seq: seq, agent: agent, text: text, time: time, kind: kind, channel: channel, control: control)
    }

    static func parseOverview(_ data: Data) -> AgySwarmSnapshot.NarratorOverview? {
        guard data.count <= viewMaxBytes,
            let root = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let fields) = root
        else { return nil }
        let headline = String((fields["headline"]?.stringValue ?? "").prefix(400))
        var phase: AgySwarmSnapshot.NarratorOverview.Phase?
        if case .object(let phaseObj)? = fields["phase"],
            let index = intValue(phaseObj["index"]),
            let total = intValue(phaseObj["total"]),
            total > 0
        {
            let label = String((phaseObj["label"]?.stringValue ?? "").prefix(120))
            phase = .init(label: label, index: max(0, min(index, total)), total: total)
        }

        var attention: [AgySwarmSnapshot.NarratorOverview.AttentionItem] = []
        if case .array(let items)? = fields["attention"] {
            for (idx, item) in items.prefix(16).enumerated() {
                guard case .object(let obj) = item else { continue }
                let title = (obj["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let id = obj["id"]?.stringValue ?? "att-\(idx)"
                let kind = obj["kind"]?.stringValue ?? "fyi"
                let severity = obj["severity"]?.stringValue ?? "med"
                let why = obj["why"]?.stringValue ?? ""
                attention.append(
                    .init(
                        id: id, kind: kind, severity: severity,
                        title: String(title.prefix(200)), why: String(why.prefix(400))))
            }
        }

        var workstreams: [AgySwarmSnapshot.NarratorOverview.Workstream] = []
        if case .array(let items)? = fields["workstreams"] {
            for (idx, item) in items.prefix(24).enumerated() {
                guard case .object(let obj) = item else { continue }
                let title = (obj["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let id = obj["id"]?.stringValue ?? "ws-\(idx)"
                let state = obj["state"]?.stringValue ?? "active"
                let note = obj["note"]?.stringValue ?? ""
                let owners: [String]
                if case .array(let rawOwners)? = obj["owners"] {
                    owners = rawOwners.compactMap(\.stringValue)
                } else {
                    owners = []
                }
                workstreams.append(
                    .init(
                        id: id, title: String(title.prefix(200)), owners: owners, state: state,
                        note: String(note.prefix(320))))
            }
        }

        func parseMilestones(_ key: String, prefix: String) -> [AgySwarmSnapshot.NarratorOverview.Milestone] {
            guard case .array(let items)? = fields[key] else { return [] }
            return items.prefix(16).enumerated().compactMap { idx, item in
                guard case .object(let obj) = item else { return nil }
                let text = (obj["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let id = obj["id"]?.stringValue ?? "\(prefix)-\(idx)"
                return .init(id: id, text: String(text.prefix(260)))
            }
        }

        let milestones = parseMilestones("milestones", prefix: "ms")
        let risks = parseMilestones("risks", prefix: "rk")
        let asOfSeq = intValue(fields["as_of_seq"])

        guard !headline.isEmpty || phase != nil || !attention.isEmpty || !workstreams.isEmpty
            || !milestones.isEmpty || !risks.isEmpty
        else { return nil }

        return AgySwarmSnapshot.NarratorOverview(
            headline: headline, phase: phase, attention: attention, workstreams: workstreams,
            milestones: milestones, risks: risks, asOfSeq: asOfSeq)
    }

    // MARK: Mentions & Channels

    struct CompiledBoardHistory: Sendable {
        var channels: [AgySwarmSnapshot.Channel]
        var activeChannelNames: Set<String>
        var messages: [AgySwarmSnapshot.BoardMessage]
        var boardPosts: [AgySwarmSnapshot.BoardMessage]
        var knownPostSeqs: Set<Int>
        var postCounts: [String: (posts: Int, lastSeq: Int)]
        var postsAreMonotonic: Bool
    }

    static func extractBoardTokens(in text: String) -> ExtractedBoardTokens {
        guard text.utf8.contains(UInt8(ascii: "@")) || text.utf8.contains(UInt8(ascii: "#")) else {
            return ExtractedBoardTokens()
        }
        let reservedChannels: Set<String> = ["main", "all", "here"]
        var result = ExtractedBoardTokens()
        var cursor = text.startIndex
        while let sigil = text[cursor...].firstIndex(where: { $0 == "@" || $0 == "#" }) {
            let ch = text[sigil]
            if ch == "@" {
                let validStart =
                    sigil == text.startIndex || !isNameCharacter(text[text.index(before: sigil)])
                let afterAt = text.index(after: sigil)
                if validStart, afterAt < text.endIndex {
                    if text[afterAt] == "#" {
                        let chanStart = text.index(after: afterAt)
                        var chanEnd = chanStart
                        var count = 0
                        while chanEnd < text.endIndex, count <= 24, isChannelTokenCharacter(text[chanEnd]) {
                            chanEnd = text.index(after: chanEnd)
                            count += 1
                        }
                        if count >= 1, count <= 24,
                            let first = text[chanStart].asciiValue,
                            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first | 0x20),
                            chanEnd == text.endIndex || !isNameCharacter(text[chanEnd])
                        {
                            let lower = text[chanStart..<chanEnd].lowercased()
                            if !reservedChannels.contains(lower), !result.channelMentions.contains(lower) {
                                result.channelMentions.append(lower)
                            }
                        }
                        cursor = chanEnd
                        continue
                    } else {
                        var nameEnd = afterAt
                        while nameEnd < text.endIndex, isNameCharacter(text[nameEnd]) {
                            nameEnd = text.index(after: nameEnd)
                        }
                        if nameEnd > afterAt {
                            result.mentionTokens.insert(text[afterAt..<nameEnd].lowercased())
                            cursor = nameEnd
                            continue
                        }
                    }
                }
                cursor = afterAt
            } else {
                let validStart =
                    sigil == text.startIndex || !isCitationPrefixCharacter(text[text.index(before: sigil)])
                let afterHash = text.index(after: sigil)
                if validStart, afterHash < text.endIndex {
                    var digitEnd = afterHash
                    var digitCount = 0
                    while digitEnd < text.endIndex, text[digitEnd].isNumber {
                        digitEnd = text.index(after: digitEnd)
                        digitCount += 1
                    }
                    if digitCount >= 1, digitCount <= 5,
                        let seq = Int(text[afterHash..<digitEnd]),
                        !result.citedSeqs.contains(seq)
                    {
                        result.citedSeqs.append(seq)
                    }
                    if digitEnd > afterHash {
                        cursor = digitEnd
                        continue
                    }
                }
                cursor = afterHash
            }
        }
        return result
    }

    static func resolveMentions(
        from extracted: Set<String>, in rawText: String, rosterNames: [String]
    ) -> (mentions: [String], all: Bool) {
        guard !extracted.isEmpty else { return ([], false) }
        var fallbackLower: String?
        let matched = rosterNames.filter { name in
            let lowerName = name.lowercased()
            if lowerName.allSatisfy(isNameCharacter) {
                if extracted.contains(lowerName) { return true }
                if let dash = lowerName.lastIndex(of: "-") {
                    let suffix = lowerName[lowerName.index(after: dash)...]
                    if !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        let prefix = String(lowerName[..<dash])
                        if !prefix.isEmpty, extracted.contains(prefix) { return true }
                    }
                }
                return false
            }
            let lower = fallbackLower ?? {
                let computed = rawText.lowercased()
                fallbackLower = computed
                return computed
            }()
            return matchesNamedToken(in: lower, token: lowerName)
        }
        return (matched, extracted.contains("all"))
    }

    static func mentions(in text: String, rosterNames: [String]) -> (mentions: [String], all: Bool) {
        let extracted = extractBoardTokens(in: text).mentionTokens
        return resolveMentions(from: extracted, in: text, rosterNames: rosterNames)
    }

    static func channelMentions(in text: String) -> [String] {
        extractBoardTokens(in: text).channelMentions
    }

    private static func matchesNamedToken(in lowerText: String, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var searchStart = lowerText.startIndex
        while let atRange = lowerText[searchStart...].range(of: "@") {
            let atIndex = atRange.lowerBound
            defer { searchStart = lowerText.index(after: atIndex) }
            if atIndex > lowerText.startIndex {
                let prev = lowerText[lowerText.index(before: atIndex)]
                if isNameCharacter(prev) { continue }
            }
            let afterAt = lowerText.index(after: atIndex)
            guard lowerText[afterAt...].hasPrefix(token) else { continue }
            let end = lowerText.index(afterAt, offsetBy: token.count)
            if end == lowerText.endIndex || !isNameCharacter(lowerText[end]) {
                return true
            }
        }
        return false
    }

    private static func isNameCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "-"
    }

    private static func isChannelTokenCharacter(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        let lower = ascii | 0x20
        return (lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z"))
            || (ascii >= UInt8(ascii: "0") && ascii <= UInt8(ascii: "9"))
            || ascii == UInt8(ascii: "-")
    }

    private static func isCitationPrefixCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    static func channelRegistry(from rawLines: [RawBoardLine]) -> [AgySwarmSnapshot.Channel] {
        var order: [String] = []
        var byName: [String: AgySwarmSnapshot.Channel] = [:]
        for line in rawLines {
            guard let ctrl = line.control, !ctrl.channel.isEmpty, ctrl.channel != mainChannel else { continue }
            if ctrl.op == "create", byName[ctrl.channel] == nil {
                order.append(ctrl.channel)
                byName[ctrl.channel] = AgySwarmSnapshot.Channel(
                    name: ctrl.channel, topic: ctrl.topic, createdBy: line.agent, isArchived: false)
            } else if ctrl.op == "archive" {
                if byName[ctrl.channel] == nil {
                    order.append(ctrl.channel)
                    byName[ctrl.channel] = AgySwarmSnapshot.Channel(
                        name: ctrl.channel, topic: "", createdBy: "", isArchived: true)
                } else {
                    byName[ctrl.channel]?.isArchived = true
                }
            }
        }
        return order.compactMap { byName[$0] }
    }

    static func buildBoardMessage(
        from raw: RawBoardLine,
        at index: Int,
        rosterNames: [String],
        activeChannelNames: Set<String>,
        postCounts: inout [String: (posts: Int, lastSeq: Int)]
    ) -> AgySwarmSnapshot.BoardMessage {
        let seq = raw.seq > 0 ? raw.seq : (index + 1)
        if raw.control != nil {
            return AgySwarmSnapshot.BoardMessage(
                seq: seq, agent: raw.agent, text: raw.text, time: raw.time, timestamp: raw.parsedTimestamp,
                channel: raw.channel, isBrief: false, isControl: true, mentions: [],
                channelMentions: [], mentionsAll: false, rawCitedSeqs: [],
                shouldCollapseBrief: false, lineCount: 0, isLongPost: false,
                isMarkedDone: false, isMarkedStall: false,
                displayTime: raw.displayTime)
        }
        let parsedMentions = resolveMentions(
            from: raw.tokens.mentionTokens, in: raw.text, rosterNames: rosterNames)
        let chanMentions = raw.tokens.channelMentions.filter { activeChannelNames.contains($0) }
        var current = postCounts[raw.agent] ?? (posts: 0, lastSeq: 0)
        current.posts += 1
        current.lastSeq = seq
        postCounts[raw.agent] = current
        return AgySwarmSnapshot.BoardMessage(
            seq: seq, agent: raw.agent, text: raw.text, time: raw.time, timestamp: raw.parsedTimestamp,
            channel: raw.channel, isBrief: raw.kind == "brief", isControl: false,
            mentions: parsedMentions.mentions, channelMentions: chanMentions,
            mentionsAll: parsedMentions.all, rawCitedSeqs: raw.tokens.citedSeqs,
            shouldCollapseBrief: raw.shouldCollapseBrief, lineCount: raw.lineCount,
            isLongPost: raw.isLongPost, isMarkedDone: raw.isMarkedDone,
            isMarkedStall: raw.isMarkedStall, displayTime: raw.displayTime)
    }

    static func compileBoardHistory(
        rawLines: [RawBoardLine], rosterNames: [String]
    ) -> CompiledBoardHistory {
        let channels = channelRegistry(from: rawLines)
        let activeChannelNames = Set(channels.filter { !$0.isArchived }.map(\.name))
        var postCounts: [String: (posts: Int, lastSeq: Int)] = [:]
        var messages: [AgySwarmSnapshot.BoardMessage] = []
        var boardPosts: [AgySwarmSnapshot.BoardMessage] = []
        var knownPostSeqs: Set<Int> = []
        messages.reserveCapacity(rawLines.count)
        boardPosts.reserveCapacity(rawLines.count)
        knownPostSeqs.reserveCapacity(rawLines.count)
        var postsAreMonotonic = true
        var lastPostSeq = Int.min

        for (idx, raw) in rawLines.enumerated() {
            let msg = buildBoardMessage(
                from: raw, at: idx, rosterNames: rosterNames, activeChannelNames: activeChannelNames,
                postCounts: &postCounts)
            messages.append(msg)
            if !msg.isControl {
                if msg.seq <= lastPostSeq {
                    postsAreMonotonic = false
                }
                lastPostSeq = msg.seq
                boardPosts.append(msg)
                knownPostSeqs.insert(msg.seq)
            }
        }
        return CompiledBoardHistory(
            channels: channels, activeChannelNames: activeChannelNames, messages: messages,
            boardPosts: boardPosts, knownPostSeqs: knownPostSeqs, postCounts: postCounts,
            postsAreMonotonic: postsAreMonotonic)
    }

    static func unreadPostCount(
        for name: String, lastReadSeq: Int, in history: CompiledBoardHistory
    ) -> Int {
        let posts = history.boardPosts
        guard !posts.isEmpty else { return 0 }
        if history.postsAreMonotonic {
            var low = 0
            var high = posts.count
            while low < high {
                let mid = (low + high) / 2
                if posts[mid].seq > lastReadSeq {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            guard low < posts.count else { return 0 }
            var unread = 0
            for idx in low..<posts.count where posts[idx].agent != name {
                unread += 1
            }
            return unread
        }
        return posts.count { $0.seq > lastReadSeq && $0.agent != name }
    }

    static func buildSnapshot(
        id: String,
        roster: RawRoster,
        rawLines: [RawBoardLine],
        transcripts: [String: AgySwarmMemberTranscript],
        overview: AgySwarmSnapshot.NarratorOverview?,
        isLive: Bool,
        now: Date
    ) -> AgySwarmSnapshot {
        let names = roster.members.keys.sorted()
        let compiled = compileBoardHistory(rawLines: rawLines, rosterNames: names)
        return buildSnapshot(
            id: id, roster: roster, sortedNames: names, compiledBoard: compiled, boardRevision: 0,
            transcripts: transcripts, overview: overview, isLive: isLive, now: now)
    }

    static func buildSnapshot(
        id: String,
        roster: RawRoster,
        sortedNames names: [String],
        compiledBoard: CompiledBoardHistory,
        boardRevision: Int,
        transcripts: [String: AgySwarmMemberTranscript],
        overview: AgySwarmSnapshot.NarratorOverview?,
        isLive: Bool,
        now: Date
    ) -> AgySwarmSnapshot {
        let head = compiledBoard.messages.last?.seq ?? 0
        var systemAlerts: [AgySwarmSnapshot.SystemAlert] = []

        var builtMembers: [AgySwarmSnapshot.Member] = names.compactMap { name in
            guard let raw = roster.members[name] else { return nil }
            let role = effectiveRole(name: name, storedRole: raw.role)
            let tr = transcripts[name]
            let failure = isLive ? tr?.failure(at: now) : nil
            let baseStatus: AgySwarmSnapshot.MemberStatus
            if raw.isKilled {
                baseStatus = .killed
            } else if failure != nil {
                baseStatus = .error
            } else if let tr, tr.hasSteps {
                baseStatus = tr.isTurnEnded ? .waiting : .working
            } else if raw.wakeMode == "mentions" || raw.wakeMode == "anything" {
                baseStatus = .waiting
            } else {
                baseStatus = .working
            }

            let isStuck: Bool
            if isLive, baseStatus == .working, let mtime = tr?.modificationDate {
                isStuck = now.timeIntervalSince(mtime) > stuckInterval
            } else {
                isStuck = false
            }

            let counts = compiledBoard.postCounts[name] ?? (posts: 0, lastSeq: 0)
            let unread = unreadPostCount(for: name, lastReadSeq: raw.lastReadSeq, in: compiledBoard)
            let member = AgySwarmSnapshot.Member(
                name: name,
                conversationID: raw.conversationID,
                role: role,
                model: raw.model,
                workspaceMode: raw.workspaceMode,
                wakeMode: raw.wakeMode,
                status: isLive || raw.isKilled ? baseStatus : .waiting,
                isKilled: raw.isKilled,
                isStuck: isStuck,
                steps: tr?.steps ?? 0,
                posts: counts.posts,
                unread: max(0, unread),
                lastReadSeq: raw.lastReadSeq,
                lastPostSeq: counts.lastSeq,
                activity: baseStatus == .working ? tr?.activity : nil,
                failure: failure,
                channels: raw.channels ?? [])

            if isLive, !member.isKilled, !member.isRoleWorker {
                if let failure {
                    systemAlerts.append(
                        .init(
                            id: "sys-\(name)-\(failure.kind.rawValue)",
                            kind: failure.kind == .quota ? .quota : .error,
                            member: name,
                            conversationID: raw.conversationID,
                            detail: failure.detail))
                } else if isStuck {
                    systemAlerts.append(
                        .init(
                            id: "sys-\(name)-stuck",
                            kind: .stuck,
                            member: name,
                            conversationID: raw.conversationID,
                            detail: String(localized: "No transcript updates for over 10 minutes.")))
                }
            }
            return member
        }

        builtMembers.sort { lhs, rhs in
            let lhsRank = memberSortRank(lhs)
            let rhsRank = memberSortRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        systemAlerts.sort { lhs, rhs in
            let lhsRank = lhs.kind == .stuck ? 1 : 0
            let rhsRank = rhs.kind == .stuck ? 1 : 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.member.localizedStandardCompare(rhs.member) == .orderedAscending
        }

        return AgySwarmSnapshot(
            id: id, title: roster.title, head: head, members: builtMembers,
            messages: compiledBoard.messages, boardPosts: compiledBoard.boardPosts,
            knownPostSeqs: compiledBoard.knownPostSeqs, boardRevision: boardRevision,
            channels: compiledBoard.channels, systemAlerts: systemAlerts, overview: overview,
            isLive: isLive)
    }

    private static func memberSortRank(_ member: AgySwarmSnapshot.Member) -> Int {
        if member.isCoordinator { return 0 }
        switch member.status {
        case .error: return 1
        case .working: return 2
        case .waiting: return member.isRoleWorker ? 4 : 3
        case .killed: return 5
        }
    }

    private static let gregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func parseBoardTimestamp(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let local = parseLocalBoardDateTime(raw) {
            return local
        }
        let isoCandidate = raw.replacingOccurrences(of: " ", with: "T")
        return try? Date(isoCandidate, strategy: .iso8601)
    }

    /// Fast zero-formatter parse of `yyyy-MM-dd HH:mm:ss` (the standard `board.jsonl` clock format).
    private static func parseLocalBoardDateTime(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8)
        guard bytes.count == 19,
            bytes[4] == UInt8(ascii: "-"),
            bytes[7] == UInt8(ascii: "-"),
            bytes[10] == UInt8(ascii: " ") || bytes[10] == UInt8(ascii: "T"),
            bytes[13] == UInt8(ascii: ":"),
            bytes[16] == UInt8(ascii: ":")
        else { return nil }
        func digits(_ range: ClosedRange<Int>) -> Int? {
            var value = 0
            for idx in range {
                let b = bytes[idx]
                guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(b - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = digits(0...3),
            let month = digits(5...6), (1...12).contains(month),
            let day = digits(8...9), (1...31).contains(day),
            let hour = digits(11...12), (0...23).contains(hour),
            let minute = digits(14...15), (0...59).contains(minute),
            let second = digits(17...18), (0...60).contains(second)
        else { return nil }
        var calendar = gregorianCalendar
        calendar.timeZone = .current
        return DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ).date
    }

    fileprivate static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let n)?:
            return Int(exactly: n)
        case .string(let s)?:
            return Int(s)
        default:
            return nil
        }
    }
}

// MARK: - Incremental Member Transcript Summary

/// Summarizes one Swarm member's compact `transcript.jsonl` (`steps`, whether
/// its current turn has stopped, its current tool/thinking activity, and any
/// settled error or quota failure), mirroring `swarm_board/main.mjs`.
struct AgySwarmMemberTranscript: Sendable {
    private var seenSteps: Set<Int> = []
    private var lineCount = 0
    private var highestStepIndex = -1
    private var latestPlannerCalls: [AgyStep.Call] = []
    private var resultsSinceLatestPlanner: [AgyStep.Status] = []
    private var hasSeenPlannerInCurrentTurn = false
    private var latestStepKind: AgyStep.Kind?
    private var latestStepStatus: AgyStep.Status?
    private var latestStepError: String?
    private(set) var activity: String?
    var modificationDate: Date?

    var hasSteps: Bool { lineCount > 0 }

    var steps: Int {
        max(lineCount, highestStepIndex + 1)
    }

    /// Mirrors `turnEnded` in `swarm_board/main.mjs`: a member's run has stopped
    /// when the newest step is a `PLANNER_RESPONSE` with no tool calls, or the
    /// `GENERIC` results of a tool batch containing `swarm_wait` whose own
    /// result is `DONE`.
    var isTurnEnded: Bool {
        guard latestStepKind == .plannerResponse || latestStepKind == .toolResult else {
            return false
        }
        guard hasSeenPlannerInCurrentTurn else { return false }
        if latestPlannerCalls.isEmpty {
            return resultsSinceLatestPlanner.isEmpty && latestStepKind == .plannerResponse
        }
        guard let waitIndex = latestPlannerCalls.firstIndex(where: { $0.name == "swarm_wait" }),
            resultsSinceLatestPlanner.count >= latestPlannerCalls.count
        else { return false }
        return resultsSinceLatestPlanner[waitIndex] == .done
    }

    mutating func apply(_ lines: [ChatLine]) {
        for line in lines {
            guard let step = AgyStep.decode(line) else { continue }
            if let index = step.stepIndex {
                guard seenSteps.insert(index).inserted else { continue }
                highestStepIndex = max(highestStepIndex, index)
            }
            lineCount += 1
            latestStepKind = step.kind
            latestStepStatus = step.status
            latestStepError = step.error

            switch step.kind {
            case .userInput:
                hasSeenPlannerInCurrentTurn = false
                latestPlannerCalls = []
                resultsSinceLatestPlanner = []
                activity = nil
            case .plannerResponse:
                hasSeenPlannerInCurrentTurn = true
                latestPlannerCalls = step.calls
                resultsSinceLatestPlanner = []
                if step.calls.contains(where: { $0.name == "swarm_wait" }) {
                    activity = nil
                } else if let toolLabel = step.calls.compactMap(Self.describeToolCall).last {
                    activity = toolLabel
                } else if let heading = Self.thinkingHeading(in: step.thinking) {
                    activity = heading
                } else if step.calls.isEmpty {
                    activity = nil
                }
            case .toolResult:
                resultsSinceLatestPlanner.append(step.status)
                if isTurnEnded {
                    activity = nil
                }
            case .systemMessage:
                if isTurnEnded {
                    hasSeenPlannerInCurrentTurn = false
                    latestPlannerCalls = []
                    resultsSinceLatestPlanner = []
                    activity = nil
                }
            case .errorMessage, .checkpoint, .ephemeral, .unknown:
                break
            }
        }
    }

    func failure(at now: Date) -> AgySwarmSnapshot.Failure? {
        guard let latestStepKind else { return nil }
        let isModelError = latestStepKind == .errorMessage
        let isSettledToolError: Bool
        if latestStepStatus == .error, let mtime = modificationDate {
            isSettledToolError = now.timeIntervalSince(mtime) >= AgySwarmParser.stepErrorSettleInterval
        } else {
            isSettledToolError = false
        }
        guard isModelError || isSettledToolError else { return nil }
        let rawText = (latestStepError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = rawText.isEmpty ? (isModelError ? "Model error" : "Step failed") : Self.oneLine(rawText, maxLength: 180)
        let isQuota = detail.range(
            of: #"RESOURCE_EXHAUSTED|quota|\b429\b|exhausted your capacity|rate.?limit"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        return AgySwarmSnapshot.Failure(kind: isQuota ? .quota : .error, detail: detail)
    }

    private static func describeToolCall(_ call: AgyStep.Call) -> String? {
        switch call.name {
        case "": return nil
        case "swarm_wait": return String(localized: "Waiting for posts")
        case "read_board": return String(localized: "Reading the board")
        case "post_message": return String(localized: "Posting to the board")
        default: break
        }
        if let summary = stringArg("toolSummary", in: call.args) ?? stringArg("toolAction", in: call.args),
            !summary.isEmpty
        {
            return oneLine(summary)
        }
        if let path = stringArg("Path", in: call.args)
            ?? stringArg("AbsolutePath", in: call.args)
            ?? stringArg("TargetFile", in: call.args),
            !path.isEmpty
        {
            let base = URL(fileURLWithPath: path).lastPathComponent
            switch call.name {
            case "read_file", "view_file": return "Read \(base)"
            case "write_file", "write_to_file": return "Write \(base)"
            case "edit_file", "replace_file_content", "multi_replace_file_content": return "Edit \(base)"
            default: break
            }
        }
        if (call.name == "grep_search" || call.name == "codebase_search" || call.name == "code_search"),
            let query = stringArg("Query", in: call.args), !query.isEmpty
        {
            return oneLine("Search \(query)")
        }
        if call.name == "swarm", let action = stringArg("action", in: call.args) {
            let target = stringArg("name", in: call.args) ?? ""
            return oneLine("swarm \(action) \(target)")
        }
        return call.name
    }

    /// Reads an argument from either `transcript_full.jsonl` (decoded JSON string)
    /// or `transcript.jsonl` (JSON-quoted string value).
    private static func stringArg(_ key: String, in args: JSONValue?) -> String? {
        guard let raw = args?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        if raw.count >= 2, raw.first == "\"", raw.last == "\"",
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(String.self, from: data)
        {
            return decoded
        }
        return raw
    }

    private static func thinkingHeading(in thinking: String?) -> String? {
        guard let thinking, !thinking.isEmpty else { return nil }
        var latest: String?
        for rawLine in thinking.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 7, trimmed.hasPrefix("**"), trimmed.hasSuffix("**") {
                let inner = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty, !inner.contains("*") {
                    latest = oneLine(String(inner))
                }
            }
        }
        return latest
    }

    private static func oneLine(_ text: String, maxLength: Int = 96) -> String {
        let cleaned = text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
