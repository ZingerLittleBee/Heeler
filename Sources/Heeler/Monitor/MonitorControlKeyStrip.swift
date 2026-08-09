import SwiftUI

/// Monitor's horizontal control-key strip (#183): Enter, Esc, Ctrl+C, and
/// the four arrows. Self-contained so package #180 can attach elsewhere
/// without reshaping the rest of the Monitor surface. Spellings live on
/// ``MonitorControlKey``; this view only presents the buttons.
struct MonitorControlKeyStrip: View {
    let isEnabled: Bool
    let onTap: (MonitorControlKey) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MonitorControlKey.allCases) { key in
                    Button {
                        onTap(key)
                    } label: {
                        keyLabel(key)
                            .font(.callout.weight(.medium))
                            .frame(minWidth: 44, minHeight: 36)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isEnabled)
                    .accessibilityLabel(key.accessibilityLabel)
                }
            }
            .padding(.horizontal, 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
}
