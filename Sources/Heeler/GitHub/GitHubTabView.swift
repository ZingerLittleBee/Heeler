import SwiftUI
import UIKit

/// Where the GitHub tab can start a Terminal on a Host, for a setup command.
struct GitHubTerminalLink {
    /// The record a new Terminal on the Host starts on; nil where none can.
    let record: @MainActor (GitHubHost) -> Host.ID?
    let open: @MainActor (Host.ID) -> Void
}

/// A row's way into its detail on an iPhone: the item, on the Host whose
/// list showed it.
struct GitHubItemLink: Hashable {
    let host: GitHubHost
    let item: GitHubItem
}

/// The GitHub tab on an iPhone, or an iPad window too narrow for a sidebar:
/// a row pushes its detail.
struct GitHubTabView: View {
    let store: GitHubStore
    /// The pushed details, which the Console reads to hide its tab bar.
    @Binding var path: [GitHubItemLink]
    let terminals: GitHubTerminalLink?
    let send: GitHubSendLink?
    let write: GitHubWriteLink

    var body: some View {
        NavigationStack(path: $path) {
            GitHubListScreen(store: store, terminals: terminals, selection: nil)
                .navigationDestination(for: GitHubItemLink.self) { link in
                    GitHubItemScreen(store: store, host: link.host, item: link.item, send: send, write: write)
                }
        }
    }
}

/// The pull requests and issues that involve the account gh is signed in to
/// on one Host, and every state on the way there (ADR 0065).
struct GitHubListScreen: View {
    let store: GitHubStore
    let terminals: GitHubTerminalLink?
    /// Beside an iPad's detail column, the row whose detail it shows; nil
    /// where a row pushes its detail instead.
    let selection: Binding<GitHubItem.ID?>?
    @SceneStorage("github.kind") private var kind = GitHubItem.Kind.pullRequest
    @State private var filterSheet: GitHubFilterSheet?
    /// Where the bar ends on screen, which the header's title scrolls under.
    @State private var barBottom: CGFloat = 0
    /// The header's title has scrolled under the bar, which then shows it.
    @State private var titleIsUnderBar = false
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    var body: some View {
        Group {
            if let host = store.selectedHost {
                content(for: host)
            } else if store.hasHiddenHostsOnly {
                fullScreen {
                    ContentUnavailableView {
                        Label("No Host Can Run gh", systemImage: "server.rack")
                    } description: {
                        Text("The GitHub tab needs a macOS or Linux Host. Heeler reads pull requests and issues through the gh command there.")
                    }
                }
            } else {
                fullScreen {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a Host in Hosts. Heeler reads pull requests and issues through the gh command there.")
                    }
                }
            }
        }
        // The content starts under the bar, so its top is the bar's bottom.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { barBottom = $0 }
        .toolbar {
            if showsHostMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    GitHubHostMenu(store: store, status: status, kind: kind)
                }
            }
        }
        .modifier(
            GitHubListTitle(
                kind: $kind, showsKind: showsList, subtitle: subtitle, isUnderBar: titleIsUnderBar,
                isSidebarColumn: isSidebarColumn))
        .sheet(item: $filterSheet) { sheet in
            if let host = store.selectedHost {
                GitHubFilterEntrySheet(
                    sheet: sheet, kind: kind, options: GitHubFilterOptions(store: store, host: host, kind: kind),
                    filter: store.filter(for: kind)
                ) { store.setFilter($0, for: kind) }
            }
        }
        // Again when the Host connects: a list read while it was offline
        // is read as soon as it can be. Again for the other segment, and
        // for each change of a filter.
        .task(
            id: ReadTrigger(
                host: store.selectedHost?.id, isConnected: store.selectedHost.map(store.isConnected), kind: kind,
                filter: store.filter(for: kind))
        ) {
            await store.appear(showing: kind)
        }
    }

    private struct ReadTrigger: Equatable {
        let host: Host.ID?
        let isConnected: Bool?
        let kind: GitHubItem.Kind
        let filter: GitHubListFilter
    }

    /// What stopped the selected Host's last read, which the title bar
    /// shows rather than the list.
    private var status: GitHubHostStatus? {
        guard let host = store.selectedHost else { return nil }
        return GitHubHostStatus(failure: store.state(of: host).failure, isConnected: store.isConnected(host))
    }

    /// The line under the title whenever the list area shows, from its
    /// first frame, so the header keeps its height while a read runs, the
    /// Host drops or a read fails. Nil over a screen that takes the list's
    /// place, and going to or from one replaces the whole content anyway.
    private var subtitle: GitHubSubtitle? {
        guard let host = store.selectedHost, case .list = screen(for: host) else { return nil }
        let isConnected = store.isConnected(host)
        let content = content(on: host, isOffline: !isConnected || store.state(of: host).failure == .offline)
        // A read runs over what shows, or will fill the placeholder rows.
        // Offline, nothing reads.
        let isReading =
            switch content {
            case .reading: true
            case .rows(let shown): shown.isReading
            case .offline, .failed: false
            }
        if isConnected, isReading { return .reading }
        switch content {
        case .rows(let shown):
            // Dated by the rows on screen: a filter's results by their own read.
            return status.map { .status($0, readAt: shown.readAt) } ?? .read(shown.readAt)
        case .reading, .offline:
            // Only while the Host is offline: the status alone.
            return .status(status ?? GitHubHostStatus(kind: .offline), readAt: nil)
        case .failed(let failure):
            let status = GitHubHostStatus(failure: failure, isConnected: isConnected)
            return .status(status ?? GitHubHostStatus(kind: .failed(failure)), readAt: nil)
        }
    }

    /// With more than one Host to pick; with one, while it has a status,
    /// so its glyph shows and a failed read's gh words and Check Again stay
    /// in reach from its menu.
    private var showsHostMenu: Bool {
        store.hosts.count > 1 || status != nil
    }

    /// The list area shows, so the title is the kind shown; over a screen
    /// in its place, GitHub.
    private var showsList: Bool {
        guard let host = store.selectedHost, case .list = screen(for: host) else { return false }
        return true
    }

    /// What takes the tab for the selected Host: the list area under the
    /// filters, or a screen in its place.
    private enum Screen {
        case setup(GitHubSetupView.Step)
        case list
        /// Offline with nothing read.
        case offline
        /// A read failed with nothing read.
        case failed
    }

    private func screen(for host: GitHubHost) -> Screen {
        let state = store.state(of: host)
        let isConnected = store.isConnected(host)
        switch state.failure {
        case .notInstalled(let isMac): return .setup(.install(isMac: isMac))
        case .notSignedIn: return .setup(.signIn)
        default:
            // A changed filter keeps its row, whatever its read found.
            if !store.filter(for: kind).isDefault || state.list != nil || state.isReading
                || (state.failure == nil && isConnected)
            {
                return .list
            }
            return !isConnected || state.failure == .offline ? .offline : .failed
        }
    }

    @ViewBuilder
    private func content(for host: GitHubHost) -> some View {
        let state = store.state(of: host)
        switch screen(for: host) {
        case .setup(let step):
            fullScreen {
                GitHubSetupView(
                    step: step, host: host, terminals: terminals, isReading: state.isReading
                ) { Task { await store.checkAgain(showing: kind) } }
            }
        case .list:
            listView(host: host, state: state, isConnected: store.isConnected(host))
        case .offline:
            fullScreen {
                ContentUnavailableView {
                    Label("\(host.name) Is Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Heeler reads GitHub through gh on \(host.name) once it connects.")
                }
            }
        case .failed:
            fullScreen {
                GitHubReadFailureView(failure: state.failure) { Task { await store.checkAgain(showing: kind) } }
            }
        }
    }

    /// A screen in the list's place. Beside an iPad's detail it fills the
    /// column; elsewhere it sits under GitHub, in the header's place, so
    /// going between it and the list leaves the title where it is.
    @ViewBuilder
    private func fullScreen(@ViewBuilder _ content: () -> some View) -> some View {
        if isSidebarColumn {
            content()
        } else {
            List {
                GitHubListHeader(kind: nil, subtitle: nil, barBottom: barBottom, isUnderBar: $titleIsUnderBar) {
                    EmptyView()
                }
                Section {
                    content()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }

    private func listView(host: GitHubHost, state: GitHubStore.HostState, isConnected: Bool) -> some View {
        let isOffline = !isConnected || state.failure == .offline
        return Group {
            if let selection {
                List(selection: selection) {
                    listRows(host: host, state: state, isOffline: isOffline)
                }
            } else {
                List {
                    listRows(host: host, state: state, isOffline: isOffline)
                }
            }
        }
        .modifier(GitHubListStyle())
        .refreshable { await store.refresh(showing: kind) }
    }

    /// What the list area shows under the filters.
    private enum Content {
        case rows(GitHubStore.Shown)
        /// The placeholder rows, while a read finds something to show.
        case reading
        /// A changed filter while the Host is offline: only the list at the
        /// defaults is kept.
        case offline
        /// A changed filter's search failed. Its earlier rows are not shown:
        /// a filter's results are never kept as a list read earlier.
        case failed(GitHubReadFailure)
    }

    private func content(on host: GitHubHost, isOffline: Bool) -> Content {
        let filter = store.filter(for: kind)
        if filter.isDefault {
            return store.shown(kind, on: host).map(Content.rows) ?? .reading
        }
        if isOffline { return .offline }
        if let results = store.results(kind, on: host), !results.isReading, let failure = results.failure {
            return .failed(failure)
        }
        return store.shown(kind, on: host).map(Content.rows) ?? .reading
    }

    @ViewBuilder
    private func listRows(host: GitHubHost, state: GitHubStore.HostState, isOffline: Bool) -> some View {
        let filter = store.filter(for: kind)
        let filters = GitHubFilterBar(
            kind: kind, filter: filter, options: GitHubFilterOptions(store: store, host: host, kind: kind),
            apply: { store.setFilter($0, for: kind) }, openSheet: { filterSheet = $0 })
        // The Host's status is in the title bar, never in the list.
        if isSidebarColumn {
            // The sidebar's title is its menu of lists, so the kind is a
            // segmented control over the filters.
            Section {
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    GitHubKindPicker(kind: $kind)
                    filters
                }
                .textCase(nil)
                .padding(.bottom, 14)
                .listRowInsets(EdgeInsets())
            }
            .listSectionSpacing(.custom(0))
        } else {
            GitHubListHeader(kind: $kind, subtitle: subtitle, barBottom: barBottom, isUnderBar: $titleIsUnderBar) {
                filters
            }
        }
        switch content(on: host, isOffline: isOffline) {
        case .rows(let shown):
            rows(shown, filter: filter, host: host, isOffline: isOffline)
        case .reading:
            // The line under the title says a read runs.
            Section {
                placeholderRows
            }
        case .offline:
            unavailable {
                ContentUnavailableView {
                    Label("\(host.name) Is Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Heeler searches GitHub through gh on \(host.name). Until it connects, only the list read earlier can be shown.")
                } actions: {
                    clearFilters
                }
            }
        case .failed(let failure):
            unavailable {
                GitHubReadFailureView(failure: failure, clearFilters: { store.setFilter(GitHubListFilter(), for: kind) }) {
                    Task { await store.checkAgain(showing: kind) }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(
        _ shown: GitHubStore.Shown, filter: GitHubListFilter, host: GitHubHost, isOffline: Bool
    ) -> some View {
        let context = GitHubRowContext(viewer: shown.login, filter: filter)
        if shown.list.items.isEmpty {
            unavailable {
                if filter.isDefault {
                    GitHubNothingView(kind: kind)
                } else {
                    ContentUnavailableView {
                        Label(
                            kind == .pullRequest ? "No Matching Pull Requests" : "No Matching Issues",
                            systemImage: "magnifyingglass")
                    } description: {
                        Text("Nothing on GitHub matches these filters.")
                    } actions: {
                        clearFilters
                    }
                }
            }
        }
        // The line under the title says when the rows were read, and that
        // a read runs over them.
        Section {
            itemRows(shown, context: context, host: host, isOffline: isOffline)
        }
    }

    @ViewBuilder
    private func itemRows(
        _ shown: GitHubStore.Shown, context: GitHubRowContext, host: GitHubHost, isOffline: Bool
    ) -> some View {
        let items = shown.list.items
        // The next page starts reading when the row about a screen above
        // the end comes on, so a scroll seldom meets the end.
        let readAheadID = items.isEmpty ? nil : items[max(0, items.count - Self.readAheadRows)].id
        ForEach(items) { item in
            row(item, context: context, host: host, isOffline: isOffline)
                .onAppear {
                    if item.id == readAheadID { readAhead(shown, host: host, isOffline: isOffline) }
                }
        }
        if shown.list.hasMore {
            if let failure = store.moreFailure(kind, on: host) {
                // Offline it stays, with Try Again greyed, so its height
                // and the rows above it hold.
                GitHubShowMoreFailureRow(failure: failure, isAvailable: !isOffline) {
                    Task { await store.showMore(kind) }
                }
            } else {
                // Offline there is nothing to read the next page with, but
                // the row stays, greyed, so the rows do not look like all
                // there is. Online it reads by itself as it comes on, and
                // stays a button for VoiceOver and Switch Control.
                GitHubShowMoreRow(
                    shown: shown.list.items.count, total: shown.list.totalCount,
                    isReading: store.state(of: host).readingMore.contains(kind), isAvailable: !isOffline
                ) { Task { await store.showMore(kind) } }
                .onAppear { readAhead(shown, host: host, isOffline: isOffline) }
            }
        }
    }

    /// How far above the end the next page starts reading: about a screen
    /// of rows on an iPhone.
    private static let readAheadRows = 10

    /// Show More without a tap, as the end of the rows comes near. A read
    /// that failed waits for Try Again rather than running again, so a rate
    /// limit is not asked again on every scroll.
    private func readAhead(_ shown: GitHubStore.Shown, host: GitHubHost, isOffline: Bool) {
        guard shown.list.hasMore, !isOffline, store.moreFailure(kind, on: host) == nil else { return }
        Task { await store.showMore(kind) }
    }

    private var placeholderRows: some View {
        ForEach(0..<4, id: \.self) { _ in
            GitHubItemRow.placeholder
        }
    }

    /// An empty state in the list's place under the filters, which stay.
    private func unavailable(@ViewBuilder _ content: () -> some View) -> some View {
        Section {
            content()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var clearFilters: some View {
        GitHubClearFiltersButton { store.setFilter(GitHubListFilter(), for: kind) }
    }

    /// A row opens its detail, except from a list shown while the Host is
    /// offline, which has nothing to read it with. No row shows a
    /// disclosure chevron, so a row is as wide offline as online.
    @ViewBuilder
    private func row(
        _ item: GitHubItem, context: GitHubRowContext, host: GitHubHost, isOffline: Bool
    ) -> some View {
        let row = GitHubItemRow(item: item, context: context)
            .opacity(isOffline ? 0.55 : 1)
        if let selection {
            row
                .tag(item.id)
                // Offline the open item keeps its highlight: a disabled
                // row loses it.
                .selectionDisabled(isOffline && item.id != selection.wrappedValue)
        } else if isOffline {
            row
        } else {
            NavigationLink(value: GitHubItemLink(host: host, item: item)) { row }
                .navigationLinkIndicatorVisibility(.hidden)
        }
    }
}

/// A plain full-width list on an iPhone; beside an iPad's detail column,
/// the sidebar's selectable rows, as the Agents list has.
private struct GitHubListStyle: ViewModifier {
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        if isSidebarColumn {
            content
                .listStyle(.sidebar)
                .modifier(ConsoleSidebarListTint())
        } else {
            content.listStyle(.plain)
        }
    }
}

/// The list's title in the bar. Beside an iPad's detail the sidebar's
/// chrome titles the column, and the line goes under its bar. Elsewhere the
/// bar stays inline, and its title is hidden while the list's header shows
/// it; once the header's title scrolls under the bar, the bar shows it, with
/// the kind's menu and, on iOS 26, the line under it. Hidden, it still names
/// a pushed detail's back button.
private struct GitHubListTitle: ViewModifier {
    @Binding var kind: GitHubItem.Kind
    /// The list area shows, so the title is the kind; otherwise GitHub.
    let showsKind: Bool
    let subtitle: GitHubSubtitle?
    let isUnderBar: Bool
    let isSidebarColumn: Bool

    func body(content: Content) -> some View {
        if isSidebarColumn {
            content.modifier(GitHubSubtitleLine(subtitle: subtitle))
        } else {
            Group {
                // An empty title menu still shows its chevron. The content
                // changes along with it, so the branch costs nothing more.
                if showsKind {
                    content
                        .navigationTitle(GitHubHeaderTitle.title(of: kind))
                        .toolbarTitleMenu { GitHubKindChoices(kind: $kind) }
                } else {
                    content.navigationTitle(ConsoleTab.github.title)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: isUnderBar ? nil : .title)
            .modifier(GitHubSubtitleLine(subtitle: isUnderBar ? subtitle : nil))
            .background(BarTitleFade(isShown: isUnderBar))
        }
    }
}

/// Crossfades the navigation bar when its title comes or goes, as a large
/// title's collapse does: SwiftUI swaps a bar's title without animation.
private struct BarTitleFade: UIViewRepresentable {
    let isShown: Bool

    func makeUIView(context: Context) -> FadeView { FadeView(isShown: isShown) }

    func updateUIView(_ view: FadeView, context: Context) {
        view.update(isShown: isShown)
    }

    final class FadeView: UIView {
        private var isShown: Bool

        init(isShown: Bool) {
            self.isShown = isShown
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func update(isShown: Bool) {
            guard isShown != self.isShown else { return }
            self.isShown = isShown
            // In the same update as the title's change, so the fade
            // covers it.
            guard let bar = enclosingNavigationController()?.navigationBar else { return }
            UIView.transition(
                with: bar, duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseInOut],
                animations: nil)
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let navigation = controller.navigationController {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}

/// The list's first row, where a large title would be: the kind, whose
/// menu switches it, over the line under it and the filters; over a screen
/// in the list's place, GitHub alone. It scrolls with the rows.
private struct GitHubListHeader<Below: View>: View {
    /// The kind the menu switches; nil for GitHub, without a menu.
    let kind: Binding<GitHubItem.Kind>?
    let subtitle: GitHubSubtitle?
    let barBottom: CGFloat
    @Binding var isUnderBar: Bool
    @ViewBuilder let below: () -> Below

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GitHubHeaderTitle(kind: kind, subtitle: subtitle, barBottom: barBottom, isUnderBar: $isUnderBar)
            below()
                .padding(.top, 12)
        }
        .listRowSeparator(.hidden)
    }
}

/// The header's title in the large title's font and the line under it.
/// Each fades with the scroll as it passes under the bar, which shows them
/// once both are gone; coming back out, they wait for the bar's to fade
/// first. The bar's glass shows what is under it, so the two never overlap.
private struct GitHubHeaderTitle: View {
    let kind: Binding<GitHubItem.Kind>?
    let subtitle: GitHubSubtitle?
    let barBottom: CGFloat
    @Binding var isUnderBar: Bool
    /// Out from under the bar while the bar still fades its title out.
    @State private var waitsForBar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .modifier(FadesUnderBar(barBottom: barBottom, isHeld: waitsForBar))
            if let subtitle {
                GitHubSubtitleText(subtitle: subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .modifier(FadesUnderBar(barBottom: barBottom, isHeld: waitsForBar))
            }
        }
        .accessibilityHidden(isUnderBar || waitsForBar)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .global).maxY <= barBottom
        } action: { isUnder in
            if isUnderBar && !isUnder { waitsForBar = true }
            isUnderBar = isUnder
        }
        .task(id: isUnderBar) {
            guard !isUnderBar, waitsForBar else { return }
            // The bar's crossfade takes 0.2 seconds.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { waitsForBar = false }
        }
    }

    @ViewBuilder
    private var title: some View {
        if let kind {
            Menu {
                GitHubKindChoices(kind: kind)
            } label: {
                // One Text, so at accessibility sizes the chevron follows
                // the last word rather than truncating it.
                (Self.title(of: kind.wrappedValue) + Text(verbatim: " ")
                    + Text(Image(systemName: "chevron.down"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary))
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    "Showing \(kind.wrappedValue == .pullRequest ? String(localized: "Pull Requests") : String(localized: "Issues"))",
                    comment: "VoiceOver label of the GitHub list's title, a menu that switches between pull requests and issues."))
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(ConsoleTab.github.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
        }
    }

    static func title(of kind: GitHubItem.Kind) -> Text {
        kind == .pullRequest ? Text("Pull Requests") : Text("Issues")
    }
}

/// Fades a piece of the list's header with the scroll: opaque until its top
/// meets the bar's bottom, clear once its bottom has passed it.
private struct FadesUnderBar: ViewModifier {
    let barBottom: CGFloat
    /// Kept clear whatever the scroll, while the bar fades its own out.
    let isHeld: Bool

    func body(content: Content) -> some View {
        let barBottom = barBottom
        let isHeld = isHeld
        content.visualEffect { effect, proxy in
            guard !isHeld else { return effect.opacity(0) }
            let frame = proxy.frame(in: .global)
            guard frame.height > 0 else { return effect.opacity(1) }
            let shown = min(max((frame.maxY - barBottom) / frame.height, 0), 1)
            return effect.opacity(shown)
        }
    }
}

// MARK: - Pieces

/// Pull Requests and Issues, each with its list's open glyph, the one
/// shown checked.
private struct GitHubKindChoices: View {
    @Binding var kind: GitHubItem.Kind

    var body: some View {
        Picker("Show", selection: $kind) {
            Label("Pull Requests", systemImage: ConsoleTab.gitHubSymbol)
                .tag(GitHubItem.Kind.pullRequest)
            Label("Issues", systemImage: "smallcircle.filled.circle")
                .tag(GitHubItem.Kind.issue)
        }
    }
}

/// Beside an iPad's detail, whose sidebar title is its menu of lists:
/// sized to its words and leading, like the filters under it.
private struct GitHubKindPicker: View {
    @Binding var kind: GitHubItem.Kind

    var body: some View {
        Picker("Show", selection: $kind) {
            Text("Pull Requests").tag(GitHubItem.Kind.pullRequest)
            Text("Issues").tag(GitHubItem.Kind.issue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private struct GitHubNothingView: View {
    let kind: GitHubItem.Kind

    var body: some View {
        switch kind {
        case .pullRequest:
            ContentUnavailableView {
                Label("No Pull Requests Involve You", systemImage: ConsoleTab.gitHubSymbol)
            } description: {
                Text("Open pull requests you created or were asked to review show here.")
            }
        case .issue:
            ContentUnavailableView {
                Label("No Issues Involve You", systemImage: "smallcircle.filled.circle")
            } description: {
                Text("Open issues assigned to you or created by you show here.")
            }
        }
    }
}

/// After a page of rows: "Show More", and how many of GitHub's count show.
/// Offline it cannot be tapped.
private struct GitHubShowMoreRow: View {
    let shown: Int
    let total: Int
    let isReading: Bool
    let isAvailable: Bool
    let showMore: () -> Void

    var body: some View {
        Button(action: showMore) {
            HStack(spacing: 8) {
                Text("Show More")
                    // The iPad's sidebar draws a button's words in the
                    // primary colour.
                    .foregroundStyle(
                        isReading || !isAvailable ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tint))
                Spacer(minLength: 8)
                if isReading {
                    ProgressView()
                } else {
                    // Its own key: "%lld of %lld" is a question card's.
                    Text(
                        String(
                            localized: "GitHub list rows shown of found", defaultValue: "\(shown) of \(total)",
                            comment: "Under a GitHub list: rows shown of what GitHub found, such as 30 of 182."))
                        .font(.subheadline)
                        .monospacedDigit()
                        // Not `.secondary`, which in a button is the tint's.
                        .foregroundStyle(Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(isReading || !isAvailable)
        // The iPad's sidebar greys its tint.
        .tint(GitHubFilterBar.accent)
    }
}

/// In Show More's place after the next page's read failed, under the rows
/// already shown: what stopped it, and Try Again, which reads the page again.
/// Offline Try Again is greyed.
private struct GitHubShowMoreFailureRow: View {
    let failure: GitHubReadFailure
    let isAvailable: Bool
    let tryAgain: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if case .rateLimited(let retryAt?) = failure {
            // Counts down to when the limit ends.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(message: Self.message(for: failure, retryAt: retryAt, now: context.date))
            }
        } else {
            row(message: GitHubBannerText.message(for: failure))
        }
    }

    /// GitHub's rate limit with when to try again, while it lasts.
    static func message(for failure: GitHubReadFailure, retryAt: Date, now: Date) -> String {
        let words = GitHubBannerText.message(for: failure)
        guard let wait = GitHubBanner.wait(until: retryAt, now: now) else { return words }
        return [words, String(localized: "Try again in \(wait).")].joinedAsSentences()
    }

    private func row(message: String) -> some View {
        let title = String(
            localized: "Could not read more",
            comment: "In place of Show More under a GitHub list, after reading its next page failed.")
        // Try Again trails the first line, and gh's words take the width
        // under both, which a sidebar's column needs. At accessibility
        // sizes it goes under the words, or the line would hold a word.
        let isLarge = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // The glyph leads the words, as a row's state glyph leads
                // its first line.
                (Text(Image(systemName: "exclamationmark.triangle")) + Text(verbatim: " \(title)"))
                    .foregroundStyle(Color.errorInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isLarge { tryAgainButton }
            }
            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            if isLarge {
                tryAgainButton
                    .padding(.top, 6)
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        // The iPad's sidebar greys its tint.
        .tint(GitHubFilterBar.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title.asSentence, message].joinedAsSentences())
        .accessibilityActions {
            if isAvailable { Button("Try Again", action: tryAgain) }
        }
    }

    private var tryAgainButton: some View {
        Button(action: tryAgain) {
            // The iPad's sidebar draws a button's words in the primary
            // colour.
            Text("Try Again")
                .foregroundStyle(isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
        }
        // Only its words take a tap, not the whole row.
        .buttonStyle(.borderless)
        .disabled(!isAvailable)
        .fixedSize()
    }
}

/// A read that failed with nothing to show for it: GitHub's rate limit, with
/// when it ends, or gh's own words.
private struct GitHubReadFailureView: View {
    let failure: GitHubReadFailure?
    /// For a changed filter's search, which GitHub may refuse however often
    /// it is asked, such as one naming an account that does not exist.
    var clearFilters: (() -> Void)?
    let checkAgain: () -> Void

    var body: some View {
        if case .rateLimited(let retryAt) = failure {
            ContentUnavailableView {
                Label("GitHub's Rate Limit Was Reached", systemImage: "hourglass")
            } description: {
                if let retryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(GitHubBanner.retry(at: retryAt, now: context.date))
                    }
                }
            } actions: {
                actions
            }
        } else {
            ContentUnavailableView {
                Label("Could Not Read GitHub", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.map(GitHubBannerText.message(for:)) ?? "")
            } actions: {
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Check Again", action: checkAgain)
        if let clearFilters {
            GitHubClearFiltersButton(action: clearFilters)
        }
    }
}

/// gh is missing on the Host, or not signed in there.
private struct GitHubSetupView: View {
    enum Step: Equatable {
        case install(isMac: Bool)
        case signIn
    }

    static let linuxInstallURL = URL(string: "https://github.com/cli/cli/blob/trunk/docs/install_linux.md")

    let step: Step
    let host: GitHubHost
    let terminals: GitHubTerminalLink?
    let isReading: Bool
    let checkAgain: () -> Void
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    var body: some View {
        // Elsewhere it is a row of a list under the tab's title, which
        // scrolls it.
        if isSidebarColumn {
            ScrollView { card }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: step == .signIn ? "person.crop.circle.badge.questionmark" : "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            command
            VStack(spacing: 12) {
                if let terminals, let record = terminals.record(host) {
                    Button {
                        terminals.open(record)
                    } label: {
                        Label("Open Terminal on \(host.name)", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button(action: checkAgain) {
                    HStack(spacing: 8) {
                        if isReading { ProgressView() }
                        Text("Check Again")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isReading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch step {
        case .install: String(localized: "GitHub CLI Isn't Installed")
        case .signIn: String(localized: "Sign In to GitHub on \(host.name)")
        }
    }

    private var message: String {
        switch step {
        case .install(isMac: true):
            String(localized: "Heeler reads pull requests and issues through the gh command on \(host.name). Install it there, then check again.")
        case .install(isMac: false):
            String(localized: "Heeler reads pull requests and issues through the gh command on \(host.name). Install it there with GitHub's instructions for Linux, then check again.")
        case .signIn:
            String(localized: "gh is installed on \(host.name) but isn't signed in. Run this in a terminal there, then check again.")
        }
    }

    @ViewBuilder
    private var command: some View {
        switch step {
        case .install(isMac: true):
            CommandBlock(command: "brew install gh")
        case .install(isMac: false):
            if let url = Self.linuxInstallURL {
                Link(destination: url) {
                    Label("Installing gh on Linux", systemImage: "arrow.up.right.square")
                }
            }
        case .signIn:
            CommandBlock(command: "gh auth login")
        }
    }
}

// MARK: - The Host's status

/// What stopped the selected Host's last read, or a detail's. The title bar
/// shows it, not the list: a glyph on the Host button and, on iOS 26, the
/// line under the title, such as "Offline · Read yesterday at 18:40"
/// (ADR 0065).
struct GitHubHostStatus: Equatable {
    enum Kind: Equatable {
        case offline
        case rateLimited(retryAt: Date?)
        /// gh's words, or Heeler's for a read that stopped some other way.
        case failed(GitHubReadFailure)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    /// gh missing or signed out takes the list's place, and a Host that
    /// cannot run gh is not offered, so neither has a status.
    init?(failure: GitHubReadFailure?, isConnected: Bool) {
        if !isConnected || failure == .offline {
            kind = .offline
        } else {
            switch failure {
            case .rateLimited(let retryAt): kind = .rateLimited(retryAt: retryAt)
            case .timedOut: kind = .failed(.timedOut)
            case .failed(let words): kind = .failed(.failed(words))
            case .notInstalled, .notSignedIn, .unsupported, .offline, nil: return nil
            }
        }
    }

    var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// "Offline": the subtitle's first part, and how VoiceOver reads the
    /// Host button's state.
    var title: String {
        switch kind {
        case .offline: String(localized: "Offline")
        case .rateLimited:
            String(
                localized: "Rate limited",
                comment: "A Host's status in the GitHub tab: GitHub's rate limit stopped its read.")
        case .failed: String(localized: "Could not read GitHub")
        }
    }

    /// Under the title: "Offline · Read yesterday at 18:40", "Rate limited ·
    /// Try again in 4m 12s", "Could not read GitHub · Read at 14:05", after
    /// when what shows was read. The status alone when nothing read shows.
    func subtitle(readAt: Date?, now: Date) -> String {
        let detail: String? =
            if case .rateLimited(let retryAt?) = kind {
                Self.retry(at: retryAt, now: now)
            } else {
                readAt.map { GitHubReadTime($0, now: now).read }
            }
        return [title, detail].compactMap(\.self).joined(separator: " · ")
    }

    /// "Try again in 4m 12s", counting down; "Pull to try again" once the
    /// limit has ended.
    static func retry(at date: Date, now: Date) -> String {
        guard let wait = GitHubBanner.wait(until: date, now: now) else {
            return String(
                localized: "Pull to try again", comment: "After \"Rate limited · \" under the GitHub tab's title.")
        }
        return String(
            localized: "Try again in \(wait)",
            comment: "After \"Rate limited · \" under the GitHub tab's title. The wait counts down: 4m 12s.")
    }
}

/// The line under a GitHub title: the list header's and a detail's (ADR
/// 0065). While either shows it is never empty, so nothing that comes and
/// goes moves what is under it; only a screen that takes the list's place
/// has none.
enum GitHubSubtitle: Equatable {
    /// A read with nothing to show yet, or one running over what shows.
    case reading
    /// What shows was read then, and nothing stopped the last read.
    case read(Date)
    /// What stopped the last read, and when what shows was read, if
    /// anything read shows.
    case status(GitHubHostStatus, readAt: Date?)

    /// iOS 26 shows the line under a detail's title. Before it there is
    /// none, and the detail's banner says it instead.
    static var isShown: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }

    /// "Reading…", "Read at 14:05", "Offline · Read yesterday at 18:40".
    func text(now: Date) -> String {
        switch self {
        case .reading: String(localized: "Reading…")
        case .read(let date): GitHubReadTime(date, now: now).read
        case .status(let status, let readAt): status.subtitle(readAt: readAt, now: now)
        }
    }

    /// When a rate limit ends, which the line counts down to.
    var retryAt: Date? {
        guard case .status(let status, _) = self, case .rateLimited(let retryAt?) = status.kind else { return nil }
        return retryAt
    }

    /// Gives `tick` the time now, then each second until a rate limit
    /// ends, so the line counts down to it.
    @MainActor
    static func keepCurrent(_ subtitle: GitHubSubtitle?, tick: (Date) -> Void) async {
        var now = Date()
        tick(now)
        guard let retryAt = subtitle?.retryAt else { return }
        while !Task.isCancelled, now < retryAt {
            try? await Task.sleep(for: .seconds(1))
            now = Date()
            tick(now)
        }
    }
}

/// The line under the list header's title. One line; at accessibility
/// sizes the lines it takes, so a short status leaves no blank line under
/// it and a long one is not cut off.
struct GitHubSubtitleText: View {
    let subtitle: GitHubSubtitle
    @State private var now = Date()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Text(subtitle.text(now: now))
            .monospacedDigit()
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .task(id: subtitle) { await GitHubSubtitle.keepCurrent(subtitle) { now = $0 } }
    }
}

/// Puts the line under the title where iOS 26 shows a navigation subtitle,
/// and under an iPad sidebar's bar, whose title is its menu of lists.
struct GitHubSubtitleLine: ViewModifier {
    let subtitle: GitHubSubtitle?
    @State private var now = Date()
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        let text = subtitle?.text(now: now)
        Group {
            if #available(iOS 26.0, *) {
                // Always set, empty when there is nothing to say: a modifier
                // added and removed would make the list a new view.
                content
                    .navigationSubtitle(isSidebarColumn ? "" : text ?? "")
                    .safeAreaBar(edge: .top, alignment: .leading) {
                        sidebarLine(text)
                    }
            } else {
                content
                    .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
                        sidebarLine(text)
                    }
            }
        }
        .task(id: subtitle) { await GitHubSubtitle.keepCurrent(subtitle) { now = $0 } }
    }

    /// In the bar's area just under the sidebar's title menu.
    @ViewBuilder
    private func sidebarLine(_ text: String?) -> some View {
        if isSidebarColumn, let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // One line, as a navigation subtitle keeps: a longer
                // status that wrapped would move the list.
                .lineLimit(1)
                // In line with the title menu's name.
                .padding(.leading, 22)
                .padding(.trailing, 16)
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Banners

/// What the banner over a pull request's or an issue's detail says before
/// iOS 26, where the line under its title says it instead.
struct GitHubBannerText: Equatable {
    enum Kind: Equatable {
        case offline
        case rateLimited(retryAt: Date?)
        case failed
    }

    let kind: Kind
    let title: String
    let message: String

    private init(kind: Kind, title: String, message: String) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    /// Over a pull request's or an issue's detail: whatever stopped its read.
    init?(detailFailure failure: GitHubReadFailure?, isOffline: Bool, host: GitHubHost, readAt: Date?) {
        self.init(failure: failure, isOffline: isOffline, host: host, readAt: readAt)
    }

    private init?(failure: GitHubReadFailure?, isOffline: Bool, host: GitHubHost, readAt: Date?) {
        let read = readAt.map { GitHubReadTime($0).showing } ?? ""
        if isOffline {
            self.init(kind: .offline, title: String(localized: "\(host.name) is offline"), message: read)
            return
        }
        switch failure {
        case .rateLimited(let retryAt):
            self.init(
                kind: .rateLimited(retryAt: retryAt), title: String(localized: "GitHub's rate limit was reached"),
                message: read)
        case .timedOut, .failed, .notInstalled, .notSignedIn, .unsupported:
            self.init(
                kind: .failed, title: String(localized: "Could not read GitHub"),
                message: failure.map(Self.message(for:)) ?? "")
        case .offline, nil:
            return nil
        }
    }

    static func message(for failure: GitHubReadFailure) -> String {
        switch failure {
        case .failed(let words): words
        case .timedOut: String(localized: "gh did not answer in time.")
        case .rateLimited: String(localized: "GitHub's rate limit was reached.")
        case .offline: String(localized: "The Host is not connected.")
        case .notInstalled: String(localized: "gh is not installed on the Host.")
        case .notSignedIn: String(localized: "gh is not signed in on the Host.")
        case .unsupported: String(localized: "This Host cannot run gh for Heeler.")
        }
    }
}

struct GitHubBanner: View {
    let text: GitHubBannerText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title)
                    .font(.subheadline.weight(.semibold))
                Group {
                    if case .rateLimited(let retryAt?) = text.kind {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text([text.message, Self.retry(at: retryAt, now: context.date)].joinedAsSentences())
                        }
                    } else {
                        Text(text.message)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch text.kind {
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch text.kind {
        case .offline: .secondary
        case .rateLimited, .failed: GitHubInk.amber
        }
    }

    static func retry(at date: Date, now: Date) -> String {
        guard let wait = wait(until: date, now: now) else { return String(localized: "Pull to try again.") }
        return String(localized: "Try again in \(wait).")
    }

    /// "4m 12s" until a rate limit ends; nil once it has.
    nonisolated static func wait(until date: Date, now: Date) -> String? {
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return nil }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

// MARK: - When a list was read

/// When a list or a detail was read, as the line under a title, a detail's
/// banner before iOS 26, and the Host menu say it.
struct GitHubReadTime {
    enum Day {
        case today
        case yesterday
        case earlier(String)
    }

    let day: Day
    let time: String

    init(_ date: Date, now: Date = Date(), calendar: Calendar = .current) {
        time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            day = .today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            day = .yesterday
        } else {
            day = .earlier(date.formatted(.dateTime.month(.abbreviated).day()))
        }
    }

    /// "Read yesterday at 18:40", under a title, alone or after a status.
    var read: String {
        switch day {
        case .today: String(localized: "Read at \(time)")
        case .yesterday:
            String(
                localized: "Read yesterday at \(time)",
                comment: "Under a GitHub title, alone or after a Host's status: when the list or item shown was read.")
        case .earlier(let date):
            String(
                localized: "Read on \(date) at \(time)",
                comment: "Under a GitHub title, alone or after a Host's status: when the list or item shown was read.")
        }
    }

    /// "Showing what was read at 14:05."
    var showing: String {
        switch day {
        case .today: String(localized: "Showing what was read at \(time).")
        case .yesterday: String(localized: "Showing what was read yesterday at \(time).")
        case .earlier(let date): String(localized: "Showing what was read on \(date) at \(time).")
        }
    }

    /// "Offline, read yesterday", in the Host menu.
    var offline: String {
        switch day {
        case .today: String(localized: "Offline, read at \(time)")
        case .yesterday: String(localized: "Offline, read yesterday")
        case .earlier(let date): String(localized: "Offline, read on \(date)")
        }
    }
}

// MARK: - Host menu

/// The Host the tab reads, with what each Host's gh last said. While the
/// selected Host has a status, its amber glyph comes before the name.
private struct GitHubHostMenu: View {
    let store: GitHubStore
    /// The selected Host's.
    let status: GitHubHostStatus?
    /// The segment on screen, which Check Again reads.
    let kind: GitHubItem.Kind
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    /// The widest the button's label fits in a 320-point sidebar's bar
    /// beside its title menu.
    private static let sidebarWidth: CGFloat = 143

    var body: some View {
        let selected = store.selectedHost
        Menu {
            ForEach(store.hosts) { host in
                Toggle(isOn: Binding(
                    get: { selected?.id == host.id },
                    set: { if $0 { store.select(host) } }
                )) {
                    Label(host.name, systemImage: store.isConnected(host) ? "desktopcomputer" : "wifi.slash")
                    if let status = status(of: host) {
                        Text(status)
                    }
                }
            }
            // After a failed read, gh's words, which nothing else on
            // screen shows: a section's title, which wraps where a Host's
            // status line would be cut off, over Check Again as the
            // full-screen failure offers it.
            if case .failed(let failure) = status?.kind {
                Section(GitHubBannerText.message(for: failure)) {
                    Button("Check Again", systemImage: "arrow.clockwise") {
                        Task { await store.checkAgain(showing: kind) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let status {
                    Image(systemName: status.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GitHubInk.amber)
                }
                Text(selected?.name ?? "")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            // An iPad sidebar's bar moves a wider button into its overflow
            // menu, so a long name, or one beside a status glyph, gives way.
            .frame(maxWidth: isSidebarColumn ? Self.sidebarWidth : nil)
        }
        .accessibilityLabel("GitHub Host")
        .accessibilityValue([selected?.name, status?.title].compactMap(\.self).joined(separator: ", "))
    }

    private func status(of host: GitHubHost) -> String? {
        let state = store.state(of: host)
        if !store.isConnected(host) {
            return state.list.map { GitHubReadTime($0.readAt).offline } ?? String(localized: "Offline")
        }
        switch state.failure {
        case .notInstalled: return String(localized: "GitHub CLI not installed")
        case .notSignedIn: return String(localized: "Not signed in")
        default: break
        }
        if let list = state.list { return "@\(list.login)" }
        // With no list to name the account, what stopped its read.
        switch state.failure {
        case .rateLimited:
            return String(
                localized: "Rate limited",
                comment: "A Host's status in the GitHub tab: GitHub's rate limit stopped its read.")
        case .timedOut, .failed, .unsupported: return String(localized: "Could not read GitHub")
        default: return nil
        }
    }
}
