import SwiftUI

/// Browses remote folders and selects a Workspace draft, or a Claude Code
/// Account's directory. Starting the Agent remains a separate action on the
/// owning New Agent form.
struct RemoteDirectoryBrowserView: View {
    /// What the chosen folder is for, which sets the sheet's words.
    enum Purpose {
        /// A new Workspace's or Terminal's directory, filled into a form.
        case workspace
        /// A Claude Code Account, added as soon as it is chosen.
        case claudeAccount

        var title: String {
            switch self {
            case .workspace: "Browse Directories"
            case .claudeAccount: "Choose Directory"
            }
        }

        var useTitle: String {
            switch self {
            case .workspace: "Select"
            case .claudeAccount: "Add"
            }
        }

        var useLabel: String {
            switch self {
            case .workspace: "Select folder"
            case .claudeAccount: "Add folder as an Account"
            }
        }

        var emptyDescription: String {
            switch self {
            case .workspace: "You can select this folder for the new Workspace."
            case .claudeAccount: "You can add this folder as a Claude Code Account."
            }
        }
    }

    /// One listed folder, read before the rows are built.
    private struct Row: Hashable, Sendable {
        let name: String
        let isSymbolicLink: Bool
    }

    @Bindable var browser: RemoteDirectoryBrowser
    var purpose = Purpose.workspace
    /// The owner is still acting on the folder it was given.
    var isUsing = false
    var onUse: (String) -> Void
    @State private var isFiltering = false

    var body: some View {
        NavigationStack {
            List {
                if let currentPath = browser.currentPath {
                    Section {
                        locationRow(currentPath)
                    } footer: {
                        if let refusal = browser.refusal {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text(refusal)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("directory-browser-refusal")
                        }
                    }
                }

                if let errorMessage = browser.errorMessage {
                    Section {
                        Label("Couldn't Load Folders", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Try Again", action: browser.retry)
                            .accessibilityIdentifier("directory-browser-retry")
                    }
                }

                if browser.isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading folders…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if browser.currentPath != nil {
                    Section {
                        if browser.visibleDirectories.isEmpty {
                            emptyState
                        } else {
                            let rows = browser.visibleDirectories.map {
                                Row(name: $0, isSymbolicLink: browser.isSymbolicLink($0))
                            }
                            ForEach(rows, id: \.self) { @Sendable row in
                                let name = row.name
                                Button {
                                    browser.enter(name)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        Text(name)
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if row.isSymbolicLink {
                                            Image(systemName: "link")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("Symbolic link")
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.forward")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .accessibilityHint("Open folder")
                                .accessibilityIdentifier("directory-browser-folder-\(name)")
                            }
                            // Not on the rows: their content is Sendable, and `.plain`
                            // is isolated to the main actor.
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Folders")
                    } footer: {
                        if browser.truncated {
                            Text("Only part of this folder is available. Filtering searches the loaded folders only.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 8, for: .scrollContent)
            .searchable(
                text: $browser.filter,
                isPresented: $isFiltering,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Filter folders")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: browser.currentPath) { _, _ in
                isFiltering = false
            }
            .navigationTitle(purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isUsing {
                        ProgressView()
                    } else {
                        Button(purpose.useTitle) {
                            if let currentPath = browser.currentPath {
                                onUse(currentPath)
                            }
                        }
                        .accessibilityLabel(purpose.useLabel)
                        .accessibilityIdentifier("directory-browser-select")
                        .disabled(browser.currentPath == nil || browser.isLoading)
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear { browser.start() }
        .onDisappear { browser.cancel() }
    }

    private func locationRow(_ path: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(path.split(separator: "/").last.map(String.init) ?? "/")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("directory-browser-location")

            Button(action: browser.goBack) {
                Image(systemName: "arrow.up")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Parent folder")
            .accessibilityIdentifier("directory-browser-parent")
            .disabled(!browser.canGoBack || browser.isLoading)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if browser.filter.isEmpty {
            ContentUnavailableView {
                Label(browser.truncated ? "No Loaded Folders" : "No Subfolders", systemImage: "folder")
            } description: {
                Text(purpose.emptyDescription)
            }
        } else {
            ContentUnavailableView {
                Label("No Matching Folders", systemImage: "magnifyingglass")
            } description: {
                Text("No loaded folders match “\(browser.filter)”.")
            } actions: {
                Button("Clear Filter") { browser.filter = "" }
                    .accessibilityIdentifier("directory-browser-clear-filter")
            }
        }
    }
}
