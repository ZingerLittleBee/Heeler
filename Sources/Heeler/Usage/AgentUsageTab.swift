import SwiftUI

/// The Usage tab on an iPhone, and in an iPad window too narrow for a
/// sidebar.
struct AgentUsageTabView: View {
    let entries: [AgentUsageHostEntry]
    @Binding var scopeHostID: Host.ID?
    @Binding var metric: AgentUsageMetric
    @Binding var limitsRequested: Bool

    var body: some View {
        NavigationStack {
            AgentUsageDashboard(
                entries: entries, scopeHostID: $scopeHostID, metric: $metric, limitsRequested: $limitsRequested)
                .navigationTitle("Usage")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AgentUsageScopeMenu(entries: entries, scopeHostID: $scopeHostID)
                    }
                }
        }
    }
}

/// All Hosts or one Host. Hosts that cannot report stay listed, disabled,
/// with the reason.
struct AgentUsageScopeMenu: View {
    let entries: [AgentUsageHostEntry]
    @Binding var scopeHostID: Host.ID?
    @Environment(\.locale) private var locale

    var body: some View {
        let scope = AgentUsageScope(readings: entries.map(\.reading))
        Menu {
            Toggle(isOn: choosing(nil)) {
                Label("All Hosts", systemImage: "square.stack.3d.up")
            }
            Section {
                ForEach(scope.included) { host in
                    Toggle(isOn: choosing(host.id)) {
                        Label(host.name, systemImage: "desktopcomputer")
                        Text("\(AgentUsageStyle.cost(host.last30Days.estimatedCostUSD, locale: locale)) est. · 30 days")
                    }
                }
                // Still loading: choosable, with nothing to show yet.
                ForEach(scope.loading) { host in
                    Toggle(isOn: choosing(host.id)) {
                        Label(host.name, systemImage: "desktopcomputer")
                        Text("Loading…")
                    }
                }
            }
            if !scope.excluded.isEmpty {
                Section {
                    ForEach(scope.excluded) { host in
                        Button {} label: {
                            Label(host.name,
                                systemImage: host.reason == "Not connected" ? "wifi.slash" : "desktopcomputer")
                            Text(host.reason)
                        }
                        .disabled(true)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .accessibilityLabel("Usage scope")
        .accessibilityValue(title)
    }

    /// A menu row's checkmark: on for the current scope, and choosing it
    /// moves the scope there.
    private func choosing(_ id: Host.ID?) -> Binding<Bool> {
        Binding(get: { scopeHostID == id }, set: { if $0 { scopeHostID = id } })
    }

    private var title: String {
        scopeHostID.flatMap { id in entries.first { $0.id == id }?.name } ?? "All Hosts"
    }
}

/// An iPad sidebar's Usage list: All Hosts, then each Host with its
/// 30-day figure in the dashboard's metric and its share of the whole.
/// Hosts that cannot report are listed apart, and not chosen.
struct AgentUsageSidebar: View {
    let entries: [AgentUsageHostEntry]
    @Binding var scopeHostID: Host.ID?
    let metric: AgentUsageMetric
    @Environment(\.locale) private var locale

    private static let allHosts = "all"

    var body: some View {
        let scope = AgentUsageScope(readings: entries.map(\.reading))
        let total = scope.total(.last30Days)
        List(selection: selection) {
            Section {
                row(tag: Self.allHosts, title: "All Hosts", symbol: "server.rack",
                    subtitle: "\(scope.included.count == 1 ? "1 Host" : "\(scope.included.count.formatted()) Hosts") · \(other(total))",
                    value: value(total), share: nil)
                ForEach(scope.included) { host in
                    row(tag: host.id.uuidString, title: host.name, symbol: "desktopcomputer",
                        subtitle: "\(AgentUsageStyle.share(metric.value(of: host.last30Days), of: metric.value(of: total), locale: locale)) · \(other(host.last30Days))",
                        value: value(host.last30Days),
                        share: metric.value(of: total) > 0 ? metric.value(of: host.last30Days) / metric.value(of: total) : 0,
                        status: status(host))
                }
                ForEach(scope.loading) { host in
                    row(tag: host.id.uuidString, title: host.name, symbol: "desktopcomputer", subtitle: "Loading…",
                        value: nil, share: nil, status: .refreshing)
                }
            } header: {
                sectionHeader("\(metric == .cost ? "Estimated API cost" : "Token Usage") · Last 30 days")
            }
            if !scope.excluded.isEmpty {
                Section {
                    ForEach(scope.excluded) { host in
                        row(tag: host.id.uuidString, title: host.name,
                            symbol: host.reason == "Not connected" ? "wifi.slash" : "desktopcomputer",
                            subtitle: host.reason, value: nil, share: nil)
                            .opacity(0.5)
                            .selectionDisabled()
                    }
                } header: {
                    sectionHeader("Not included")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private enum Status { case refreshing, failed }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textCase(nil)
    }

    private func status(_ host: AgentUsageScope.IncludedHost) -> Status? {
        if host.report.refreshing == true { return .refreshing }
        return host.refreshFailure == nil ? nil : .failed
    }

    private var selectionTag: String { scopeHostID?.uuidString ?? Self.allHosts }

    private var selection: Binding<String?> {
        Binding(
            get: { selectionTag },
            set: { value in
                guard let value else { return }
                scopeHostID = value == Self.allHosts ? nil : UUID(uuidString: value)
            })
    }

    private func value(_ summary: AgentUsageReport.Summary) -> String {
        metric == .cost
            ? AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)
            : AgentUsageStyle.tokens(summary.tokens.total, locale: locale)
    }

    /// The figure the metric does not show.
    private func other(_ summary: AgentUsageReport.Summary) -> String {
        metric == .cost
            ? "\(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens"
            : "\(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)) est."
    }

    private func row(
        tag: String, title: String, symbol: String, subtitle: String, value: String?, share: Double?,
        status: Status? = nil
    ) -> some View {
        let isSelected = tag == selectionTag
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                    in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                // The selected row keeps its colors; the highlight marks it.
                HStack(alignment: .firstTextBaseline) {
                    Text(title).lineLimit(1)
                    Spacer(minLength: 8)
                    if let value {
                        Text(value).fontWeight(.semibold).monospacedDigit()
                    }
                }
                .foregroundStyle(Color.primary)
                HStack(spacing: 5) {
                    Text(subtitle).lineLimit(1)
                    switch status {
                    case .refreshing: ProgressView().controlSize(.mini)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Last refresh failed")
                    case nil: EmptyView()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
                if let share {
                    GeometryReader { proxy in
                        Capsule().fill(Color(uiColor: .tertiarySystemFill))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.secondary)
                                    .frame(width: proxy.size.width * min(max(share, 0), 1))
                            }
                    }
                    .frame(height: 3)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 4)
        .tag(tag)
        .accessibilityElement(children: .combine)
    }
}
