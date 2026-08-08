import SwiftUI

/// A dialog drawn over the terminal, for the moments when the terminal itself
/// cannot answer: the session ended, or it has not started yet.
///
/// It carries its own background on purpose. The first version was a bare
/// `ContentUnavailableView`, which is transparent by design — over a live
/// terminal that left the copy competing with whatever glyphs happened to be
/// underneath it, and losing.
///
/// The background is the terminal's, not the system's: the theme owns the
/// whole screen (see `surfaceBackground(for:)`), and a `.regularMaterial` card
/// over a Solarized or Nord grid reads as a piece of some other app. The card
/// lifts off the terminal background rather than matching it, or it would be
/// invisible on the surface it sits on.
enum TerminalStatusGlyph {
    case symbol(String)
    /// For states the app is actively working through, where a still icon
    /// would read as "stuck".
    case progress
}

/// The status overlay `AgentAttachView` presents for one terminal state.
/// Keeping this mapping as a value lets hosted lifecycle tests observe the
/// actual presentation choice without snapshotting Ghostty's live Metal tree.
struct TerminalStatusPresentation: Equatable {
    enum Kind: Equatable {
        case connecting
        case ended
    }

    let kind: Kind
    let title: String
    let message: String?
    let dimsBackground: Bool

    static let connecting = TerminalStatusPresentation(
        kind: .connecting,
        title: "Connecting…",
        message: nil,
        dimsBackground: false)

    static func ended(message: String) -> TerminalStatusPresentation {
        TerminalStatusPresentation(
            kind: .ended,
            title: "Session Ended",
            message: message,
            dimsBackground: true)
    }

    init?(status: AttachTerminalStore.Status) {
        switch status {
        case .waitingForSize, .connecting:
            self = .connecting
        case .ended(let message):
            self = .ended(message: message)
        case .live, .stopped:
            return nil
        }
    }

    private init(
        kind: Kind,
        title: String,
        message: String?,
        dimsBackground: Bool
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.dimsBackground = dimsBackground
    }
}

struct TerminalStatusDialog<Actions: View>: View {
    let glyph: TerminalStatusGlyph
    let title: String
    var message: String?
    /// The active terminal theme's colours. Defaults to the system palette so
    /// previews and pixel tests need not carry a theme.
    var palette: TerminalThemePalette = .system
    /// Dims the terminal behind the dialog. Off for transient states, where a
    /// full-screen dim would flash on every reconnect.
    var dimsBackground = true
    @ViewBuilder let actions: () -> Actions

    private static var cornerRadius: CGFloat { 20 }

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
                        .foregroundStyle(palette.foreground.opacity(0.7))
                case .progress:
                    ProgressView()
                        .controlSize(.large)
                        .tint(palette.accent)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.foreground)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(palette.foreground.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                actions()
                    .tint(palette.accent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(cardBackground, in: .rect(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(palette.foreground.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }

    /// The terminal's background, lifted toward its foreground just enough to
    /// separate the card from the grid it sits on — the same trick a TUI uses
    /// for a popup, and it works for a light theme and a dark one alike.
    private var cardBackground: Color {
        palette.background.mix(with: palette.foreground, by: 0.08)
    }
}

extension TerminalStatusDialog where Actions == EmptyView {
    init(
        glyph: TerminalStatusGlyph,
        title: String,
        message: String? = nil,
        palette: TerminalThemePalette = .system,
        dimsBackground: Bool = true
    ) {
        self.init(
            glyph: glyph, title: title, message: message, palette: palette,
            dimsBackground: dimsBackground, actions: { EmptyView() })
    }
}

#Preview("Ended") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack {
        palette.background
        TerminalStatusDialog(
            glyph: .symbol("cable.connector.slash"),
            title: "Session Ended",
            message: "The session ended.",
            palette: palette
        ) {
            Button("Reattach") {}
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview("Connecting") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack {
        palette.background
        TerminalStatusDialog(
            glyph: .progress, title: "Connecting…", palette: palette, dimsBackground: false)
    }
}
