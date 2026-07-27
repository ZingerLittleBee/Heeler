import SwiftUI

/// A dialog drawn over the terminal, for the moments when the terminal itself
/// cannot answer: the session ended, or it has not started yet.
///
/// It carries its own background on purpose. The first version was a bare
/// `ContentUnavailableView`, which is transparent by design — over a live
/// terminal that left the copy competing with whatever glyphs happened to be
/// underneath it, and losing.
enum TerminalStatusGlyph {
    case symbol(String)
    /// For states the app is actively working through, where a still icon
    /// would read as "stuck".
    case progress
}

struct TerminalStatusDialog<Actions: View>: View {
    let glyph: TerminalStatusGlyph
    let title: String
    var message: String?
    /// Dims the terminal behind the dialog. Off for transient states, where a
    /// full-screen dim would flash on every reconnect.
    var dimsBackground = true
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ZStack {
            if dimsBackground {
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                case .progress:
                    ProgressView()
                        .controlSize(.large)
                }
                Text(title)
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                actions()
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }
}

extension TerminalStatusDialog where Actions == EmptyView {
    init(
        glyph: TerminalStatusGlyph,
        title: String,
        message: String? = nil,
        dimsBackground: Bool = true
    ) {
        self.init(
            glyph: glyph, title: title, message: message, dimsBackground: dimsBackground,
            actions: { EmptyView() })
    }
}

#Preview("Ended") {
    ZStack {
        Color.black
        TerminalStatusDialog(
            glyph: .symbol("cable.connector.slash"),
            title: "Session Ended",
            message: "The session ended."
        ) {
            Button("Reattach") {}
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview("Connecting") {
    ZStack {
        Color.black
        TerminalStatusDialog(glyph: .progress, title: "Connecting…", dimsBackground: false)
    }
}
