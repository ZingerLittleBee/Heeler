import SwiftUI

/// Words and checks the Accounts screen shares with Usage (#621).
enum AccountsListing {
    static func footer(for kind: SupportedAgentKind, variable: String?) -> String {
        let defaultLine =
            HostAccountsStore.usageKinds.contains(kind)
            ? "Default is the folder \(kind.displayName) uses in herdr’s environment. It can be renamed, not removed."
            : "Default is the folder \(kind.displayName) picks itself."
        guard let variable else {
            return defaultLine + " Name the variable \(kind.displayName) reads its folder from to launch an Account."
        }
        return defaultLine + " A Launch Preset with an Account sets \(variable) to its folder."
    }

    static let suggestionsFooter =
        "Folders that hold a sign-in or Transcripts. None counts until you add it."
    static var fullFooter: String { AgentAccountError.limitReached.message }

    /// The Usage view's notice while the Host suggests directories; nil
    /// while there is none, or the plugin predates Accounts.
    static func noticeTitle(state: AgentUsageStore.State, supportsAccounts: Bool) -> String? {
        guard supportsAccounts, case .available(let report) = state else { return nil }
        let count = (report.programs ?? []).reduce(0) { $0 + ($1.accountSuggestions?.count ?? 0) }
        switch count {
        case 0: return nil
        case 1: return "Found 1 Account folder"
        default: return "Found \(count.formatted()) Account folders"
        }
    }

    /// Why an Account adds nothing to Usage, under its directory; nil while
    /// it counts or Usage does not say.
    static func stateLine(_ state: AgentUsageReport.Account.State?) -> String? {
        switch state {
        case .ok?, nil: nil
        case .missing?: "Directory not found"
        case .duplicate?: "Same directory as another Account"
        case .overLimit?, .other?: "Not counted"
        }
    }

    /// Where a suggestion was found, with its symbol.
    static func sourceLine(_ source: AgentUsageReport.AccountSuggestion.Source) -> (text: String, symbol: String)? {
        switch source {
        case .agent: ("Used by a running Agent", "sparkles")
        case .home: ("In your home folder", "house")
        case .other: nil
        }
    }

    /// `directory` with `~` for the Host's home folder.
    static func displayDirectory(_ directory: String, home: String?) -> String {
        guard var home, home.count > 1 else { return directory }
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        if directory == home { return "~" }
        guard directory.hasPrefix(home + "/") else { return directory }
        return "~" + directory.dropFirst(home.count)
    }

    /// The rename alert's message and whether Save keeps `name`. `isTaken`
    /// is the store's answer for the same name.
    static func renameCheck(
        _ name: String, for row: HostAccountsStore.Row, hostName: String, isTaken: Bool
    ) -> (message: String, canSave: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTaken {
            let shown = trimmed.isEmpty ? AgentUsageReport.Account.defaultDisplayName : trimmed
            return ("Another Account on \(hostName) is named \(shown).", false)
        }
        return (
            "Names appear in Usage, widgets and Launch Presets. Each Account of a harness on \(hostName) needs its own.",
            row.isDefault || !trimmed.isEmpty
        )
    }
}

/// One Host's Accounts for every harness: tap one to rename it, swipe or
/// press an added one to remove it, add or ignore a suggestion, choose a
/// folder, or add Accounts for another harness. Each change saves the
/// Host's Account file; Usage, Chat and Launch Presets read it from there.
struct HostAccountsView: View {
    let hostName: String
    let store: HostAccountsStore
    /// The Host's Usage, refreshed on open so its suggestions show; nil
    /// while Usage is off.
    var usage: AgentUsageStore?
    /// Pushed in an enclosing stack; otherwise the sheet brings its own,
    /// with a Close button.
    var isPushed = true
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Renaming?
    @State private var draftName = ""
    @State private var removing: Renaming?
    @State private var editingVariable: SupportedAgentKind?
    @State private var draftVariable = ""
    @State private var browsing: Browsing?
    /// A directory chosen in the browser is being checked and added.
    @State private var isAddingDirectory = false
    /// Harnesses added from the menu that have no Account yet.
    @State private var addedKinds: [SupportedAgentKind] = []
    /// On screen; until then a failure is not this screen's to show.
    @State private var isShown = false

    struct Renaming: Identifiable, Equatable {
        let kind: SupportedAgentKind
        let row: HostAccountsStore.Row
        var id: String { "\(kind.rawValue).\(row.id)" }
    }

    struct Browsing: Identifiable {
        let kind: SupportedAgentKind
        let browser: RemoteDirectoryBrowser
        var id: ObjectIdentifier { ObjectIdentifier(browser) }
    }

    private var kinds: [SupportedAgentKind] {
        store.shownKinds + addedKinds.filter { !store.shownKinds.contains($0) }
    }

    var body: some View {
        if isPushed {
            list
        } else {
            NavigationStack {
                list.toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            if case .failed(let message) = store.loadState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(kinds) { @Sendable kind in
                MainActorContent { section(for: kind) }
            }
            Section {
                Menu {
                    ForEach(SupportedAgentKind.allCases.filter { !kinds.contains($0) }) { kind in
                        Button(kind.displayName) { addedKinds.append(kind) }
                    }
                } label: {
                    Label("Add Accounts for Another Harness", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("accounts.addHarness")
            } footer: {
                Text("Each harness keeps up to four Accounts on a Host. Chat finds conversations in all of them.")
            }
        }
        .listStyle(.insetGrouped)
        .modifier(HostAccountsTitle(hostName: hostName))
        .modifier(HostAccountsDialogs(
            hostName: hostName, store: store, renaming: $renaming, draftName: $draftName,
            editingVariable: $editingVariable, draftVariable: $draftVariable,
            isAlertActive: isShown && browsing == nil))
        .sheet(item: $browsing) { browsing in
            RemoteDirectoryBrowserView(
                browser: browsing.browser, purpose: .account(browsing.kind), isUsing: isAddingDirectory
            ) { path in
                Task { await add(path, for: browsing.kind, from: browsing.browser) }
            }
            .modifier(AccountChangeFailureAlert(store: store))
        }
        .task {
            await store.load()
            if let usage, usage.state == .idle { await usage.pullToRefresh() }
        }
        .refreshable {
            await store.load()
            await usage?.pullToRefresh()
        }
        .onAppear {
            store.changeFailure = nil
            isShown = true
        }
        .onDisappear {
            isShown = false
            store.changeFailure = nil
        }
    }

    @ViewBuilder
    private func section(for kind: SupportedAgentKind) -> some View {
        let rows = store.rows(for: kind)
        let suggestions = store.suggestions(for: kind)
        let isFull = store.isFull(kind)
        Section {
            ForEach(rows) { @Sendable row in
                MainActorContent { accountRow(row, kind: kind) }
            }
            // Keeps a row's words in their own colors instead of the tint.
            .buttonStyle(.plain)
            ForEach(suggestions) { @Sendable suggestion in
                MainActorContent { suggestionRow(suggestion, kind: kind, isFull: isFull) }
            }
            variableRow(kind)
            Button("Choose a Folder…", systemImage: "folder.badge.plus") {
                if let browser = store.directoryBrowser() { browsing = Browsing(kind: kind, browser: browser) }
            }
            .foregroundStyle(isFull ? Color(uiColor: .tertiaryLabel) : Color.accentColor)
            .disabled(isFull)
            .accessibilityIdentifier("accounts.\(kind.rawValue).choose")
        } header: {
            Text(kind.displayName)
        } footer: {
            Text(isFull ? AccountsListing.fullFooter : AccountsListing.footer(for: kind, variable: store.variable(for: kind)))
        }
    }

    private func accountRow(_ row: HostAccountsStore.Row, kind: SupportedAgentKind) -> some View {
        let isChanging = store.isChanging(.account(kind, row.id))
        return Button {
            rename(row, kind: kind)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName).foregroundStyle(.primary)
                    if let directory = row.directory {
                        directoryText(directory)
                    } else {
                        Text("\(kind.displayName)’s own folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let line = AccountsListing.stateLine(row.state) {
                        detailLine(line) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 8)
                if isChanging { ProgressView() }
            }
            .contentShape(.rect)
        }
        .disabled(isChanging)
        .accessibilityHint("Rename")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !row.isDefault && !isChanging {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    removing = Renaming(kind: kind, row: row)
                }
            }
        }
        .contextMenu {
            Group {
                Button("Rename", systemImage: "pencil") { rename(row, kind: kind) }
                if !row.isDefault {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        removing = Renaming(kind: kind, row: row)
                    }
                }
            }
            .disabled(isChanging)
        }
        .confirmationDialog(
            "Remove \(row.displayName)?",
            isPresented: Binding(
                get: { removing == Renaming(kind: kind, row: row) },
                set: { if !$0, removing == Renaming(kind: kind, row: row) { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                Task { await store.remove(row, for: kind) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Usage, Chat and Launch Presets stop using it. The folder and its sign-in stay on \(hostName).")
        }
    }

    private func rename(_ row: HostAccountsStore.Row, kind: SupportedAgentKind) {
        draftName = row.name ?? ""
        renaming = Renaming(kind: kind, row: row)
    }

    @ViewBuilder
    private func variableRow(_ kind: SupportedAgentKind) -> some View {
        let variable = store.variable(for: kind)
        Button {
            draftVariable = variable ?? ""
            editingVariable = kind
        } label: {
            LabeledContent {
                if store.isChanging(.variable(kind)) {
                    ProgressView()
                } else {
                    Text(variable ?? "Not Set")
                        .font(variable == nil ? .body : .body.monospaced())
                        .foregroundStyle(variable == nil ? .orange : .secondary)
                }
            } label: {
                Text("Folder Variable").foregroundStyle(.primary)
            }
        }
        .accessibilityIdentifier("accounts.\(kind.rawValue).variable")
    }

    private func suggestionRow(
        _ suggestion: AgentUsageReport.AccountSuggestion, kind: SupportedAgentKind, isFull: Bool
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name)
                directoryText(suggestion.directory)
                if let source = AccountsListing.sourceLine(suggestion.source) {
                    detailLine(source.text) {
                        Image(systemName: source.symbol).foregroundStyle(.secondary)
                    }
                }
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if store.isChanging(.directory(kind, suggestion.directory)) {
                ProgressView()
            } else {
                Button("Ignore") {
                    Task { await store.ignore(suggestion, for: kind) }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .accessibilityLabel("Ignore \(suggestion.name)")
                Button {
                    Task { await store.add(suggestion, for: kind) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").imageScale(.small)
                        Text("Add")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(isFull)
                .accessibilityLabel("Add \(suggestion.name)")
            }
        }
    }

    private func detailLine(_ text: String, @ViewBuilder symbol: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            symbol().imageScale(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.top, 1)
    }

    private func directoryText(_ directory: String) -> some View {
        Text(AccountsListing.displayDirectory(directory, home: store.hostHome))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Adds the browser's folder: closes it once added, says in place why
    /// a folder was refused, and keeps it open under the failure alert.
    private func add(_ directory: String, for kind: SupportedAgentKind, from browser: RemoteDirectoryBrowser) async {
        isAddingDirectory = true
        defer { isAddingDirectory = false }
        switch await store.add(directory: directory, for: kind) {
        case .added: browsing = nil
        case .refused(let refusal): browser.refusal = refusal.message
        case .failed: break
        }
    }
}

/// "Accounts" over the Host's name.
private struct HostAccountsTitle: ViewModifier {
    let hostName: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationTitle("Accounts")
                .navigationSubtitle(hostName)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .navigationTitle("Accounts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Accounts").font(.headline)
                            Text(hostName).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
    }
}

/// The rename and variable alerts, and the failure alert, which yields to
/// the directory browser's own while that is open.
private struct HostAccountsDialogs: ViewModifier {
    let hostName: String
    let store: HostAccountsStore
    @Binding var renaming: HostAccountsView.Renaming?
    @Binding var draftName: String
    @Binding var editingVariable: SupportedAgentKind?
    @Binding var draftVariable: String
    let isAlertActive: Bool

    func body(content: Content) -> some View {
        content
            .alert("Rename Account", isPresented: isPresent($renaming), presenting: renaming) { renaming in
                // Left empty, the Default Account is "Default" again.
                TextField(
                    renaming.row.isDefault ? AgentUsageReport.Account.defaultDisplayName : "Name", text: $draftName
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Save") { save(renaming) }
                    .disabled(!check(renaming).canSave)
                    .keyboardShortcut(.defaultAction)
            } message: { renaming in
                Text(check(renaming).message)
            }
            .alert("Folder Variable", isPresented: isPresent($editingVariable), presenting: editingVariable) { kind in
                TextField(kind.configDirectoryVariable ?? "VARIABLE_NAME", text: $draftVariable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .font(.body.monospaced())
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let variable = draftVariable
                    Task { await store.setVariable(variable, for: kind) }
                }
                .keyboardShortcut(.defaultAction)
            } message: { kind in
                Text(
                    "The environment variable \(kind.displayName) reads its settings folder from. "
                        + (kind.configDirectoryVariable.map { "Left empty, Heeler uses \($0)." }
                            ?? "Launch Presets set it to an Account’s folder."))
            }
            .modifier(AccountChangeFailureAlert(store: store, isActive: isAlertActive))
    }

    private func check(_ renaming: HostAccountsView.Renaming) -> (message: String, canSave: Bool) {
        AccountsListing.renameCheck(
            draftName, for: renaming.row, hostName: hostName,
            isTaken: store.isNameTaken(draftName, renaming: renaming.row, for: renaming.kind))
    }

    private func save(_ renaming: HostAccountsView.Renaming) {
        let name = draftName
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != (renaming.row.name ?? "") else { return }
        Task { await store.rename(renaming.row, to: name, for: renaming.kind) }
    }

    private func isPresent<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Why the last Account change could not be saved; dismissing it clears
/// the failure.
struct AccountChangeFailureAlert: ViewModifier {
    let store: HostAccountsStore
    var isActive = true

    func body(content: Content) -> some View {
        content.alert(
            "Couldn’t Change Accounts",
            isPresented: Binding(
                get: { isActive && store.changeFailure != nil },
                set: { if !$0 { store.changeFailure = nil } }),
            presenting: store.changeFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }
}

/// The Usage view's row while a Host suggests Account folders; it opens
/// the Host's Accounts, the same screen Settings › Agents & Accounts shows.
struct AccountsNotice: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("usage.accounts.notice")
    }
}

/// Finds a Host's Accounts store; the Console provides it app-wide.
struct HostAccountsProvider: @unchecked Sendable {
    let store: @MainActor (Host.ID) -> HostAccountsStore
}

extension EnvironmentValues {
    @Entry var hostAccounts: HostAccountsProvider?
}

/// Presents a Host's Accounts as a sheet while `hostID` names one of
/// `entries`; a form sheet on an iPad.
struct HostAccountsSheetPresenter: ViewModifier {
    @Binding var hostID: Host.ID?
    let entries: [AgentUsageHostEntry]
    @Environment(\.hostAccounts) private var hostAccounts

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { hostID != nil }, set: { if !$0 { hostID = nil } })) {
            if let entry = entries.first(where: { $0.id == hostID }), let hostAccounts {
                HostAccountsView(
                    hostName: entry.name, store: hostAccounts.store(entry.id), usage: entry.store, isPushed: false
                )
                .presentationSizing(.form)
            }
        }
    }
}
