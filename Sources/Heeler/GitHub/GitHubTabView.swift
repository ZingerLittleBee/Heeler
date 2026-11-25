import SwiftUI

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
            if store.hosts.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    GitHubHostMenu(store: store)
                }
            }
        }
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
        let banner = filter.isDefault
            ? state.list.flatMap { GitHubBannerText(failure: state.failure, isOffline: isOffline, host: host, list: $0) }
            : nil
        Section {
            if let banner {
                GitHubBanner(text: banner)
            }
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
        // With no banner this section is only the header, and the rows sit
        // as close under the chips as a banner would.
        .listSectionSpacing(banner == nil ? .custom(0) : .default)
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
                GitHubShowMoreRow(
                    shown: shown.list.items.count, total: shown.list.totalCount,
                    isReading: store.state(of: host).readingMore.contains(kind)
                ) { Task { await store.showMore(kind) } }
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
        Button("Clear Filters") { store.setFilter(GitHubListFilter(), for: kind) }
            // The iPad's sidebar greys its tint.
            .tint(GitHubFilterBar.accent)
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
                Spacer(minLength: 8)
                if isReading {
                    ProgressView()
                } else {
                    Text("\(shown) of \(total)", comment: "Under a GitHub list: rows shown of what GitHub found.")
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
            Button("Clear Filters", action: clearFilters)
                .tint(GitHubFilterBar.accent)
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

// MARK: - Banners

/// What a banner over a list read earlier says.
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

    /// Over a list read earlier. gh missing or signed out takes the list's
    /// place instead.
    init?(failure: GitHubReadFailure?, isOffline: Bool, host: GitHubHost, list: GitHubList) {
        switch failure {
        case .unsupported:
            guard isOffline else { return nil }
        default:
            break
        }
        self.init(failure: failure, isOffline: isOffline, host: host, readAt: list.readAt)
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
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return String(localized: "Pull to try again.") }
        let wait = Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
        return String(localized: "Try again in \(wait).")
    }
}

// MARK: - When a list was read

/// When a list was read, as the footer, banners and Host menu say it.
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

/// The Host the tab reads, with what each Host's gh last said.
private struct GitHubHostMenu: View {
    let store: GitHubStore

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
        } label: {
            HStack(spacing: 6) {
                Text(selected?.name ?? "")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .accessibilityLabel("GitHub Host")
        .accessibilityValue(selected?.name ?? "")
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
                comment: "A Host's status in the GitHub tab's Host menu: GitHub's rate limit stopped its read.")
        case .timedOut, .failed, .unsupported: return String(localized: "Could not read GitHub")
        default: return nil
        }
    }
}
