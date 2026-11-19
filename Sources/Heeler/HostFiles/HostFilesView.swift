import SwiftUI
import UIKit

/// Files: a sheet over an Agent that browses its Host's folders, one page a
/// folder, starting in the Agent's directory. Read-only; a file opens in a
/// preview over the sheet.
struct HostFilesView: View {
    @Bindable var browser: HostFilesBrowser
    /// The Host's connection is up, as the Agent detail sees it.
    let isHostConnected: Bool
    /// Puts a file's path in the Agent's message and closes Files; nil where
    /// nothing takes one.
    var insertPath: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isAskingForFolder = false
    @State private var typedFolder = ""

    var body: some View {
        NavigationStack(path: $browser.path) {
            page(for: "/")
                .navigationDestination(for: HostFilesBrowser.Route.self) { route in
                    page(for: route.directory)
                }
        }
        .fullScreenCover(item: preview) { preview in
            HostFilePreviewView(
                preview: preview,
                insertPath: insertPath.map { insert in
                    { insert(browser.reference(to: preview.path)) }
                })
        }
        .alert("Go to Folder", isPresented: $isAskingForFolder) {
            TextField("Path", text: $typedFolder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Go") { browser.go(toTyped: typedFolder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A path on the Host. ~ is the home directory.")
        }
        .alert("Can't Open", isPresented: notice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.notice ?? "")
        }
        // From the first value: the connection may have come back between
        // the tap that opened Files and this page.
        .onChange(of: isHostConnected, initial: true) { _, isConnected in
            browser.hostConnectionChanged(isConnected)
        }
    }

    private func page(for directory: String) -> some View {
        HostFolderPage(
            browser: browser,
            folder: browser.folder(at: directory),
            askForFolder: {
                typedFolder = ""
                isAskingForFolder = true
            },
            close: { dismiss() }
        )
        .id(directory)
    }

    private var preview: Binding<HostFilePreview?> {
        Binding(
            get: { browser.preview },
            set: { if $0 == nil { browser.closePreview() } })
    }

    private var notice: Binding<Bool> {
        Binding(
            get: { browser.notice != nil },
            set: { if !$0 { browser.notice = nil } })
    }
}

/// One folder's page.
private struct HostFolderPage: View {
    let browser: HostFilesBrowser
    @Bindable var folder: HostFolder
    let askForFolder: () -> Void
    let close: () -> Void
    @AppStorage(HostFileSort.defaultsKey) private var sort = HostFileSort.name
    @AppStorage(HostFileSort.showsHiddenKey) private var showsHidden = false
    @State private var isFiltering = false

    private var isHostConnected: Bool { browser.isHostConnected }

    var body: some View {
        let rows = folder.rows(sortedBy: sort, showingHidden: showsHidden)
        List {
            if folder.phase == .loaded, !rows.isEmpty {
                Section {
                    // Read once for the page, so every row tells time alike.
                    let now = Date.now
                    let following = browser.following
                    ForEach(rows) { @Sendable entry in
                        MainActorContent {
                            Button { browser.open(entry) } label: {
                                HostFileRow(entry: entry, isFollowing: following == entry.path, now: now)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isHostConnected)
                            // Two lines a row, close enough to scan a long folder.
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            .contextMenu {
                                Button("Copy Path", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = entry.path
                                }
                            }
                            .accessibilityIdentifier("host-files-row-\(entry.name)")
                        }
                    }
                } header: {
                    if !isHostConnected {
                        // A note above the rows, laid out as a row is so it
                        // lines up with the names under it.
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: "wifi.slash")
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            Text("The Host is not connected. This is the folder as Files last read it.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))
                        .accessibilityIdentifier("host-files-not-connected")
                    }
                } footer: {
                    footer(shown: rows.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("host-files-folder")
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .contentMargins(.top, 8, for: .scrollContent)
        .refreshable {
            // A pull with no connection would trade the rows for an error.
            // Asked of the browser: this action keeps the page it first saw.
            if browser.isHostConnected { await folder.refresh() }
        }
        .overlay { stateOverlay(isEmpty: rows.isEmpty) }
        .searchable(
            text: $folder.filter,
            isPresented: $isFiltering,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "Filter this folder"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .scrollDismissesKeyboard(.interactively)
        // The Back button's name for this page.
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HostFolderTitle(name: folder.name, path: folder.path)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                options
                Button("Close", systemImage: "xmark", action: close)
                    .accessibilityIdentifier("host-files-close")
            }
        }
        // By folder: a path that changes under a page the stack kept showing
        // would otherwise never be read.
        .task(id: folder.path) {
            // Without a connection the page waits: `hostReconnected` reads it.
            if browser.isHostConnected { folder.loadIfNeeded() }
        }
    }

    private var options: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                Text("Name").tag(HostFileSort.name)
                Text("Date Modified").tag(HostFileSort.modified)
                Text("Size").tag(HostFileSort.size)
            }
            .pickerStyle(.inline)
            Section {
                Toggle("Show Hidden Files", systemImage: "eye", isOn: $showsHidden)
            }
            Section {
                Button("Agent Directory", systemImage: "apple.terminal") {
                    browser.go(to: browser.agentDirectory)
                }
                .disabled(folder.path == browser.agentDirectory)
                Button("Home", systemImage: "house") { browser.goHome() }
                Button("Go to Folder…", systemImage: "arrow.right.to.line", action: askForFolder)
            }
            .disabled(!isHostConnected)
            Section {
                Button("Copy Path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = folder.path
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("host-files-options")
    }

    @ViewBuilder
    private func footer(shown: Int) -> some View {
        let hidden = showsHidden ? 0 : folder.hiddenCount
        VStack(alignment: .leading, spacing: 4) {
            if !folder.filter.isEmpty {
                Text("Showing \(shown) of \(folder.entries.count)")
            } else if hidden > 0 {
                Text(
                    verbatim: [
                        String(localized: "\(shown) items"),
                        String(
                            localized: "\(hidden) hidden",
                            comment: "How many of a folder's items Files is not showing because their names start with a dot."),
                    ].joinedAsPhrases())
            } else {
                Text("\(shown) items")
            }
            if folder.isPartial {
                Text("This folder holds more than Files lists. Sorting and filtering cover only the items listed.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func stateOverlay(isEmpty: Bool) -> some View {
        switch folder.phase {
        case .idle where !isHostConnected:
            ContentUnavailableView {
                Label("Not Connected", systemImage: "wifi.slash")
            } description: {
                Text("Files reads this folder when the Host is connected.")
            }
        case .idle, .loading:
            ProgressView("Reading Folder…")
        case .failed(let failure):
            failureState(failure)
                .disabled(!isHostConnected)
        case .loaded:
            if isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func failureState(_ failure: HostFilesFailure) -> some View {
        switch failure {
        case .unavailable:
            ContentUnavailableView {
                Label("Files Unavailable", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text("This Host's SSH server offers no SFTP, which Files, Chat and attachments all use. Turn on SFTP in the server's settings, then check again.")
            } actions: {
                // Asked for, never repeated on its own: each attempt costs
                // the Host's connection (#596).
                Button("Check Again") { folder.reload() }
                    .accessibilityIdentifier("host-files-check-again")
            }
        case .missing:
            ContentUnavailableView {
                Label("Folder Not Found", systemImage: "questionmark.folder")
            } description: {
                Text("“\(folder.path)” is not on the Host.")
            } actions: {
                Button("Try Again") { folder.reload() }
            }
        case .denied:
            ContentUnavailableView {
                Label("Can't Open This Folder", systemImage: "lock")
            } description: {
                Text("The Host's account is not allowed to list it.")
            } actions: {
                Button("Try Again") { folder.reload() }
            }
        case .other(let message):
            ContentUnavailableView {
                Label("Couldn't Read This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { folder.reload() }
                    .accessibilityIdentifier("host-files-try-again")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !folder.filter.isEmpty {
            ContentUnavailableView {
                Label("No Matching Items", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing listed here matches “\(folder.filter)”.")
            } actions: {
                Button("Clear Filter") { folder.filter = "" }
            }
        } else if folder.entries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else {
            ContentUnavailableView {
                Label("Hidden Files Only", systemImage: "eye.slash")
            } description: {
                Text("Every item here starts with a dot.")
            } actions: {
                Button("Show Hidden Files") { showsHidden = true }
            }
        }
    }
}

/// A folder page's title: its name, with where it is beneath.
private struct HostFolderTitle: View {
    let name: String
    let path: String

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if path != "/" {
                Text(verbatim: path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One name in a folder: what it is, and beneath it its size and when it
/// last changed, marked when that was moments ago.
private struct HostFileRow: View {
    let entry: HostFileEntry
    let isFollowing: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isFollowing {
                ProgressView()
            } else if entry.kind == .directory {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.kind == .directory ? Text("Opens the folder") : Text("Opens a preview"))
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.kind {
        case .directory:
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        case .symlink:
            Image(systemName: "arrow.up.right.square")
                .font(.title3)
                .foregroundStyle(.secondary)
        default:
            Image(systemName: HostFileKind(name: entry.name).symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let size = entry.kind == .regular ? entry.size.map(HostFileFormat.size) : nil
        let kindNote = entry.kind == .symlink ? String(localized: "Link") : nil
        let lead = [kindNote, size].compactMap { $0 }.joined(separator: " · ")
        if let modified = entry.modified {
            let time = HostFileFormat.modified(modified, now: now)
            if HostFileFormat.isRecent(modified, now: now) {
                HStack(spacing: 4) {
                    if !lead.isEmpty {
                        Text(verbatim: lead + " ·")
                            .accessibilityLabel(Text(verbatim: lead))
                    }
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(verbatim: time)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Changed \(time)")
                }
            } else {
                Text(verbatim: lead.isEmpty ? time : lead + " · " + time)
            }
        } else if !lead.isEmpty {
            Text(verbatim: lead)
        }
    }
}
