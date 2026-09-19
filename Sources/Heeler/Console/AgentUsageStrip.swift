import SwiftUI

/// The Agent's own session figures, which its status line shows on a wide
/// terminal but drops first when there is no room for them (#325).
///
/// Every value is optional and omitted independently: a figure Heeler could not
/// read is left out rather than shown as a zero. The row itself is kept once
/// the Agent is known to have a session file, so figures that arrive a few
/// seconds after the screen opens fill it in rather than pushing the terminal
/// down (and resizing its PTY) a second time. An Agent with no session file
/// shows no row at all and looks exactly as it did before this existed.
///
/// It wears the terminal's theme, not the system's: a dark theme under a light
/// appearance would otherwise get a light band above its grid.
struct AgentUsageStrip: View {
    let model: String?
    let contextText: String?
    let costText: String?
    /// omp's `tok/s` readout, passed only while omp shows it itself.
    let rateText: String?
    /// Whether to hold the row's height while no figure is known yet.
    let isReserved: Bool
    let palette: TerminalThemePalette

    static let preferredHeight: CGFloat = 24

    var body: some View {
        if hasContent || isReserved {
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
                if let rateText {
                    item(systemImage: "speedometer", text: rateText, isProminent: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.preferredHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(palette.foreground.opacity(0.15))
                    .frame(height: 1 / max(displayScale, 1))
            }
            .background(palette.background)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHidden(!hasContent)
        }
    }

    private var hasContent: Bool {
        model != nil || contextText != nil || costText != nil || rateText != nil
    }

    @Environment(\.displayScale) private var displayScale

    /// Spoken as one figure rather than three unlabelled fragments: the glyphs
    /// that separate them on screen carry no meaning to a screen reader.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let model { parts.append("model \(model)") }
        if let contextText { parts.append("context \(contextText)") }
        if let costText { parts.append("session cost \(costText)") }
        if let rateText { parts.append("generation rate \(rateText)") }
        return "Agent usage: " + parts.joined(separator: ", ")
    }

    /// The glyph names the figure; the value carries the weight, because it is
    /// what the user is reading the strip for.
    private func item(systemImage: String, text: String, isProminent: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.foreground.opacity(0.45))
            Text(text)
                .font(.system(size: 11, weight: isProminent ? .semibold : .medium))
                .foregroundStyle(palette.foreground.opacity(isProminent ? 1 : 0.7))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
