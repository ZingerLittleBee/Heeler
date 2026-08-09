import SwiftUI

/// Monitor's compact control-key row (#183). The three prompt actions stay
/// one tap away; directional keys live behind an explicit menu so narrow
/// layouts never hide controls offscreen. Spellings live on
/// ``MonitorControlKey``; this view only presents the buttons.
struct MonitorControlKeyStrip: View {
    let isEnabled: Bool
    let onTap: (MonitorControlKey) -> Void
    private static let glyphPointSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.quickKeys) { key in
                Button {
                    onTap(key)
                } label: {
                    keyLabel(key)
                        .frame(width: 38, height: 30)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(key.accessibilityLabel)
            }

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
                    .font(.system(size: Self.glyphPointSize, weight: .medium))
                    .frame(width: 38, height: 30)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                .font(.system(size: Self.glyphPointSize, weight: .medium))
        } else if let label = key.label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private static let quickKeys: [MonitorControlKey] = [
        .enter, .escape, .interrupt,
    ]

    private static let arrowKeys: [MonitorControlKey] = [
        .up, .down, .left, .right,
    ]
}
