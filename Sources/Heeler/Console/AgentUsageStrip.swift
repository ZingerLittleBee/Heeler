import SwiftUI

/// The Agent's own session figures, which its status line shows on a wide
/// terminal but drops first when there is no room for them (#325).
///
/// Every value is optional and omitted independently: a figure Heeler could not
/// read is left out rather than shown as a zero. With nothing to show the row
/// disappears entirely, so an Agent whose session cannot be read looks exactly
/// as it did before this existed.
struct AgentUsageStrip: View {
    let model: String?
    let contextText: String?
    let costText: String?

    static let preferredHeight: CGFloat = 24

    var body: some View {
        if hasContent {
            HStack(spacing: 12) {
                if let model {
                    item(systemImage: "cpu", text: model, isProminent: false)
                }
                if let contextText {
                    item(systemImage: "rectangle.stack", text: contextText, isProminent: true)
                }
                if let costText {
                    item(
                        systemImage: "dollarsign.circle", text: costText, isProminent: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.preferredHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1 / max(displayScale, 1))
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var hasContent: Bool {
        model != nil || contextText != nil || costText != nil
    }

    @Environment(\.displayScale) private var displayScale

    /// Spoken as one figure rather than three unlabelled fragments: the glyphs
    /// that separate them on screen carry no meaning to a screen reader.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let model { parts.append("model \(model)") }
        if let contextText { parts.append("context \(contextText)") }
        if let costText { parts.append("session cost \(costText)") }
        return "Agent usage: " + parts.joined(separator: ", ")
    }

    /// The glyph names the figure; the value carries the weight, because it is
    /// what the user is reading the strip for.
    private func item(systemImage: String, text: String, isProminent: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
            Text(text)
                .font(.system(size: 11, weight: isProminent ? .semibold : .medium))
                .foregroundStyle(Color(uiColor: isProminent ? .label : .secondaryLabel))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
