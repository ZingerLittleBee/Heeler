import SwiftUI

/// What the terminal holds, quoted in Chat: a command, a path, a change,
/// rows of the Agent's screen. Black in either appearance, so it reads as
/// the terminal's and not as Chat's own words. The content pads itself,
/// clear of the corners, which nothing clips it to.
struct ChatTerminalBlock<Content: View>: View {
    var cornerRadius: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .foregroundStyle(ChatTerminalBlockStyle.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black, in: shape)
            .overlay { shape.strokeBorder(ChatTerminalBlockStyle.border, lineWidth: 1) }
            // Colours inside take their dark variants on the black.
            .environment(\.colorScheme, .dark)
    }
}

enum ChatTerminalBlockStyle {
    static let text = Color(white: 0.92)
    static let border = Color.white.opacity(0.12)
    /// A shell prompt's `$`, and a change's added lines.
    static let prompt = Color(red: 0xA6 / 255, green: 0xE3 / 255, blue: 0xA1 / 255)
}

/// Text in a `ChatTerminalBlock`. A command leads with the shell's `$`,
/// which selecting the text leaves out.
struct ChatTerminalText: View {
    let text: String
    var isCommand = false
    var isSmall = false
    var lineLimit: Int? = nil
    var cornerRadius: CGFloat = 10
    /// Off where a long press is the row's own, as in a list whose rows
    /// offer Copy.
    var isSelectable = true

    var body: some View {
        ChatTerminalBlock(cornerRadius: cornerRadius) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if isCommand {
                    Text(verbatim: "$ ")
                        .foregroundStyle(ChatTerminalBlockStyle.prompt)
                        .accessibilityHidden(true)
                }
                Text(verbatim: shown)
                    .lineLimit(lineLimit)
                    .terminalTextSelection(isSelectable)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(isSmall ? .caption : .footnote, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, isSmall ? 8 : 10)
        }
    }

    /// A command that already carries its prompt shows one `$`.
    private var shown: String {
        isCommand && text.hasPrefix("$ ") ? String(text.dropFirst(2)) : text
    }
}

/// A change's lines in a `ChatTerminalBlock`: an added line on green, a
/// removed one on red, and a count of the lines it leaves out.
struct ChatTerminalChangeLines: View {
    /// Where a line keeps the `+` or `-` that says what happened to it.
    enum Marks: Sendable {
        /// Nowhere: the lines are a file's content.
        case none
        /// First on the line, as a diff has it.
        case leading
        /// After the line's number, as an Agent's screen has it.
        case numbered
    }

    let lines: [String]
    let marks: Marks
    var isSmall = false
    var cornerRadius: CGFloat = 10
    var isSelectable = true

    var body: some View {
        ChatTerminalBlock(cornerRadius: cornerRadius) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(Self.lineLimit).enumerated()), id: \.offset) { @Sendable _, line in
                    MainActorContent {
                        // An empty line keeps its height.
                        Text(verbatim: line.isEmpty ? " " : line)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            // A shape: under a rounded clip a bare colour
                            // takes rounded ends of its own (iOS 27.0).
                            .background { Rectangle().fill(tint(of: line)) }
                    }
                }
                if lines.count > Self.lineLimit {
                    let more = lines.count - Self.lineLimit
                    Text(more == 1 ? String(localized: "\(more) more line") : String(localized: "\(more) more lines"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
            }
            .font(.system(isSmall ? .caption : .footnote, design: .monospaced))
            .terminalTextSelection(isSelectable)
            .padding(.vertical, isSmall ? 8 : 10)
        }
    }

    private static let lineLimit = 40

    private func tint(of line: String) -> Color {
        let mark: Character? =
            switch marks {
            case .none: nil
            case .leading: line.first
            case .numbered: line.drop { $0 == " " || $0.isNumber }.first
            }
        switch mark {
        case "+": return .green.opacity(0.22)
        case "-": return .red.opacity(0.24)
        default: return .clear
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func terminalTextSelection(_ isSelectable: Bool) -> some View {
        if isSelectable {
            textSelection(.enabled)
        } else {
            self
        }
    }
}
