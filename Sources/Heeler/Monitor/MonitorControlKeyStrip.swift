import SwiftUI

/// Monitor's compact control-key row (#183). The three prompt actions stay
/// one tap away; directional keys live behind an explicit menu so narrow
/// layouts never hide controls offscreen. Spellings live on
/// ``MonitorControlKey``; this view only presents the buttons.
///
/// Scales with Dynamic Type: a single HStack when width allows, otherwise a
/// horizontally scrollable strip so every target stays ≥44pt.
struct MonitorControlKeyStrip: View {
    let isEnabled: Bool
    let onTap: (MonitorControlKey) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                quickKeyButtons
                Spacer(minLength: 0)
                directionalMenu
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickKeyButtons
                    directionalMenu
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Control keys")
    }

    @ViewBuilder
    private var quickKeyButtons: some View {
        ForEach(Self.quickKeys) { key in
            Button {
                onTap(key)
            } label: {
                keyLabel(key)
                    .font(.callout.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .disabled(!isEnabled)
            .accessibilityLabel(key.accessibilityLabel)
        }
    }

    private var directionalMenu: some View {
        Menu {
            ForEach(Self.arrowKeys) { key in
                Button {
                    onTap(key)
                } label: {
                    Label(key.accessibilityLabel, systemImage: key.systemImage ?? "arrow.up")
                }
                .disabled(!isEnabled)
            }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.callout.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
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
