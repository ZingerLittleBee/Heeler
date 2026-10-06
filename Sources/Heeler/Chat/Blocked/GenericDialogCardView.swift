import SwiftUI

/// A dialog the parsers could not name: its rows as the terminal shows them,
/// a button per numbered option, and the keys to finish it.
struct GenericDialogCard: View {
    let excerpt: GenericDialogExcerpt
    let store: BlockedCardStore
    let maxHeight: CGFloat
    let openTerminal: () -> Void
    @State private var showsKeys = false

    private var numbers: [Int] { excerpt.numbered.keys.sorted() }
    private var isReady: Bool { store.progress == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockedCardHeader(
                title: "Waiting for Input", detail: nil, isActing: store.progress == .acting,
                collapse: { store.isCollapsed = true })
            // The options stay in view below the rows, which scroll.
            BlockedScrollingContent(maxHeight: max(maxHeight - CGFloat(numbers.count) * 52, 96)) {
                VStack(alignment: .leading, spacing: 10) {
                    if !excerpt.reason.isEmpty {
                        BlockedCardText(excerpt.reason)
                    }
                    GenericExcerptView(rows: excerpt.rows)
                }
            }
            if !numbers.isEmpty {
                VStack(spacing: 8) {
                    ForEach(numbers, id: \.self) { number in
                        BlockedOptionButton(
                            option: DialogOption(
                                ordinal: number, number: number,
                                label: "\(number). \(excerpt.numbered[number] ?? "")", role: .answer),
                            emphasis: .plain
                        ) {
                            Task { await store.press(number: number) }
                        }
                    }
                }
                .disabled(!isReady)
            }
            // Without options to press, the keys are the way through.
            if numbers.isEmpty || showsKeys {
                BlockedKeyPad(store: store)
            }
            BlockedCardFooter(
                notice: store.notice, isReady: isReady, keys: numbers.isEmpty ? nil : $showsKeys,
                openTerminal: openTerminal)
        }
    }
}

/// herdr says Blocked, and the screen shows nothing Heeler recognizes.
struct UnreadableDialogCard: View {
    let store: BlockedCardStore
    let openTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockedCardHeader(
                title: "Waiting for Input", detail: nil, isActing: store.progress == .acting,
                collapse: { store.isCollapsed = true })
            BlockedCardText(
                "The Agent is waiting on something Heeler can't read. Answer with these keys or in the terminal.")
            BlockedKeyPad(store: store)
            BlockedCardFooter(notice: store.notice, isReady: store.progress == .ready, openTerminal: openTerminal)
        }
    }
}

/// The keys for a prompt Heeler can't read: the tools dock's Agent page.
struct BlockedKeyPad: View {
    let store: BlockedCardStore

    var body: some View {
        AgentQuickKeyPad(isEnabled: store.progress != .acting, insets: EdgeInsets()) { key in
            guard let name = key.herdrKeyName else { return }
            Task { await store.sendKeys([name]) }
        }
        .frame(height: 124)
    }
}

/// The rows as the terminal shows them. Rules become lines: drawn in
/// characters, they would wrap at a phone's width.
private struct GenericExcerptView: View {
    let rows: [ScreenRow]

    private enum Line {
        case text(String)
        case rule
        case gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .text(let text):
                    Text(verbatim: text)
                        .fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Divider()
                        .padding(.vertical, 4)
                case .gap:
                    Spacer()
                        .frame(height: 6)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
    }

    /// Trailing padding dropped, blank runs folded to one gap, none at
    /// either end.
    private var lines: [Line] {
        var lines: [Line] = []
        for row in rows {
            let text = String(row.text.reversed().drop(while: \.isWhitespace).reversed())
            if text.isEmpty {
                if let last = lines.last, case .gap = last { continue }
                if !lines.isEmpty { lines.append(.gap) }
            } else if Self.isRule(text) {
                lines.append(.rule)
            } else {
                lines.append(.text(text))
            }
        }
        if let last = lines.last, case .gap = last { lines.removeLast() }
        return lines
    }

    private static let ruleCharacters: Set<Character> = ["─", "━", "═", "╌", "╍", "┄", "┈", "▔", "▁"]

    private static func isRule(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy(ruleCharacters.contains)
    }
}
