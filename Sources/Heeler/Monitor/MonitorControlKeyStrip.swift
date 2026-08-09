import SwiftUI

/// Monitor's compact control-key row (#183). The three prompt actions stay
/// one tap away; directional keys live behind an explicit menu so narrow
/// layouts never hide controls offscreen. Spellings live on
/// ``MonitorControlKey``; this view only presents the buttons.
struct MonitorControlKeyStrip: View {
    let isEnabled: Bool
    let onTap: (MonitorControlKey) -> Void

    var body: some View {
        HStack(spacing: 8) {
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

            Spacer(minLength: 0)

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
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Control keys")
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
