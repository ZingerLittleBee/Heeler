import SwiftUI
import UIKit

/// Every Host's Plugin and Helper in one place (ADR 0048): what is older than
/// this app carries, one button to update all of it, and how each update went.
/// After an app update it opens by itself once, with a word on why.
struct HostUpdatesView: View {
    let store: HostUpdatesStore
    /// Opened by the app, not by the user.
    private let isPrompt: Bool
    @State private var path: [HostUpdateItem.ID]
    @Environment(\.dismiss) private var dismiss

    /// `opening` lands on one item's page, as a failed row in Host detail asks.
    init(store: HostUpdatesStore, isPrompt: Bool = false, opening: HostUpdateItem.ID? = nil) {
        self.store = store
        self.isPrompt = isPrompt
        _path = State(initialValue: opening.map { [$0] } ?? [])
    }

    var body: some View {
        let snapshot = store.snapshot
        NavigationStack(path: $path) {
            List {
                if isPrompt { hero(snapshot) }
                ForEach(snapshot.behind) { @Sendable group in
                    MainActorContent { section(group) }
                }
                upToDateSection(snapshot)
            }
            .navigationTitle(isPrompt ? "" : String(localized: "Updates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isPrompt {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(snapshot) }
            .refreshable { await store.refresh() }
            .navigationDestination(for: HostUpdateItem.ID.self) { id in
                HostUpdateDetailView(store: store, id: id)
            }
        }
        .onAppear { store.pageDidOpen() }
        .onDisappear { store.pageDidClose() }
    }

    private func hero(_ snapshot: HostUpdatesSnapshot) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("Updates for Your Hosts")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(Self.reason(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// Why the page opened unasked: what this app carries, and how many Hosts
    /// hold something older.
    static func reason(_ snapshot: HostUpdatesSnapshot) -> String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let plugin = snapshot.items.first { $0.component == .plugin }.map { "\($0.bundled)" }
        let helper = snapshot.items.first { $0.component == .helper }.map { "\($0.bundled)" }
        let carries: String
        switch (plugin, helper) {
        case (let plugin?, let helper?):
            carries = String(
                localized: "Heeler \(app) carries Heeler Plugin \(plugin) and Host Helper \(helper).",
                comment: "Opens the Updates prompt. Arguments: the app's version, then the Plugin and Helper versions it carries.")
        case (let plugin?, nil):
            carries = String(
                localized: "Heeler \(app) carries Heeler Plugin \(plugin).",
                comment: "Opens the Updates prompt. Arguments: the app's version, then the Plugin version it carries.")
        case (nil, let helper?):
            carries = String(
                localized: "Heeler \(app) carries Host Helper \(helper).",
                comment: "Opens the Updates prompt. Arguments: the app's version, then the Helper version it carries.")
        case (nil, nil):
            carries = ""
        }
        let behind = snapshot.groups.filter { group in group.items.contains(where: \.state.isOutstanding) }.count
        let count =
            behind == 0
            ? String(localized: "Your Hosts are up to date.")
            : String(
                localized: "\(behind) Hosts have older ones.",
                comment: "Closes the Updates prompt's opening line. Argument: how many Hosts hold an older Plugin or Helper.")
        return carries.isEmpty ? count : String(localized: "\(carries) \(count)")
    }

    private func section(_ group: HostUpdatesSnapshot.Group) -> some View {
        let notes = group.items.filter { $0.state.isOutstanding }.flatMap(\.notes)
        let failed = group.items.filter { $0.state.failure != nil }
        return Section {
            ForEach(group.items) { @Sendable item in
                MainActorContent {
                    HostUpdateRow(item: item, act: { store.update(item.id) }, open: { path.append(item.id) })
                }
            }
        } header: {
            Text(group.name)
        } footer: {
            if !notes.isEmpty || !failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { @Sendable note in Text(note) }
                    if let first = failed.first {
                        // One kind failed: its own steps. Both: the guide's
                        // table of what each failure asks for.
                        HostUpdateGuideLink(component: failed.count == 1 ? first.component : nil)
                            .font(.footnote)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func upToDateSection(_ snapshot: HostUpdatesSnapshot) -> some View {
        let rows = snapshot.groups.flatMap { group in
            group.items.filter { $0.state == .current }.map { (host: group.name, item: $0) }
        }
        if !rows.isEmpty {
            Section("Up to Date") {
                ForEach(rows, id: \.item.id) { @Sendable row in
                    LabeledContent {
                        Text(row.item.installed)
                    } label: {
                        Text(row.host)
                        Text("\(row.item.component.name) · \(row.item.scope)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionBar(_ snapshot: HostUpdatesSnapshot) -> some View {
        let progress = snapshot.progress
        let action = snapshot.primaryAction
        if progress != nil || action != nil || isPrompt {
            VStack(spacing: 4) {
                if let progress {
                    // The button's place and shape, with nothing to press: a
                    // disabled button fades its words past reading.
                    Button {} label: {
                        HStack(spacing: 8) {
                            // Not the button's size, which would make this
                            // bar taller than the button it stands in for.
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                "Updating \(progress.position) of \(progress.total)…",
                                comment: "Arguments: which update is running, then how many were started.")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Color(uiColor: .secondaryLabel))
                    .allowsHitTesting(false)
                    .accessibilityRemoveTraits(.isButton)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("hosts.updates.progress")
                    if isPrompt { secondary("Hide") }
                } else if let action {
                    Button {
                        store.updateAll()
                    } label: {
                        Text(action.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("hosts.updates.primary")
                    if isPrompt { secondary("Not Now") }
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("hosts.updates.done")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    /// Closes the prompt and nothing else: the card and the badge stay, and an
    /// update under way carries on.
    private func secondary(_ title: LocalizedStringKey) -> some View {
        Button {
            dismiss()
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("hosts.updates.later")
    }
}

/// A Plugin or Helper as a row: what it is, where it stands, and the one thing
/// to do about it.
struct HostUpdateRow: View {
    let item: HostUpdateItem
    /// Starts its update, retry or repair.
    let act: () -> Void
    /// Opens the whole of why it failed.
    var open: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if item.state.failure != nil, let open {
                Button(action: open) {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows why the update failed")
            } else {
                label
            }
            trailing
        }
        .accessibilityIdentifier("hosts.updates.row.\(item.component == .plugin ? "plugin" : "helper")")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.component.name)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(item.state.failure == nil ? Color.secondary : Color.hostUpdateWarning)
                // A failure is said whole: its last words are what to do.
                .lineLimit(wraps ? nil : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var wraps: Bool {
        item.state.failure != nil || item.state == .readingBack
    }

    private var subtitle: String {
        switch item.state {
        case .updateAvailable, .waiting, .updating:
            "\(item.scope) · \(item.installed) → \(item.bundled)"
        case .readingBack:
            String(localized: "The Host did not finish in time. Heeler is reading what is installed there now.")
        case .failed(let failure), .damaged(let failure):
            failure.message
        case .current, .other, .updated:
            item.scope
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .updateAvailable:
            HostUpdatePill(title: String(localized: "Update"), action: act)
        case .failed:
            HostUpdatePill(title: String(localized: "Retry"), action: act)
        case .damaged:
            HostUpdatePill(title: String(localized: "Repair"), action: act)
        case .waiting:
            Text(
                String(
                    localized: "Update waiting its turn", defaultValue: "Waiting",
                    comment: "On a Plugin or Helper row: its update starts after another on the same Host."))
                .foregroundStyle(.secondary)
        case .updating, .readingBack:
            ProgressView()
                .accessibilityLabel("Updating")
        case .updated:
            HStack(spacing: 6) {
                Text(verbatim: "\(item.bundled)")
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Updated")
            }
        case .current, .other:
            HStack(spacing: 6) {
                Text(item.installed)
                    .foregroundStyle(.secondary)
                if item.needsAttention { PluginWarningIcon() }
            }
        }
    }
}

/// The pill on a row or on the card: one thing to do, in a word.
struct HostUpdatePill: View {
    let title: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isProminent ? Color.white : Color.accentColor)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(
                    isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
                    in: Capsule())
                .contentShape(Capsule())
        }
        // Its own target inside a row that is a button or a link too.
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

/// The mark of an update on a row that used to carry a warning: blue, since
/// nothing is wrong with what is installed.
struct HostUpdateMark: View {
    var body: some View {
        Image(systemName: "arrow.up.circle.fill")
            .foregroundStyle(.tint)
            .accessibilityLabel("Update available")
    }
}

/// One Plugin or Helper on one Host: where it stands and, after a failure, all
/// of why.
struct HostUpdateDetailView: View {
    let store: HostUpdatesStore
    let id: HostUpdateItem.ID
    @State private var didCopy = false

    var body: some View {
        if let (group, item) = store.snapshot.item(id) {
            page(item, on: group)
        } else {
            ContentUnavailableView("Host removed", systemImage: "server.rack")
        }
    }

    private func page(_ item: HostUpdateItem, on group: HostUpdatesSnapshot.Group) -> some View {
        List {
            Section {
                LabeledContent("Installed", value: item.installed)
                LabeledContent("In This App", value: "\(item.bundled)")
            } header: {
                Text(verbatim: "\(group.name) · \(item.scope)")
            } footer: {
                if case .failed = item.state {
                    Text(
                        "\(item.component.name) \(item.installed) keeps working on \(group.name).",
                        comment: "Under a failed update. Arguments: Heeler Plugin or Host Helper, the version the Host holds, the Host's name.")
                }
            }
            standing(item)
        }
        .navigationTitle(item.component.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = item.state.failure {
                VStack(spacing: 4) {
                    Button {
                        store.update(item.id)
                    } label: {
                        Text(isDamaged(item) ? "Repair" : "Try Again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("hosts.updates.detail.retry")
                    Button {
                        UIPasteboard.general.string = Self.details(of: item, on: group, failure: failure)
                        didCopy = true
                    } label: {
                        Text(didCopy ? "Copied" : "Copy Details")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("hosts.updates.detail.copy")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .onChange(of: item.state) { didCopy = false }
    }

    private func isDamaged(_ item: HostUpdateItem) -> Bool {
        if case .damaged = item.state { true } else { false }
    }

    @ViewBuilder
    private func standing(_ item: HostUpdateItem) -> some View {
        switch item.state {
        case .failed(let failure), .damaged(let failure):
            Section(isDamaged(item) ? "Damaged" : "Update Failed") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.message)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = failure.detail {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("hosts.updates.detail.failure")
                HostUpdateGuideLink(component: item.component)
            }
        case .waiting, .updating, .readingBack:
            Section {
                LabeledContent {
                    ProgressView()
                } label: {
                    Text("Updating…")
                }
            }
        case .updated, .current:
            Section {
                LabeledContent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                } label: {
                    Text("Up to Date")
                }
            }
        case .updateAvailable:
            Section {
                Button("Update") { store.update(item.id) }
            }
        case .other:
            EmptyView()
        }
    }

    /// What a bug report needs: which Host, which versions, and every word of
    /// the failure.
    static func details(
        of item: HostUpdateItem, on group: HostUpdatesSnapshot.Group, failure: HostUpdateFailure
    ) -> String {
        var lines = [
            "\(group.name) · \(item.scope)",
            "\(item.component.name): \(item.installed) → \(item.bundled)",
            failure.message,
        ]
        if let detail = failure.detail { lines.append(detail) }
        return lines.joined(separator: "\n")
    }
}

/// The way on when updating from the app keeps failing: the user guide's
/// steps for doing it on the Host.
struct HostUpdateGuideLink: View {
    /// The Plugin's steps or the Helper's; nil for the guide's table of
    /// failures.
    let component: HostUpdateItem.Component?

    var body: some View {
        if let url = HostUpdateGuide.url(for: component) {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text("How to Update Manually")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                // A footer's line is too short a target on its own.
                .frame(minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityHint("Opens in your default browser")
            .accessibilityIdentifier("hosts.updates.guide")
        }
    }
}

/// The card over the Hosts list: how many updates wait, one button to run
/// them all, and how the run is going while the page is closed.
struct HostUpdatesCard: View {
    let card: HostUpdatesSnapshot.Card
    let updateAll: () -> Void
    /// Opens Updates.
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isFinished {
                summary
            } else {
                Button(action: open) {
                    summary.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Updates")
            }
            trailing
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("hosts.updates.card")
    }

    private var isFinished: Bool {
        if case .finished = card { true } else { false }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(card.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch card {
        case .available:
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
        case .updating:
            ProgressView()
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch card {
        case .available:
            HostUpdatePill(title: String(localized: "Update All"), isProminent: true, action: updateAll)
                .accessibilityIdentifier("hosts.updates.card.updateAll")
        case .updating:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        case .failed:
            HostUpdatePill(title: String(localized: "Details"), action: open)
        case .finished:
            EmptyView()
        }
    }
}

/// The tag after a Host's name on the Hosts list: updates wait there, are
/// running, or failed.
struct HostUpdateTag: View {
    let tag: HostUpdatesSnapshot.Tag

    var body: some View {
        HStack(spacing: 3) {
            if case .updates = tag {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(tint.opacity(0.16), in: Capsule())
        .fixedSize()
    }

    private var title: String {
        switch tag {
        case .updates(let count):
            String(
                localized: "\(count) Updates",
                comment: "Tag after a Host's name on the Hosts list. Argument: how many Plugin and Helper updates wait there.")
        case .updating: String(localized: "Updating…")
        case .failed: String(localized: "Update Failed")
        }
    }

    private var tint: Color {
        if case .failed = tag { .hostUpdateWarning } else { .accentColor }
    }
}

extension Color {
    /// The orange of an update that failed, as text: a failure's red is for a
    /// Host that stopped working, and this one still works. Darker on a light
    /// card, where system orange is too faint to read small.
    static let hostUpdateWarning = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.systemOrange
                : UIColor(red: 0.76, green: 0.38, blue: 0.0, alpha: 1)
        })
}

/// A request to show Updates over a page of the Hosts tab.
struct HostUpdatesRequest: Hashable, Identifiable {
    /// The item whose page it opens on, as a failed row asks; nil opens the
    /// list.
    var item: HostUpdateItem.ID?

    var id: Self { self }
}

struct HostUpdatesSheet: ViewModifier {
    let store: HostUpdatesStore?
    @Binding var request: HostUpdatesRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            if let store { HostUpdatesView(store: store, opening: request.item) }
        }
    }
}

/// Host detail's list of what Heeler installed on the Host: each Herdr TUI
/// Server's plugin, and the Helper once, however many Servers it serves.
struct HostUpdatesSection: View {
    let store: HostUpdatesStore
    let machine: HostMachine
    /// Opens Updates on one item's page.
    let openItem: (HostUpdateItem.ID) -> Void

    var body: some View {
        if let group = store.snapshot.group(machine.id) {
            Section {
                ForEach(group.items) { @Sendable item in
                    MainActorContent { row(item) }
                }
            } header: {
                HStack {
                    Text("Plugin & Helper")
                    Spacer()
                    if group.items.filter(\.state.isReady).count > 1 {
                        Button("Update All") { store.updateAll(on: machine.id) }
                            .font(.subheadline)
                            .textCase(nil)
                            .accessibilityIdentifier("hosts.host.updates.updateAll")
                    }
                }
            } footer: {
                Text(
                    "What Heeler installed on \(machine.name). Newer versions arrive with updates to the app.",
                    comment: "Under Host detail's Plugin & Helper section. Argument: the Host's name.")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: HostUpdateItem) -> some View {
        switch item.state {
        case .current, .other:
            // Nothing to do from here: the Server's page has the rest.
            NavigationLink(
                value: HostDetailDestination.server(item.record, opensHostHelper: item.component == .helper)
            ) {
                HostUpdateRow(item: item, act: {})
            }
        case .updateAvailable, .waiting, .updating, .readingBack, .updated, .failed, .damaged:
            HostUpdateRow(item: item, act: { store.update(item.id) }, open: { openItem(item.id) })
        }
    }
}
