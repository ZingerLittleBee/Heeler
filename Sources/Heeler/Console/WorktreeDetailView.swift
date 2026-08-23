import SwiftUI

struct WorktreeDetailView: View {
    @State private var store: WorktreeDetailStore
    let onRemoved: (WorktreeRemovalReceipt) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        store: WorktreeDetailStore,
        onRemoved: @escaping (WorktreeRemovalReceipt) -> Void
    ) {
        _store = State(initialValue: store)
        self.onRemoved = onRemoved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Linked Worktree") {
                    LabeledContent("Repository", value: store.checkout.repoName)
                    branchRow
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Checkout Path")
                            .foregroundStyle(.secondary)
                        Text(store.checkout.checkoutPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Button("Remove Worktree…", role: .destructive) {
                        store.prepareConfirmation()
                    }
                    .disabled(!store.canRemove)
                    if store.removalPhase == .removing {
                        ProgressView("Removing worktree")
                    }
                } footer: {
                    if store.removalPhase == .unconfirmed {
                        Text(WorktreeRemovalError.outcomeUnconfirmed.message)
                    } else if case .stale(let message) = store.removalPhase {
                        Text(message)
                    } else {
                        Text(
                            "Deletes this checkout and closes its workspace. No branch is deleted."
                        )
                    }
                }
            }
            .navigationTitle("Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                store.confirmation?.title ?? "Remove worktree?",
                isPresented: confirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Remove Worktree", role: .destructive) {
                    Task { await store.confirmRemoval() }
                }
                Button("Cancel", role: .cancel) { store.cancelConfirmation() }
            } message: {
                Text(store.confirmation?.message ?? "")
            }
            .alert(
                feedbackTitle,
                isPresented: feedbackPresented
            ) {
                Button("OK", role: .cancel) { store.dismissFeedback() }
            } message: {
                Text(feedbackMessage)
            }
            .onChange(of: store.removalPhase) { _, phase in
                guard case .removed(let receipt) = phase else { return }
                onRemoved(receipt)
                dismiss()
            }
            .task { await store.loadBranchIfNeeded() }
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { store.confirmation != nil },
            set: { if !$0 { store.cancelConfirmation() } })
    }

    private var feedbackPresented: Binding<Bool> {
        Binding(
            get: { store.showsFeedback },
            set: { presented in
                if !presented { store.dismissFeedback() }
            })
    }

    private var feedbackTitle: String {
        switch store.removalPhase {
        case .unconfirmed: "Removal Unconfirmed"
        default: "Couldn't Remove Worktree"
        }
    }

    private var feedbackMessage: String {
        switch store.removalPhase {
        case .failed(let message): message
        case .stale(let message): message
        case .unconfirmed: WorktreeRemovalError.outcomeUnconfirmed.message
        default: ""
        }
    }

    @ViewBuilder
    private var branchRow: some View {
        HStack {
            Text("Branch")
            Spacer()
            switch store.branch {
            case .loading:
                Text("Loading…").foregroundStyle(.secondary)
            case .named(let name):
                Text(name).font(.body.monospaced())
            case .detached:
                Text("Detached HEAD")
            case .unavailable:
                Text("Unavailable").foregroundStyle(.secondary)
                Button("Retry") { Task { await store.retryBranch() } }
            }
        }
    }
}
