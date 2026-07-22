import GhosttyTerminal
import SwiftUI
import UIKit

struct SettingsView: View {
    let terminalThemes: TerminalThemeSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TerminalThemePreview(theme: terminalThemes.theme)
                        .frame(height: 180)
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    Color(uiColor: .separator).opacity(0.45),
                                    lineWidth: 0.5)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityLabel("Terminal theme preview")
                } header: {
                    Text("Preview")
                } footer: {
                    Text(
                        "Changes apply instantly to current and future Attach terminals without reconnecting."
                    )
                }

                Section("Terminal Theme") {
                    ForEach(TerminalThemeOption.allCases) { option in
                        themeButton(option)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func themeButton(_ option: TerminalThemeOption) -> some View {
        let isSelected = terminalThemes.selection == option
        return Button {
            terminalThemes.select(option)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct TerminalThemePreview: UIViewRepresentable {
    let theme: TerminalTheme

    func makeUIView(context _: Context) -> TerminalThemePreviewView {
        TerminalThemePreviewView(theme: theme)
    }

    func updateUIView(_ view: TerminalThemePreviewView, context _: Context) {
        view.applyTheme(theme)
    }
}

@MainActor
private final class TerminalThemePreviewView: UITerminalView {
    private static let previewLines: [String] = [
        "\u{1B}[2J\u{1B}[H\u{1B}[1;36mherdr-mobile\u{1B}[0m",
        "\u{1B}[32m● connected\u{1B}[0m  mac-studio",
        "",
        "\u{1B}[34m~/Projects/herdr\u{1B}[0m",
        "\u{1B}[35m›\u{1B}[0m codex --continue",
        "\u{1B}[2mReady for input\u{1B}[0m",
    ]
    private static let preview = Data(previewLines.joined(separator: "\r\n").utf8)

    private let previewSession: InMemoryTerminalSession
    private let themeController: TerminalController
    private var hasLoadedPreview = false

    init(theme: TerminalTheme) {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        previewSession = session
        themeController = TerminalController(theme: theme) { builder in
            builder.withWindowPaddingX(12)
            builder.withWindowPaddingY(10)
        }
        super.init(frame: .zero)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: 13)
        controller = themeController
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Terminal theme preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasLoadedPreview else { return }
        hasLoadedPreview = true
        previewSession.receive(Self.preview)
    }

    func applyTheme(_ theme: TerminalTheme) {
        _ = themeController.setTheme(theme)
    }
}
