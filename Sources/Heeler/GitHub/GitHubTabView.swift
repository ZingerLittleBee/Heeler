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
                .navigationTitle(ConsoleTab.github.title)
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

    var body: some View {
        Group {
            if let host = store.selectedHost {
                content(for: host)
            } else if store.hasHiddenHostsOnly {
                ContentUnavailableView {
                    Label("No Host Can Run gh", systemImage: "server.rack")
                } description: {
                    Text("The GitHub tab needs a macOS or Linux Host. Heeler reads pull requests and issues through the gh command there.")
                }
            } else {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a Host in Hosts. Heeler reads pull requests and issues through the gh command there.")
                }
            }
        }
        .toolbar {
            if showsHostMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    GitHubHostMenu(store: store, status: status, kind: kind)
                }
            }
        }
        .modifier(GitHubStatusSubtitle(status: status))
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
        let state = store.state(of: host)
        let isConnected = store.isConnected(host)
        // Dated by the rows on screen: a filter's results by their own
        // read, and nothing over a filter's Is Offline or failure screen.
        let readAt: Date? =
            if case .rows(let shown) = content(on: host, isOffline: !isConnected || state.failure == .offline) {
                shown.readAt
            } else {
                nil
            }
        return GitHubHostStatus(failure: state.failure, isConnected: isConnected, readAt: readAt)
    }

    /// With more than one Host to pick; with one, while it has a status,
    /// so its glyph shows and a failed read's gh words and Check Again stay
    /// in reach from its menu.
    private var showsHostMenu: Bool {
        store.hosts.count > 1 || status != nil
    }

    @ViewBuilder
    private func content(for host: GitHubHost) -> some View {
        let state = store.state(of: host)
        let isConnected = store.isConnected(host)
        switch state.failure {
        case .notInstalled(let isMac):
            GitHubSetupView(
                step: .install(isMac: isMac), host: host, terminals: terminals, isReading: state.isReading
            ) { Task { await store.checkAgain(showing: kind) } }
        case .notSignedIn:
            GitHubSetupView(
                step: .signIn, host: host, terminals: terminals, isReading: state.isReading
            ) { Task { await store.checkAgain(showing: kind) } }
        default:
            // A changed filter keeps its row, whatever its read found.
            if !store.filter(for: kind).isDefault || state.list != nil || state.isReading
                || (state.failure == nil && isConnected)
            {
                listView(host: host, state: state, isConnected: isConnected)
            } else if !isConnected || state.failure == .offline {
                ContentUnavailableView {
                    Label("\(host.name) Is Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Heeler reads GitHub through gh on \(host.name) once it connects.")
                }
            } else {
                GitHubReadFailureView(failure: state.failure) { Task { await store.checkAgain(showing: kind) } }
            }
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

    /// What the list area shows under the picker and the filters.
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
        // The Host's status is in the title bar, never in the list: this
        // section is only the picker and the filters.
        Section {
        } header: {
            VStack(alignment: .leading, spacing: 10) {
                GitHubKindPicker(kind: $kind)
                GitHubFilterBar(
                    kind: kind, filter: filter, options: GitHubFilterOptions(store: store, host: host, kind: kind),
                    apply: { store.setFilter($0, for: kind) }, openSheet: { filterSheet = $0 })
            }
            .textCase(nil)
            .padding(.bottom, 14)
            .listRowInsets(EdgeInsets())
        }
        .listSectionSpacing(.custom(0))
        switch content(on: host, isOffline: isOffline) {
        case .rows(let shown):
            rows(shown, filter: filter, host: host, isOffline: isOffline)
        case .reading:
            Section {
                ForEach(0..<4, id: \.self) { _ in
                    GitHubItemRow.placeholder
                }
            } header: {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading from \(host.name)…")
                }
                // One heading: the spinner alone read as an unnamed one.
                .accessibilityElement(children: .combine)
                .textCase(nil)
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
        Section {
            ForEach(shown.list.items) { item in
                row(item, context: context, host: host, isOffline: isOffline)
            }
            // Offline there is nothing to read the next page with.
            if shown.list.hasMore, !isOffline {
                if let failure = store.moreFailure(kind, on: host) {
                    GitHubShowMoreFailureRow(failure: failure) { Task { await store.showMore(kind) } }
                } else {
                    GitHubShowMoreRow(
                        shown: shown.list.items.count, total: shown.list.totalCount,
                        isReading: store.state(of: host).readingMore.contains(kind)
                    ) { Task { await store.showMore(kind) } }
                }
            }
        } footer: {
            HStack(spacing: 6) {
                // A read on its way over the list read earlier.
                if shown.isReading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(Text("Refreshing"))
                }
                Text(GitHubReadTime(shown.readAt).footer(host: host.name))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// An empty state in the list's place under the filters, which stay.
    private func unavailable(@ViewBuilder _ content: () -> some View) -> some View {
        Section {
            content()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        }
    }

    private var clearFilters: some View {
        GitHubClearFiltersButton { store.setFilter(GitHubListFilter(), for: kind) }
    }

    /// A row opens its detail, except from a list shown while the Host is
    /// offline, which has nothing to read it with.
    @ViewBuilder
    private func row(
        _ item: GitHubItem, context: GitHubRowContext, host: GitHubHost, isOffline: Bool
    ) -> some View {
        let row = GitHubItemRow(item: item, context: context)
            .opacity(isOffline ? 0.55 : 1)
        if selection != nil {
            row
                .tag(item.id)
                .selectionDisabled(isOffline)
        } else if isOffline {
            row
        } else {
            NavigationLink(value: GitHubItemLink(host: host, item: item)) { row }
        }
    }
}

/// Cards on an iPhone; beside an iPad's detail column, the sidebar's
/// selectable rows, as the Agents list has.
private struct GitHubListStyle: ViewModifier {
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        if isSidebarColumn {
            content
                .listStyle(.sidebar)
                .modifier(ConsoleSidebarListTint())
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}

// MARK: - Pieces

private struct GitHubKindPicker: View {
    @Binding var kind: GitHubItem.Kind

    var body: some View {
        Picker("Show", selection: $kind) {
            Text("Pull Requests").tag(GitHubItem.Kind.pullRequest)
            Text("Issues").tag(GitHubItem.Kind.issue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
private struct GitHubShowMoreRow: View {
    let shown: Int
    let total: Int
    let isReading: Bool
    let showMore: () -> Void

    var body: some View {
        Button(action: showMore) {
            HStack(spacing: 8) {
                Text("Show More")
                    // The iPad's sidebar draws a button's words in the
                    // primary colour.
                    .foregroundStyle(isReading ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tint))
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
            // In line with the rows' titles, past their 22-point icon and
            // its 10-point gap.
            .padding(.leading, 32)
            .contentShape(Rectangle())
        }
        .disabled(isReading)
        // The iPad's sidebar greys its tint.
        .tint(GitHubFilterBar.accent)
    }
}

/// In Show More's place after the next page's read failed, under the rows
/// already shown: what stopped it, and Try Again, which reads the page again.
private struct GitHubShowMoreFailureRow: View {
    let failure: GitHubReadFailure
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
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // In the rows' icon column, so the words line up with their titles.
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.errorInk)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: title)
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
        }
        // The iPad's sidebar greys its tint.
        .tint(GitHubFilterBar.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title.asSentence, message].joinedAsSentences())
        .accessibilityAction(named: Text("Try Again"), tryAgain)
    }

    private var tryAgainButton: some View {
        Button(action: tryAgain) {
            // The iPad's sidebar draws a button's words in the primary
            // colour.
            Text("Try Again")
                .foregroundStyle(.tint)
        }
        // Only its words take a tap, not the whole row.
        .buttonStyle(.borderless)
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

    var body: some View {
        ScrollView {
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

/// What stopped the selected Host's last read. The title bar shows it, not
/// the list: a glyph on the Host button and, on iOS 26, a subtitle under
/// the title such as "Offline · Read yesterday at 18:40" (ADR 0065).
struct GitHubHostStatus: Equatable {
    enum Kind: Equatable {
        case offline
        case rateLimited(retryAt: Date?)
        /// gh's words, or Heeler's for a read that stopped some other way.
        case failed(GitHubReadFailure)
    }

    let kind: Kind
    /// When the list on screen was read; nil when none was, and a screen
    /// of its own says what stopped the read.
    let readAt: Date?

    /// gh missing or signed out takes the list's place, and a Host that
    /// cannot run gh is not offered, so neither has a status.
    init?(failure: GitHubReadFailure?, isConnected: Bool, readAt: Date?) {
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
        self.readAt = readAt
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

    /// Under the title, over a list read earlier: "Offline · Read yesterday
    /// at 18:40", "Rate limited · Try again in 4m 12s", "Could not read
    /// GitHub · Read at 14:05". Nil without a list.
    func subtitle(now: Date) -> String? {
        guard let readAt else { return nil }
        let detail =
            if case .rateLimited(let retryAt?) = kind {
                Self.retry(at: retryAt, now: now)
            } else {
                GitHubReadTime(readAt, now: now).read
            }
        return [title, detail].joined(separator: " · ")
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

/// The status under the title, where iOS 26 shows a navigation subtitle;
/// before it, the Host button's glyph and its menu say it.
private struct GitHubStatusSubtitle: ViewModifier {
    let status: GitHubHostStatus?
    @State private var now = Date()
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let text = status?.subtitle(now: now)
            // Each always set, empty when there is nothing to say: a
            // modifier added and removed would make the list a new view.
            content
                .navigationSubtitle(isSidebarColumn ? "" : text ?? "")
                .background {
                    if !isSidebarColumn {
                        LargeTitleRemeasure(hasSubtitle: text != nil)
                    }
                }
                // An iPad sidebar's bar shows its own title menu in place
                // of the title, and no subtitle with it, so the line goes
                // in the bar's area just under it.
                .safeAreaBar(edge: .top, alignment: .leading) {
                    if isSidebarColumn, let text {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            // In line with the title menu's name.
                            .padding(.leading, 22)
                            .padding(.trailing, 16)
                            .padding(.bottom, 6)
                    }
                }
                .task(id: status) {
                    now = Date()
                    // A rate limit counts down to when it ends.
                    guard case .rateLimited(let retryAt?) = status?.kind else { return }
                    while !Task.isCancelled, now < retryAt {
                        try? await Task.sleep(for: .seconds(1))
                        now = Date()
                    }
                }
        } else {
            content
        }
    }
}

/// Gives a resting large title its new height when the subtitle comes or
/// goes. UIKit (iOS 26.5 and 27) keeps the bar's old height until the list
/// scrolls: a subtitle that comes pushes the title up beside the Host
/// button, and one that goes leaves a gap above the title. The bar is
/// measured again when the navigation controller lays out, which has to
/// come after SwiftUI has set the subtitle, so on the main queue's next
/// turn.
@available(iOS 26.0, *)
private struct LargeTitleRemeasure: UIViewRepresentable {
    let hasSubtitle: Bool

    func makeUIView(context: Context) -> RemeasureView { RemeasureView(hasSubtitle: hasSubtitle) }

    func updateUIView(_ view: RemeasureView, context: Context) {
        view.update(hasSubtitle: hasSubtitle)
    }

    final class RemeasureView: UIView {
        private var hasSubtitle: Bool

        init(hasSubtitle: Bool) {
            self.hasSubtitle = hasSubtitle
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func update(hasSubtitle: Bool) {
            guard hasSubtitle != self.hasSubtitle else { return }
            self.hasSubtitle = hasSubtitle
            DispatchQueue.main.async { [weak self] in
                guard let navigation = self?.enclosingNavigationController() else { return }
                navigation.view.setNeedsLayout()
                navigation.view.layoutIfNeeded()
            }
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

// MARK: - Banners

/// What the banner over a pull request's or an issue's detail says.
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

/// When a list was read, as the footer, the title bar's status, a detail's
/// banner and the Host menu say it.
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

    /// "Read at 14:05 from studio-mac".
    func footer(host: String) -> String {
        switch day {
        case .today: String(localized: "Read at \(time) from \(host)")
        case .yesterday: String(localized: "Read yesterday at \(time) from \(host)")
        case .earlier(let date): String(localized: "Read on \(date) at \(time) from \(host)")
        }
    }

    /// "Read yesterday at 18:40", after the status under the title.
    var read: String {
        switch day {
        case .today: String(localized: "Read at \(time)")
        case .yesterday:
            String(
                localized: "Read yesterday at \(time)",
                comment: "After a Host's status under the GitHub tab's title: when the list shown was read.")
        case .earlier(let date):
            String(
                localized: "Read on \(date) at \(time)",
                comment: "After a Host's status under the GitHub tab's title: when the list shown was read.")
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
/// selected Host has a status, the button carries its glyph on amber.
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
            // Beside a glyph the amber's margin stands in for most of the
            // padding, so the button grows by less than the glyph.
            .padding(.horizontal, status == nil ? 6 : 2)
            // An iPad sidebar's bar moves a wider button into its overflow
            // menu, so a long name, or one beside a status glyph, gives way.
            .frame(maxWidth: isSidebarColumn ? Self.sidebarWidth : nil)
            .background {
                // Out to just inside the glass. iOS 26 cuts a toolbar
                // label off about 6 points to either side of it, which
                // would square off a wider capsule's ends.
                if status != nil {
                    Capsule()
                        .fill(Self.amberFill)
                        .padding(.horizontal, -5)
                        .padding(.vertical, -6)
                }
            }
        }
        .accessibilityLabel("GitHub Host")
        .accessibilityValue([selected?.name, status?.title].compactMap(\.self).joined(separator: ", "))
    }

    /// Behind the selected Host's name while it has a status: a pale amber
    /// under dark text, a dim one under light text.
    private static let amberFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 214 / 255, blue: 10 / 255, alpha: 0.16)
            : UIColor(red: 1, green: 241 / 255, blue: 194 / 255, alpha: 1)
    })

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
