import SwiftUI
import UniformTypeIdentifiers

/// Monitor's compact control-key row (#183) plus pinned draft accessories.
/// Enter, Esc, and Ctrl+C stay one tap away; arrows live behind a menu.
/// Files and Paste pin at the leading edge and never scroll away.
///
/// Layout prefers a single HStack. When Dynamic Type or a narrow width does
/// not fit, Files and Paste stay outside a horizontally scrollable region so
/// they remain visible while quick keys (and the arrows menu) may scroll.
struct MonitorControlKeyStrip: View {
    /// Gates only the remote control keys (Enter / Esc / Ctrl+C / arrows).
    /// Paste and Files edit local draft state and stay enabled independently.
    let isControlKeyEnabled: Bool
    let isFileStaging: Bool
    let canStageFile: Bool
    let onControlKey: (MonitorControlKey) -> Void
    let onPaste: (String) -> Void
    let onImageSelected: (any ImageSelection) -> Void

    @State private var isPresentingFileImporter = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                pinnedAccessories
                accessoryDivider
                quickKeyButtons
                Spacer(minLength: 0)
                directionalMenu
            }

            HStack(spacing: 8) {
                pinnedAccessories
                accessoryDivider
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        quickKeyButtons
                        directionalMenu
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Control keys")
        .fileImporter(
            isPresented: $isPresentingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                return
            }
            onImageSelected(FileURLImageSelection(url: url))
        }
    }

    @ViewBuilder
    private var pinnedAccessories: some View {
        filesButton
        pasteButton
    }

    private var filesButton: some View {
        Button {
            isPresentingFileImporter = true
        } label: {
            Group {
                if isFileStaging {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Files")
                        .font(.callout.weight(.medium))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .disabled(!canStageFile || isFileStaging)
        .accessibilityLabel("Attach file")
        .accessibilityValue(isFileStaging ? "Uploading" : "")
        .accessibilityHint("Stages an image on the Host and inserts its path into the draft")
    }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first, !text.isEmpty else { return }
            onPaste(text)
        }
        .labelStyle(.titleOnly)
        .buttonStyle(.bordered)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Paste")
        .accessibilityHint("Inserts clipboard text into the draft without sending")
    }

    private var accessoryDivider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.35))
            .frame(width: 1, height: 28)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var quickKeyButtons: some View {
        ForEach(Self.quickKeys) { key in
            Button {
                onControlKey(key)
            } label: {
                keyLabel(key)
                    .font(.callout.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .disabled(!isControlKeyEnabled)
            .accessibilityLabel(key.accessibilityLabel)
        }
    }

    private var directionalMenu: some View {
        Menu {
            ForEach(Self.arrowKeys) { key in
                Button {
                    onControlKey(key)
                } label: {
                    Label(key.accessibilityLabel, systemImage: key.systemImage ?? "arrow.up")
                }
                .disabled(!isControlKeyEnabled)
            }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.callout.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!isControlKeyEnabled)
        .accessibilityLabel("Directional keys")
        .accessibilityHint("Shows directional keys")
    }

    @ViewBuilder
    private func keyLabel(_ key: MonitorControlKey) -> some View {
        if let systemImage = key.systemImage {
            Image(systemName: systemImage)
        } else if let label = key.label {
            Text(label)
        }
    }

    private static let quickKeys: [MonitorControlKey] = [
        .enter, .escape, .interrupt,
    ]

    private static let arrowKeys: [MonitorControlKey] = [
        .up, .down, .left, .right,
    ]
}
