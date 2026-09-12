import SwiftUI

/// The New Workspace remote-directory browser sheet (#280): shows one
/// absolute remote path at a time, mirroring the Rename sheet's toolbar
/// shape (Cancel leading, committing action trailing). Picking Use This
/// Directory only writes the path into the Directory field; Start stays a
/// separate tap on the owning form.
struct RemoteDirectoryBrowserView: View {
    @Bindable var browser: RemoteDirectoryBrowser
    var onUse: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = browser.errorMessage {
                    Section {
                        Text(errorMessage)
                    }
                    if browser.currentPath == nil {
                        Section {
                            Button("Try Again") {
                                browser.start()
                            }
                        }
                    }
                }
                if let currentPath = browser.currentPath {
                    Section("Current directory") {
                        Text(currentPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button {
                            browser.goBack()
                        } label: {
                            Label("Back to parent", systemImage: "chevron.left")
                        }
                        .disabled(!browser.canGoBack)
                    }
                    Section {
                        TextField("Filter", text: $browser.filter)
                    }
                    if browser.isLoading {
                        Section {
                            ProgressView()
                        }
                    }
                    if browser.truncated {
                        Section {
                            Text("Showing the first entries only; type or filter to narrow down.")
                        }
                    }
                    Section {
                        ForEach(browser.visibleDirectories, id: \.self) { name in
                            Button {
                                browser.enter(name)
                            } label: {
                                Label(name, systemImage: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if browser.isLoading {
                    Section {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Browse Directories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        browser.cancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Directory") {
                        if let currentPath = browser.currentPath {
                            onUse(currentPath)
                        }
                    }
                    .disabled(browser.currentPath == nil || browser.isLoading)
                }
            }
        }
        .onAppear {
            browser.start()
        }
        .onDisappear {
            browser.cancel()
        }
    }
}
