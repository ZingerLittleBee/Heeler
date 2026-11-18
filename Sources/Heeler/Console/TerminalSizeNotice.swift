import SwiftUI

/// What a terminal says while it shows at a size another device set, on a
/// Server Kind whose terminals keep their own size (ADR 0053).
struct TerminalSizeNotice: Equatable {
    enum Phase: Equatable {
        /// It offers to fit the terminal to this screen.
        case offered
        /// The request is out.
        case taking
        /// The request did not go through, in words for the user. Only
        /// another tap tries again.
        case failed(String)
    }

    /// The size the terminal has, as the other device set it.
    var server: TerminalSizeReport.Grid
    var phase: Phase

    /// The end of the terminal the notice sits at, away from where the
    /// output ends, which is where the prompt and cursor usually are: the
    /// bottom while the last row with text is in the upper half of the
    /// `viewport` (one line per row), the top otherwise.
    static func edge(forViewport viewport: String) -> VerticalEdge {
        let rows = viewport.split(separator: "\n", omittingEmptySubsequences: false)
        let lastText = rows.lastIndex { !$0.allSatisfy(\.isWhitespace) } ?? -1
        return lastText < rows.count / 2 ? .bottom : .top
    }
}

/// A small control over a terminal that shows at a size another device set:
/// it says so, offers to fit the terminal to this screen, and goes away when
/// dismissed. It sits over the grid's top or bottom rows, away from where the
/// output ends, rather than taking a row of its own, so the view's grid stays
/// as it is, and it never stays there for good. Drawn in the terminal's own
/// colors, as `TerminalStatusDialog` is.
struct TerminalSizeNoticeView: View {
    let notice: TerminalSizeNotice
    let palette: TerminalThemePalette
    let onTake: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let cornerRadius: CGFloat = 22

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The action under the words, as wide as it needs.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        summary
                        Spacer(minLength: 0)
                        dismissButton
                    }
                    actionButton
                }
            } else {
                // One row; the words wrap beside the action if they must.
                HStack(spacing: 10) {
                    summary
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actionButton
                    dismissButton
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: 520)
        .background(background, in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(palette.foreground.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .foregroundStyle(palette.foreground)
        .environment(\.terminalStatusPalette, palette)
        .accessibilityElement(children: .contain)
    }

    /// The terminal's background lifted toward its foreground, as the status
    /// dialog's card is, and opaque, so no output shows through the words.
    private var background: Color {
        palette.background.mix(with: palette.foreground, by: 0.08)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(palette.foreground.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(sizeDescription)
    }

    /// Only a state the words alone do not show: the request at work, or
    /// one that did not go through. The offer needs its room for the words.
    @ViewBuilder
    private var glyph: some View {
        switch notice.phase {
        case .offered:
            EmptyView()
        case .taking:
            ProgressView()
                .controlSize(.small)
                .tint(palette.foreground.opacity(0.72))
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(palette.foreground.opacity(0.72))
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        switch notice.phase {
        case .offered: String(localized: "Sized for another device")
        case .taking: String(localized: "Fitting to this screen…")
        case .failed: String(localized: "Couldn't fit to this screen")
        }
    }

    private var detail: String? {
        if case .failed(let message) = notice.phase { return message }
        return nil
    }

    private var sizeDescription: String {
        String(localized: "Shown at \(notice.server.columns) columns by \(notice.server.rows) rows")
    }

    @ViewBuilder
    private var actionButton: some View {
        switch notice.phase {
        case .offered:
            Button("Fit to Screen", action: onTake)
                .buttonStyle(TerminalSizeNoticeButtonStyle())
                .accessibilityHint(
                    "Resizes the terminal to fit this screen. Other devices show it at this size until you leave it.")
        case .taking:
            EmptyView()
        case .failed:
            Button("Try Again", action: onTake)
                .buttonStyle(TerminalSizeNoticeButtonStyle())
                .accessibilityHint("Asks the Host again to resize the terminal to fit this screen.")
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.foreground.opacity(0.6))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Dismiss")
        .accessibilityHint("Keeps the size the other device set.")
    }
}

/// What a terminal screen's size notice reads and tells: a Shell Terminal's
/// store, or an Agent detail's Attach (ADRs 0053 and 0056).
@MainActor
protocol TerminalSizeNoticeSource: AnyObject {
    /// What the view says while the terminal shows at a size another device
    /// set; nil when there is nothing to say.
    var sizeNotice: TerminalSizeNotice? { get }
    /// Takes the terminal's size for this view, at the user's tap.
    func takeTerminalSize()
    /// Keeps the size the other device set, and hides the notice.
    func dismissSizeNotice()
    /// The scene went to the background: a size the view took is given back.
    func sceneDidEnterBackground()
    /// The scene came back: the terminal still on its screen takes the size
    /// again.
    func sceneDidBecomeActive()
}

extension ShellTerminalStore: TerminalSizeNoticeSource {}
extension AgentAttachStore: TerminalSizeNoticeSource {}

/// Lays a terminal's size notice over its screen at `edge`, `top` or
/// `bottom` in from that edge, and tells the store when its scene goes to
/// the background, which gives back a size the view took, and when it comes
/// back, which takes it again (ADR 0053).
struct TerminalSizeNoticeOverlay: ViewModifier {
    let store: any TerminalSizeNoticeSource
    let palette: TerminalThemePalette
    /// The terminal chrome's color scheme, as the back header takes it.
    let colorScheme: ColorScheme
    /// See `TerminalSizeNotice.edge(forViewport:)`.
    let edge: VerticalEdge
    let top: CGFloat
    let bottom: CGFloat
    /// Out of the way of what opens in the same place, such as the drawer
    /// the back header's menu opens.
    let isHidden: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Group {
                    if let notice = store.sizeNotice, !isHidden {
                        TerminalSizeNoticeView(
                            notice: notice, palette: palette,
                            onTake: { store.takeTerminalSize() },
                            onDismiss: { store.dismissSizeNotice() })
                        .environment(\.colorScheme, colorScheme)
                        .padding(.horizontal, 12)
                        .padding(edge == .top ? .top : .bottom, edge == .top ? top : bottom)
                        .transition(.move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: store.sizeNotice != nil)
            }
            // From the first frame too, so a screen that appears in a scene
            // in the background takes nothing until the scene comes back.
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .background: store.sceneDidEnterBackground()
                case .active: store.sceneDidBecomeActive()
                default: break
                }
            }
    }
}

/// The notice's action: the status dialog's primary button, compact.
private struct TerminalSizeNoticeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @Environment(\.terminalStatusPalette) private var palette

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(palette.background)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(palette.foreground, in: .capsule)
                .contentShape(.capsule)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .fixedSize()
        }
    }
}

#Preview("Offered") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack(alignment: .top) {
        palette.background.ignoresSafeArea()
        VStack(spacing: 16) {
            TerminalSizeNoticeView(
                notice: TerminalSizeNotice(server: .init(columns: 100, rows: 30), phase: .offered),
                palette: palette, onTake: {}, onDismiss: {})
            TerminalSizeNoticeView(
                notice: TerminalSizeNotice(server: .init(columns: 100, rows: 30), phase: .taking),
                palette: palette, onTake: {}, onDismiss: {})
            TerminalSizeNoticeView(
                notice: TerminalSizeNotice(
                    server: .init(columns: 100, rows: 30),
                    phase: .failed("The Host didn't answer. The size may still change.")),
                palette: palette, onTake: {}, onDismiss: {})
        }
        .padding(12)
    }
}
