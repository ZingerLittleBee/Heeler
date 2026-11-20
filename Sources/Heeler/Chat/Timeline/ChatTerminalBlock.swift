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
                    .textSelection(.enabled)
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
