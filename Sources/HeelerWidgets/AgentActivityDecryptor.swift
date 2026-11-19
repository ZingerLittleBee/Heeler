import Foundation

/// Render-time view of one Live Activity update: decrypted Host details, or
/// the plaintext counts when the envelope cannot be opened.
enum AgentActivityPresentation: Equatable, Sendable {
    case detailed(details: AgentActivityDetails, counts: AgentActivityAttributes.ContentState.Counts)
    case countsOnly(counts: AgentActivityAttributes.ContentState.Counts)

    var counts: AgentActivityAttributes.ContentState.Counts {
        switch self {
        case .detailed(_, let counts), .countsOnly(let counts):
            return counts
        }
    }

    func lockScreenHostName(hostID: String, snapshot: LiveActivityHostSnapshot?) -> String? {
        if let name = snapshot?.name(forHostID: hostID), !name.isEmpty { return name }
        if case .detailed(let details, _) = self, !details.hostName.isEmpty {
            return details.hostName
        }
        return nil
    }

    var agents: [AgentActivityDetails.AgentDetail] {
        switch self {
        case .detailed(let details, _):
            return details.agents
        case .countsOnly:
            return []
        }
    }

    /// Reserve the Host heading before fitting complete linked Agent entries.
    func lockScreenAgents(
        isStale: Bool, hasHeader: Bool = true
    ) -> [AgentActivityDetails.AgentDetail] {
        let total = counts.total
        guard total > 0 else { return [] }
        let candidates = Array(agents.prefix(min(total, 4)))
        guard !candidates.isEmpty else { return [] }
        for shown in stride(from: candidates.count, through: 1, by: -1) {
            let prefix = Array(candidates.prefix(shown))
            let target = AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: shown)
            let rowHeight = prefix.reduce(0) {
                $0 + max(target, AgentActivityRowMetrics.minimumHeight(for: $1))
            }
            let captionHeight = isStale || total > shown
                ? AgentActivityRowMetrics.lockScreenCaptionHeight : 0
            let padding = AgentActivityRowMetrics.lockScreenBannerVerticalPadding * 2
            let headerHeight = hasHeader ? AgentActivityRowMetrics.lockScreenHeaderHeight : 0
            if rowHeight + padding + captionHeight + headerHeight
                <= AgentActivityRowMetrics.lockScreenHeightBudget
            {
                return prefix
            }
        }
        return Array(candidates.prefix(1))
    }

    /// Inventory beyond the drawn lock-screen rows. Zero in counts-only.
    func lockScreenOverflowCount(isStale: Bool, hasHeader: Bool = true) -> Int {
        let shown = lockScreenAgents(isStale: isStale, hasHeader: hasHeader)
        guard !shown.isEmpty else { return 0 }
        return max(0, counts.total - shown.count)
    }

    /// Trailing caption2 on the lock screen: overflow, stale notice, or both.
    func lockScreenTrailingCaption(isStale: Bool, hasHeader: Bool = true) -> String? {
        let overflow = lockScreenOverflowCount(isStale: isStale, hasHeader: hasHeader)
        switch (isStale, overflow > 0) {
        case (true, true): return String(localized: "+\(overflow) more · May be out of date")
        case (true, false): return String(localized: "May be out of date")
        case (false, true): return String(localized: "+\(overflow) more")
        case (false, false): return nil
        }
    }
}

/// What the Dynamic Island shows for one Host: every status with Agents, as
/// drawn in the Island Scenarios design (compact, minimal, landscape) and B2
/// (expanded).
struct AgentActivityIslandPresentation: Equatable, Sendable {
    /// One status that has Agents, and how many.
    struct Tally: Equatable, Sendable {
        let status: String
        let count: Int
    }

    let counts: AgentActivityAttributes.ContentState.Counts
    /// Statuses with Agents in attention order: Blocked, Done, Working.
    let tallies: [Tally]
    let hostName: String?
    /// The Host's short form, only when the catalog has two or more Hosts.
    let hostLabel: String?
    let hasMultipleHosts: Bool

    init(
        presentation: AgentActivityPresentation,
        hostID: String,
        hostSnapshot: LiveActivityHostSnapshot?
    ) {
        counts = presentation.counts
        tallies = presentation.counts.attentionItems.map { Tally(status: $0.status, count: $0.count) }
        hasMultipleHosts = (hostSnapshot?.hosts.count ?? 0) >= 2
        if hasMultipleHosts, let label = hostSnapshot?.label(forHostID: hostID), !label.isEmpty {
            hostLabel = label
        } else {
            hostLabel = nil
        }
        hostName = presentation.lockScreenHostName(hostID: hostID, snapshot: hostSnapshot)
    }

    var accessibilityLabel: String {
        var phrases = AgentActivityCopy.countPhrases(counts)
        if hasMultipleHosts, let hostName { phrases.insert(hostName, at: 0) }
        return phrases.joinedAsPhraseList
    }

    func compact(screenWidth: CGFloat) -> AgentActivityIslandCompact {
        AgentActivityIslandCompact(tallies: tallies, letter: hostLabel, screenWidth: screenWidth)
    }
}

/// The compact island. One status: its symbol left of the camera, its count
/// right. Two: one per side. Three: Blocked and Done left, Working right.
/// With two or more Hosts the Host letter sits alone on the right and the
/// statuses gather on the left. Both sides take the wider side's width and
/// hug the camera; without that, iOS pushes a narrow side to the island's
/// outer end.
struct AgentActivityIslandCompact: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        case symbol(String)
        case count(String, Int)
        case pair(String, Int)
    }

    /// One size unit sets the symbols, the numbers and the Host letter, so a
    /// step down shrinks them together.
    struct Level: Equatable, Sendable {
        let unit: CGFloat
        let showsSymbols: Bool

        static let full = Level(unit: 15, showsSymbols: true)
        static let small = Level(unit: 12.3, showsSymbols: true)
        static let numbersOnly = Level(unit: 15, showsSymbols: false)

        var symbol: CGFloat { unit * 0.93 }
        var symbolGap: CGFloat { unit * 0.17 }
        var itemSpacing: CGFloat { unit * (showsSymbols ? 0.4 : 0.6) }
        var digit: CGFloat { unit * 0.6 }
    }

    let leading: [Item]
    let trailing: [Item]
    let letter: String?
    let level: Level
    let sideWidth: CGFloat

    /// Room each side has before the status bar's clock or signal: 58 pt on
    /// 430 pt wide phones, 47 pt on 393 pt ones, from the approved drawings.
    static func sideLimit(screenWidth: CGFloat) -> CGFloat {
        screenWidth >= 420 ? 58 : 47
    }

    init(
        tallies: [AgentActivityIslandPresentation.Tally], letter: String?, screenWidth: CGFloat
    ) {
        var leading: [Item]
        var trailing: [Item]
        if letter != nil, tallies.count <= 2 {
            leading = tallies.map { .pair($0.status, $0.count) }
            trailing = []
        } else {
            switch tallies.count {
            case 1:
                leading = [.symbol(tallies[0].status)]
                trailing = [.count(tallies[0].status, tallies[0].count)]
            case 2:
                leading = [.pair(tallies[0].status, tallies[0].count)]
                trailing = [.pair(tallies[1].status, tallies[1].count)]
            default:
                leading = tallies.prefix(2).map { .pair($0.status, $0.count) }
                trailing = tallies.dropFirst(2).map { .pair($0.status, $0.count) }
            }
        }
        let limit = Self.sideLimit(screenWidth: screenWidth)
        let level = [Level.full, .small, .numbersOnly].first {
            Self.width(leading: leading, trailing: trailing, letter: letter, at: $0) <= limit
        } ?? .numbersOnly
        if !level.showsSymbols {
            leading = leading.map(\.numberOnly)
            trailing = trailing.map(\.numberOnly)
        }
        self.leading = leading
        self.trailing = trailing
        self.letter = letter
        self.level = level
        sideWidth = Self.width(leading: leading, trailing: trailing, letter: letter, at: level)
    }

    private static func width(
        leading: [Item], trailing: [Item], letter: String?, at level: Level
    ) -> CGFloat {
        var trailingWidth = width(of: trailing, at: level)
        if let letter {
            trailingWidth += (trailing.isEmpty ? 0 : level.itemSpacing) + letterWidth(letter, at: level)
        }
        return max(width(of: leading, at: level), trailingWidth)
    }

    private static func width(of items: [Item], at level: Level) -> CGFloat {
        items.reduce(0) { $0 + $1.width(at: level) }
            + CGFloat(max(0, items.count - 1)) * level.itemSpacing
    }

    /// The letter is plain text at the numbers' size: wide capitals, narrow
    /// lowercase, digit width otherwise.
    static func letterWidth(_ letter: String, at level: Level) -> CGFloat {
        letter.reduce(0) { width, character in
            if character == "M" || character == "W" { return width + level.unit * 0.82 }
            if character.isLowercase { return width + level.unit * 0.55 }
            return width + level.digit
        }
    }
}

extension AgentActivityIslandCompact.Item {
    var status: String {
        switch self {
        case .symbol(let status), .count(let status, _), .pair(let status, _): status
        }
    }

    var numberOnly: Self {
        switch self {
        case .pair(let status, let count): .count(status, count)
        case .symbol, .count: self
        }
    }

    func width(at level: AgentActivityIslandCompact.Level) -> CGFloat {
        switch self {
        case .symbol: level.symbol
        case .count(_, let count): CGFloat(String(count).count) * level.digit
        case .pair(_, let count):
            (level.showsSymbols ? level.symbol + level.symbolGap : 0)
                + CGFloat(String(count).count) * level.digit
        }
    }
}

/// The expanded island (B2): a card per Agent, at most three, in the order
/// the Host sent them, then the Agents left out, counted by status.
struct AgentActivityIslandExpanded: Equatable, Sendable {
    static let cardLimit = 3

    let cards: [AgentActivityDetails.AgentDetail]
    /// With cards, the Agents beyond them; counts-only, every status.
    let summary: [AgentActivityIslandPresentation.Tally]
    let total: Int

    init(presentation: AgentActivityPresentation) {
        let counts = presentation.counts
        let cards = Array(presentation.agents.prefix(Self.cardLimit))
        self.cards = cards
        total = counts.total
        summary = counts.attentionItems.compactMap { item in
            let left = item.count - cards.filter { $0.status == item.status }.count
            return left > 0 ? .init(status: item.status, count: left) : nil
        }
    }

    var isOverflow: Bool { !cards.isEmpty }
}

/// Synchronous render-time helper. Failures degrade to counts-only so a
/// view body never has to throw (nil envelope, locked Keychain before
/// first unlock, unknown kid, decrypt or payload error).
enum AgentActivityDecryptor {
    static func presentation(
        for state: AgentActivityAttributes.ContentState,
        store: NotificationKeyStore = NotificationKeyStore(),
        mirror: NotificationKeyMirror = NotificationKeyMirror()
    ) -> AgentActivityPresentation {
        #if DEBUG
            lastFailureReason = nil
        #endif
        guard let envelope = state.envelope,
            let data = try? JSONEncoder().encode(envelope),
            let kid = SealedEnvelopeCodec.peekKeyID(in: data)
        else {
            breadcrumb("no envelope or unreadable kid")
            return .countsOnly(counts: state.counts)
        }

        // The Keychain is unreachable in the locked lock-screen rendering
        // context (errSecNotAvailable); the app-group mirror is maintained
        // for exactly that gap, so a kid missing from whichever Keychain
        // records did load falls through to it as well.
        let records = (try? store.allRecords()) ?? []
        guard
            let record = records.first(where: { $0.keyID == kid })
                ?? mirror.read().first(where: { $0.keyID == kid })
        else {
            breadcrumb("kid \(kid) not among \(records.map(\.keyID)) nor mirrored")
            return .countsOnly(counts: state.counts)
        }
        let opened: AgentActivityDetails
        do {
            opened = try AgentActivityEnvelope.open(data, using: record.key)
        } catch {
            breadcrumb("open failed: \(error)")
            return .countsOnly(counts: state.counts)
        }

        return .detailed(details: opened, counts: state.counts)
    }

    /// Debug-only: why the last `presentation(for:)` in this process fell
    /// back to counts-only, for on-lock-screen diagnosis of device-only
    /// failures. Rendered by the lock-screen view in Debug builds.
    #if DEBUG
        nonisolated(unsafe) static var lastFailureReason: String?
    #endif

    /// Debug-only render-time trace into the shared app-group container, so
    /// a countsOnly fallback on a physical device can name its cause
    /// (`devicectl device copy from --domain-type appGroupDataContainer`).
    private static func breadcrumb(_ reason: String) {
        #if DEBUG
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)
            lastFailureReason = "\(reason) | group: \(container == nil ? "nil" : "ok")"
            guard let url = container else { return }
            let line = "\(Date()) \(reason)\n"
            let file = url.appendingPathComponent("activity-decrypt-debug.txt")
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        #endif
    }
}

enum AgentActivityCopy {
    /// "2 blocked": a count and its status, in the language the widget
    /// renders in. The status stays a wire token for colors and glyphs; one
    /// this build does not know reads as the Host sent it.
    static func count(_ count: Int, status: String) -> String {
        switch status {
        case "blocked": String(localized: "\(count) blocked")
        case "working":
            String(localized: "\(count) working", comment: "Count of a Host's Agents by status, including Live Activity summaries and accessibility labels.")
        case "done":
            String(localized: "\(count) done", comment: "Count of a Host's Agents by status, including Live Activity summaries and accessibility labels.")
        case "idle": String(localized: "\(count) idle")
        default: "\(count) \(status)"
        }
    }

    static func lockScreenStatus(_ status: String) -> String {
        switch status {
        case "blocked":
            String(localized: "Needs you", comment: "Live Activity Agent status. The Agent is blocked waiting for the user's input; also used for an Agent error.")
        case "working": String(localized: "Working")
        case "done": String(localized: "Agent status Done", defaultValue: "Done")
        default: status
        }
    }

    static func lockScreenCounts(_ counts: AgentActivityAttributes.ContentState.Counts) -> String {
        countPhrases(counts).joined(separator: " · ")
    }

    static func countPhrases(_ counts: AgentActivityAttributes.ContentState.Counts) -> [String] {
        counts.chipItems.map { item in
            switch item.status {
            case "blocked":
                String(localized: "\(item.count) needs you", comment: "Live Activity count of Agents waiting for the user's input. Singular: 1 needs you; plural: 2 need you.")
            default:
                count(item.count, status: item.status)
            }
        }
    }
}

extension AgentActivityAttributes.ContentState.Counts {
    /// Full eligible inventory carried in plaintext.
    var total: Int { working + blocked + done }

    /// Non-zero chips in contract urgency order (blocked, working, done).
    var chipItems: [(status: String, count: Int)] {
        var items: [(String, Int)] = []
        if blocked > 0 { items.append(("blocked", blocked)) }
        if working > 0 { items.append(("working", working)) }
        if done > 0 { items.append(("done", done)) }
        return items
    }

    /// Non-zero counts in attention order: blocked, done, working.
    var attentionItems: [(status: String, count: Int)] {
        var items: [(String, Int)] = []
        if blocked > 0 { items.append(("blocked", blocked)) }
        if done > 0 { items.append(("done", done)) }
        if working > 0 { items.append(("working", working)) }
        return items
    }
}

extension [String] {
    var joinedAsPhraseList: String {
        joined(separator: String(
            localized: ", ",
            comment: "Separates the phrases of a list, as in “Ran 2 commands, Edited 2 files”."))
    }
}
