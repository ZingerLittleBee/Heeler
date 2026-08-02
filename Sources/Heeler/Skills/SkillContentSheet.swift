import SwiftUI

/// The skill's full document, fetched on demand when "View Content" is
/// chosen from a row's long-press menu. Presented by the screen (the
/// keyboard window cannot host a sheet), so opening it takes the keyboard
/// down and dismissing brings it back — the Snippets-management behavior.
struct SkillContentSheet: View {
    let skill: AgentSkill
    let fetch: () async throws -> String

    private enum Phase {
        case loading
        case loaded(String)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(skill.command)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await load() }
        .presentationDetents([.large, .medium])
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let document):
            ScrollView {
                Text(document)
                    .font(.footnote)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await fetch())
        } catch is CancellationError {
            // The sheet went away mid-load; nothing left to show it in.
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.malformedResponse(let detail):
            detail
        default:
            "Loading the skill failed: \(error)"
        }
    }
}
