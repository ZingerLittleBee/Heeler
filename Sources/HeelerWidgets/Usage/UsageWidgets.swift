import AppIntents
import SwiftUI
import WidgetKit

/// Estimated API cost or Token Usage for a range, on All Hosts or one Host.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: UsageWidgetSnapshotStore.usageKind, intent: UsageWidgetIntent.self,
            provider: UsageWidgetProvider()
        ) { entry in
            UsageWidgetFamilyReader { UsageWidgetView(entry: entry, family: $0) }
                .usageWidgetBackground()
        }
        .configurationDisplayName("Usage")
        .description("Estimated API cost or Token Usage across your Hosts.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// One Host's Usage Limits and when they reset. Never merged across Hosts:
/// two Hosts may share an account, and the report carries no identity.
struct UsageLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: UsageWidgetSnapshotStore.limitsKind, intent: UsageLimitsWidgetIntent.self,
            provider: UsageLimitsWidgetProvider()
        ) { entry in
            UsageWidgetFamilyReader { UsageLimitsWidgetView(entry: entry, family: $0) }
                .usageWidgetBackground()
        }
        .configurationDisplayName("Usage Limits")
        .description("A Host’s Claude Code or Codex Usage Limits and when they reset.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// Hands the views their family, which tests cannot set in the environment.
private struct UsageWidgetFamilyReader<Content: View>: View {
    @ViewBuilder let content: (WidgetFamily) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View { content(family) }
}

extension View {
    /// The card on the Home Screen; the Lock Screen draws its own.
    fileprivate func usageWidgetBackground() -> some View {
        modifier(UsageWidgetBackground())
    }
}

private struct UsageWidgetBackground: ViewModifier {
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            content.containerBackground(for: .widget) {}
        default:
            content.containerBackground(for: .widget) {
                Color(uiColor: .secondarySystemGroupedBackground)
            }
        }
    }
}

// MARK: Timelines

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, snapshot: nil, hostID: nil, metric: .cost, range: .today)
    }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageWidgetEntry {
        entry(configuration, at: .now)
    }

    /// Redrawn when the snapshot turns stale; otherwise the app's next write
    /// reloads it.
    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        let now = Date.now
        let first = entry(configuration, at: now)
        var dates = [now]
        if let readAt = first.snapshot?.hosts.compactMap(\.readAt).min() {
            let stale = readAt.addingTimeInterval(UsageWidgetText.staleAfter)
            if stale > now { dates.append(stale) }
        }
        return Timeline(entries: dates.map { entry(configuration, at: $0) }, policy: .never)
    }

    private func entry(_ configuration: UsageWidgetIntent, at date: Date) -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: date, snapshot: UsageWidgetSnapshotStore().read(),
            hostID: configuration.scope?.hostID, metric: configuration.metric, range: configuration.range)
    }
}

struct UsageLimitsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageLimitsWidgetEntry {
        UsageLimitsWidgetEntry(date: .now, snapshot: nil, hostID: nil, program: nil)
    }

    func snapshot(for configuration: UsageLimitsWidgetIntent, in context: Context) async -> UsageLimitsWidgetEntry {
        entry(configuration, snapshot: UsageWidgetSnapshotStore().read(), at: .now)
    }

    /// Countdowns read "1h 48m", so the timeline steps each minute while a
    /// reset is under a day away and each hour otherwise, plus an entry at
    /// every reset and when the reading turns stale. It reloads at its end.
    func timeline(for configuration: UsageLimitsWidgetIntent, in context: Context) async -> Timeline<UsageLimitsWidgetEntry> {
        let now = Date.now
        let snapshot = UsageWidgetSnapshotStore().read()
        let host = configuration.host.flatMap { snapshot?.host($0.id) }
            ?? snapshot?.hosts.first { !$0.limits.isEmpty }
        let resets = (host?.limits ?? []).flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now }
        guard let soonest = resets.min() else {
            return Timeline(entries: [entry(configuration, snapshot: snapshot, at: now)], policy: .never)
        }
        let step: TimeInterval = soonest.timeIntervalSince(now) < 86_400 ? 60 : 3_600
        // Aligned to the soonest reset, so its countdown turns over on time.
        let offset = soonest.timeIntervalSince(now).truncatingRemainder(dividingBy: step)
        var dates = [now] + (0..<60).map { now.addingTimeInterval(offset + Double($0) * step) }
        let end = dates.last ?? now
        dates += resets.filter { $0 <= end }
        if let readAt = host?.readAt {
            let stale = readAt.addingTimeInterval(UsageWidgetText.staleAfter)
            if stale > now && stale <= end { dates.append(stale) }
        }
        let entries = Array(Set(dates)).sorted().map { entry(configuration, snapshot: snapshot, at: $0) }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func entry(
        _ configuration: UsageLimitsWidgetIntent, snapshot: UsageWidgetSnapshot?, at date: Date
    ) -> UsageLimitsWidgetEntry {
        UsageLimitsWidgetEntry(
            date: date, snapshot: snapshot, hostID: configuration.host?.id,
            program: configuration.program == .automatic ? nil : configuration.program.rawValue)
    }
}

// MARK: Configuration

struct UsageWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription("Estimated API cost or Token Usage across your Hosts.")

    @Parameter(title: "Scope")
    var scope: UsageScopeEntity?

    @Parameter(title: "Show", default: .cost)
    var metric: AgentUsageMetric

    @Parameter(title: "Range", default: .today)
    var range: AgentUsageRange
}

struct UsageLimitsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage Limits"
    static let description = IntentDescription("A Host’s Claude Code or Codex Usage Limits and when they reset.")

    @Parameter(title: "Host")
    var host: UsageLimitsHostEntity?

    /// Small and Lock Screen sizes show one program; larger ones show both.
    @Parameter(title: "Program", default: .automatic)
    var program: UsageLimitsProgram

    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .oneOf, [.systemMedium, .systemLarge]) {
            Summary {
                \.$host
            }
        } otherwise: {
            Summary {
                \.$host
                \.$program
            }
        }
    }
}

/// All Hosts or one Host the snapshot holds.
struct UsageScopeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scope"
    static let defaultQuery = UsageScopeQuery()
    static let allHostsID = "all"

    let id: String
    let name: String

    var hostID: UUID? { UUID(uuidString: id) }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let allHosts = UsageScopeEntity(id: allHostsID, name: "All Hosts")
}

struct UsageScopeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [UsageScopeEntity] {
        let options = suggestions()
        return identifiers.compactMap { id in options.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [UsageScopeEntity] { suggestions() }

    func defaultResult() async -> UsageScopeEntity? { .allHosts }

    private func suggestions() -> [UsageScopeEntity] {
        [.allHosts] + (UsageWidgetSnapshotStore().read()?.hosts ?? []).map {
            UsageScopeEntity(id: $0.id.uuidString, name: $0.name)
        }
    }
}

/// A Host the snapshot holds; Usage Limits have no All Hosts.
struct UsageLimitsHostEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Host"
    static let defaultQuery = UsageLimitsHostQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct UsageLimitsHostQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [UsageLimitsHostEntity] {
        let options = suggestions()
        return identifiers.compactMap { id in options.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [UsageLimitsHostEntity] { suggestions() }

    /// The first Host that reported Usage Limits.
    func defaultResult() async -> UsageLimitsHostEntity? {
        let hosts = UsageWidgetSnapshotStore().read()?.hosts ?? []
        return (hosts.first { !$0.limits.isEmpty } ?? hosts.first).map {
            UsageLimitsHostEntity(id: $0.id, name: $0.name)
        }
    }

    private func suggestions() -> [UsageLimitsHostEntity] {
        (UsageWidgetSnapshotStore().read()?.hosts ?? []).map { UsageLimitsHostEntity(id: $0.id, name: $0.name) }
    }
}

enum UsageLimitsProgram: String, AppEnum {
    /// The program closest to its limit.
    case automatic
    case claude
    case codex

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Program"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: "Automatic",
        .claude: "Claude Code",
        .codex: "Codex",
    ]
}

extension AgentUsageMetric: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .cost: "Estimated API cost",
        .tokens: "Token Usage",
    ]
}

extension AgentUsageRange: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Range"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "Today",
        .last7Days: "7 Days",
        .last30Days: "30 Days",
    ]
}
