import SwiftUI

/// Browses remote folders and selects a Workspace draft. Starting the Agent
/// remains a separate action on the owning New Agent form.
struct RemoteDirectoryBrowserView: View {
    @Bindable var browser: RemoteDirectoryBrowser
    var onUse: (String) -> Void
    @State private var isFiltering = false

    var body: some View {
        NavigationStack {
            List {
                if let currentPath = browser.currentPath {
                    Section {
                        locationRow(currentPath)
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
                            ForEach(browser.visibleDirectories, id: \.self) { name in
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
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.forward")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .accessibilityHint("Open folder")
                                .accessibilityIdentifier("directory-browser-folder-\(name)")
                            }
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
            .navigationTitle("Browse Directories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") {
                        if let currentPath = browser.currentPath {
                            onUse(currentPath)
                        }
                    }
                    .accessibilityLabel("Select folder")
                    .accessibilityIdentifier("directory-browser-select")
                    .disabled(browser.currentPath == nil || browser.isLoading)
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
                Text("You can select this folder for the new Workspace.")
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
