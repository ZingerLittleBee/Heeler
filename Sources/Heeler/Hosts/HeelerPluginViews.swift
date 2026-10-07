import SwiftUI

/// The warning glyph plugin notices share, in the Console's warning tone
/// rather than a failure's red: the Host still works.
struct PluginWarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(HostConnectionTone.warning.tint)
    }
}

/// A feature the Host's plugin is too old for, pointing at the Host's page,
/// which says how to update it.
struct PluginRequirementNote: View {
    let text: String

    var body: some View {
        let message = "\(text) See this Host's page in Hosts."
        Label {
            Text(message)
        } icon: {
            PluginWarningIcon()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The icon on a Host's plugin row when there is something to do: the
/// warning glyph, or an info glyph for a Host that has no plugin yet.
struct PluginNoticeIcon: View {
    let tone: HeelerPluginPresentation.Notice.Tone

    var body: some View {
        switch tone {
        case .warning:
            PluginWarningIcon()
        case .info:
            Image(systemName: "info.circle")
                .foregroundStyle(.tint)
        }
    }
}

/// What to run on the Host to install, update, enable, or replace the
/// plugin, opened from the Host page's plugin row.
struct PluginNoticeSheet: View {
    let notice: HeelerPluginPresentation.Notice
    let runChecks: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(notice.message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            PluginNoticeIcon(tone: notice.tone)
                        }
                        .accessibilityIdentifier("hosts.detail.plugin.notice")
                        ForEach(notice.commands, id: \.self) { command in
                            CommandBlock(command: command)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    if !notice.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(notice.notes, id: \.self) { note in
                                Text(note)
                            }
                        }
                    }
                }

                if !notice.commands.isEmpty {
                    Section {
                        Button("Run Checks Again", systemImage: "arrow.clockwise", action: runChecks)
                    } footer: {
                        Text("After running the commands on the Host.")
                    }
                }
            }
            .navigationTitle("Heeler Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// Presents `PluginNoticeSheet` for `notice`, closing it once there is
    /// nothing left to do. Run Checks Again closes it before `runChecks`.
    func pluginNoticeSheet(
        _ notice: HeelerPluginPresentation.Notice?,
        isPresented: Binding<Bool>,
        runChecks: @escaping () -> Void
    ) -> some View {
        modifier(PluginNoticeSheetModifier(notice: notice, isPresented: isPresented, runChecks: runChecks))
    }
}

private struct PluginNoticeSheetModifier: ViewModifier {
    let notice: HeelerPluginPresentation.Notice?
    @Binding var isPresented: Bool
    let runChecks: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                if let notice {
                    PluginNoticeSheet(notice: notice) {
                        isPresented = false
                        runChecks()
                    }
                }
            }
            .onChange(of: notice == nil) { _, resolved in
                if resolved { isPresented = false }
            }
    }
}
