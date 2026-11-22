import SwiftUI

/// The staging's progress or result, with its commands, above the Composer:
/// the same bar on the Agent terminal and in Chat. Empty while idle, and
/// silent for image stages that the Composer's inline pill strip already shows.
struct ComposerStagingStatusBar: View {
    let staging: ComposerStagingStore

    var body: some View {
        if Self.showsBar(for: staging.state, isPill: staging.activeOperationIsPill),
            let presentation = staging.presentation
        {
            AttachmentStatusBar(
                icon: presentation.icon,
                title: presentation.title,
                accessibilityLabel: presentation.accessibilityLabel
            ) {
                ForEach(presentation.commands, id: \.self) { @Sendable command in
                    MainActorContent { commandButton(command) }
                }
            }
        }
    }

    static func showsBar(for state: ComposerStagingStore.State, isPill: Bool = false) -> Bool {
        switch state {
        case .idle:
            false
        case .preparing(let medium), .uploading(let medium, _):
            medium == .file && !isPill
        case .completed(let outcome):
            outcome.medium == .file && !isPill
        case .failed(let failure), .backgroundInterrupted(let failure):
            if failure.medium == .image || isPill {
                !failure.isRetryable
            } else {
                true
            }
        }
    }

    @ViewBuilder
    private func commandButton(_ command: ComposerStagingStore.Command) -> some View {
        switch command {
        case .cancel:
            Button("Cancel", role: .cancel) { staging.perform(command) }
        case .retry:
            Button("Retry") { staging.perform(command) }
        case .copyPath:
            Button("Copy Path") { staging.perform(command) }
        case .dismiss:
            Button("Dismiss", role: .cancel) { staging.perform(command) }
        }
    }
}

private struct AttachmentStatusBar<Actions: View>: View {
    let icon: String
    let title: String
    let accessibilityLabel: String
    let actions: Actions

    init(
        icon: String,
        title: String,
        accessibilityLabel: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .lineLimit(3)
            HStack(spacing: 12) {
                Spacer()
                actions
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
