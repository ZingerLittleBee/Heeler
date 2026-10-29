import SwiftUI

/// What the Claude Code Accounts sheet lists for one Host's reading: the
/// Accounts in the report's order (the Default Account first), the
/// suggestions not yet added or ignored, and whether another Account fits
/// (ADR 0030).
struct ClaudeAccountsListing: Equatable {
    let accounts: [AgentUsageReport.Account]
    let suggestions: [AgentUsageReport.AccountSuggestion]

    init(report: AgentUsageReport?) {
        let program = report?.claudeProgram
        accounts = program?.accounts ?? []
        suggestions = program?.accountSuggestions ?? []
    }

    init(state: AgentUsageStore.State) {
        if case .available(let report) = state {
            self.init(report: report)
        } else {
            self.init(report: nil)
        }
    }

    /// The Default Account and three added ones: Add and Choose Another
    /// Directory… stay off until one is removed. Ignore stays available.
    var isFull: Bool {
        accounts.count(where: { !$0.isDefault }) >= UsageAccountFile.accountLimit
    }

    static let accountsFooter =
        "Default is the directory Claude Code uses in herdr’s environment. It can be renamed, not removed."
    static let suggestionsFooter =
        "Directories that hold a Claude Code sign-in or Transcripts. None counts until you add it."
    static var fullFooter: String { ClaudeAccountError.limitReached.message }

    /// The Usage view's notice while the Host suggests directories; nil
    /// while there is none, or the plugin predates Accounts.
    static func noticeTitle(state: AgentUsageStore.State, supportsAccounts: Bool) -> String? {
        guard supportsAccounts else { return nil }
        switch Self(state: state).suggestions.count {
        case 0: return nil
        case 1: return "Found 1 Claude Code directory"
        case let count: return "Found \(count.formatted()) Claude Code directories"
        }
    }

    /// Why an Account adds nothing, under its directory; nil while it counts.
    static func stateLine(_ state: AgentUsageReport.Account.State) -> String? {
        switch state {
        case .ok: nil
        case .missing: "Directory not found"
        case .duplicate: "Same directory as another Account"
        case .overLimit, .other: "Not counted"
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
        _ name: String, for account: AgentUsageReport.Account, hostName: String, isTaken: Bool
    ) -> (message: String, canSave: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTaken {
            let shown = trimmed.isEmpty ? AgentUsageReport.Account.defaultDisplayName : trimmed
            return ("Another Account on \(hostName) is named \(shown).", false)
        }
        return (
            "Names appear in Usage, Usage Limits and widgets. Each Account on \(hostName) needs its own.",
            account.isDefault || !trimmed.isEmpty
        )
    }
}

/// A Host's Claude Code Accounts: tap one to rename it, swipe or press an
/// added one to remove it, add or ignore a suggestion, or choose another
/// directory. Each change saves the Host's Account file and reads Usage
/// again; the row shows a spinner until that read lands.
struct ClaudeAccountsSheet: View {
    let hostName: String
    let store: AgentUsageStore
    /// Pushed in the Usage Limits sheet's stack; otherwise the sheet brings
    /// its own, with a Close button.
    var isPushed = false
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: AgentUsageReport.Account?
    @State private var draftName = ""
    @State private var removing: AgentUsageReport.Account?
    @State private var browser: RemoteDirectoryBrowser?
    /// A directory chosen in the browser is being checked and added.
    @State private var isAddingDirectory = false

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
        let listing = ClaudeAccountsListing(state: store.state)
        return List {
            Section {
                if listing.accounts.isEmpty {
                    AgentUsageContent(state: store.state)
                }
                ForEach(listing.accounts) { @Sendable account in
                    MainActorContent { accountRow(account) }
                }
                // Not on the rows: their content is Sendable, and `.plain` is
                // isolated to the main actor. It keeps a row's words in their
                // own colors instead of the button tint.
                .buttonStyle(.plain)
            } header: {
                Text("Accounts")
            } footer: {
                Text(ClaudeAccountsListing.accountsFooter)
            }
            if !listing.suggestions.isEmpty {
                Section {
                    ForEach(listing.suggestions) { @Sendable suggestion in
                        MainActorContent { suggestionRow(suggestion, isFull: listing.isFull) }
                    }
                } header: {
                    Text("Suggestions")
                } footer: {
                    Text(ClaudeAccountsListing.suggestionsFooter)
                }
            }
            Section {
                let canChoose = !listing.isFull && store.supportsClaudeAccounts
                Button("Choose Another Directory…", systemImage: "folder.badge.plus") {
                    browser = store.accountDirectoryBrowser()
                }
                // A disabled list button keeps its title dark; dim it like
                // a full Host's Add buttons.
                .foregroundStyle(canChoose ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                .disabled(!canChoose)
                .accessibilityIdentifier("usage.accounts.choose")
            } footer: {
                if listing.isFull { Text(ClaudeAccountsListing.fullFooter) }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(ClaudeAccountsTitle(hostName: hostName))
        .modifier(ClaudeAccountsDialogs(
            hostName: hostName, store: store, renaming: $renaming, draftName: $draftName,
            isAlertActive: browser == nil))
        .sheet(item: $browser) { browser in
            RemoteDirectoryBrowserView(browser: browser, purpose: .claudeAccount, isUsing: isAddingDirectory) { path in
                Task { await add(path, from: browser) }
            }
            .modifier(ClaudeAccountChangeFailureAlert(store: store))
        }
        .task { await store.loadHostHome() }
    }

    private func accountRow(_ account: AgentUsageReport.Account) -> some View {
        let isChanging = store.isChangingAccount(.account(account.id))
        return Button {
            rename(account)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .foregroundStyle(.primary)
                    directoryText(account.directory)
                    if let line = ClaudeAccountsListing.stateLine(account.state) {
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
        .modifier(ClaudeAccountRowActions(
            account: account, hostName: hostName, store: store, isChanging: isChanging, removing: $removing,
            rename: { rename(account) }))
    }

    private func rename(_ account: AgentUsageReport.Account) {
        draftName = account.name ?? ""
        renaming = account
    }

    private func suggestionRow(_ suggestion: AgentUsageReport.AccountSuggestion, isFull: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name)
                directoryText(suggestion.directory)
                if let source = ClaudeAccountsListing.sourceLine(suggestion.source) {
                    detailLine(source.text) {
                        Image(systemName: source.symbol).foregroundStyle(.secondary)
                    }
                }
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if store.isChangingAccount(.directory(suggestion.directory)) {
                ProgressView()
            } else {
                Button("Ignore") {
                    Task { await store.ignoreSuggestion(suggestion) }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .accessibilityLabel("Ignore \(suggestion.name)")
                Button {
                    Task { await store.addAccount(suggestion) }
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

    /// A row's third line: a state or source, its symbol beside it.
    private func detailLine(_ text: String, @ViewBuilder symbol: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            symbol().imageScale(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.top, 1)
    }

    private func directoryText(_ directory: String) -> some View {
        Text(ClaudeAccountsListing.displayDirectory(directory, home: store.hostHome))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Adds the browser's folder: closes it once added, says in place why
    /// a folder was refused, and keeps it open under the failure alert.
    private func add(_ directory: String, from browser: RemoteDirectoryBrowser) async {
        isAddingDirectory = true
        defer { isAddingDirectory = false }
        switch await store.addAccount(directory: directory) {
        case .added: self.browser = nil
        case .refused(let refusal): browser.refusal = refusal.message
        case .failed: break
        }
    }
}

/// "Claude Code Accounts" over the Host's name.
private struct ClaudeAccountsTitle: ViewModifier {
    let hostName: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationTitle("Claude Code Accounts")
                .navigationSubtitle(hostName)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
                .navigationTitle("Claude Code Accounts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Claude Code Accounts").font(.headline)
                            Text(hostName).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
    }
}

/// An Account row's swipe action and menu, and the confirmation before
/// removing it, which points at the row it removes. The Default Account
/// can only be renamed, and a row being saved waits for its last change.
private struct ClaudeAccountRowActions: ViewModifier {
    let account: AgentUsageReport.Account
    let hostName: String
    let store: AgentUsageStore
    let isChanging: Bool
    @Binding var removing: AgentUsageReport.Account?
    let rename: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !account.isDefault && !isChanging {
                    Button("Remove", systemImage: "trash", role: .destructive) { removing = account }
                }
            }
            .contextMenu {
                Group {
                    Button("Rename", systemImage: "pencil", action: rename)
                    if !account.isDefault {
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = account }
                    }
                }
                .disabled(isChanging)
            }
            .confirmationDialog("Remove \(account.displayName)?", isPresented: isRemoving, titleVisibility: .visible) {
                Button("Remove Account", role: .destructive) {
                    Task { await store.removeAccount(account) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its Token Usage and Usage Limits stop showing. The directory and its sign-in stay on \(hostName).")
            }
    }

    private var isRemoving: Binding<Bool> {
        Binding(
            get: { removing?.id == account.id },
            set: { if !$0, removing?.id == account.id { removing = nil } })
    }
}

/// The Accounts sheet's rename alert and failure alert. The failure alert
/// yields to the directory browser's own while that is open.
private struct ClaudeAccountsDialogs: ViewModifier {
    let hostName: String
    let store: AgentUsageStore
    @Binding var renaming: AgentUsageReport.Account?
    @Binding var draftName: String
    let isAlertActive: Bool

    func body(content: Content) -> some View {
        content
            .alert("Rename Account", isPresented: isPresent($renaming), presenting: renaming) { account in
                // Left empty, the Default Account is "Default" again.
                TextField(account.isDefault ? AgentUsageReport.Account.defaultDisplayName : "Name", text: $draftName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Save") { save(account) }
                    .disabled(!check(account).canSave)
                    .keyboardShortcut(.defaultAction)
            } message: { account in
                // A presented alert keeps the message it opened with; only
                // Save follows the draft.
                Text(check(account).message)
            }
            .modifier(ClaudeAccountChangeFailureAlert(store: store, isActive: isAlertActive))
    }

    private func check(_ account: AgentUsageReport.Account) -> (message: String, canSave: Bool) {
        ClaudeAccountsListing.renameCheck(
            draftName, for: account, hostName: hostName,
            isTaken: store.isAccountNameTaken(draftName, renaming: account))
    }

    private func save(_ account: AgentUsageReport.Account) {
        let name = draftName
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != (account.name ?? "") else { return }
        Task { await store.renameAccount(account, to: name) }
    }

    private func isPresent(_ item: Binding<AgentUsageReport.Account?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Why the last Account change could not be saved; dismissing it clears
/// the failure.
struct ClaudeAccountChangeFailureAlert: ViewModifier {
    let store: AgentUsageStore
    var isActive = true

    func body(content: Content) -> some View {
        content.alert(
            "Couldn’t Change Accounts",
            isPresented: Binding(
                get: { isActive && store.accountChangeFailure != nil },
                set: { if !$0 { store.accountChangeFailure = nil } }),
            presenting: store.accountChangeFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }
}

/// The Usage view's row while a Host suggests Claude Code directories; it
/// opens the Host's Accounts.
struct ClaudeAccountsNotice: View {
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

/// Presents a Host's Claude Code Accounts as a sheet while `hostID` names
/// one of `entries`; a form sheet on an iPad.
struct ClaudeAccountsSheetPresenter: ViewModifier {
    @Binding var hostID: Host.ID?
    let entries: [AgentUsageHostEntry]

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { hostID != nil }, set: { if !$0 { hostID = nil } })) {
            if let entry = entries.first(where: { $0.id == hostID }) {
                ClaudeAccountsSheet(hostName: entry.name, store: entry.store)
                    .presentationSizing(.form)
            }
        }
    }
}
