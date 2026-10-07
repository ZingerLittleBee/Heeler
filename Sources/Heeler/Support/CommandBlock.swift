import SwiftUI
import UIKit

/// A shell command with a Copy button, so it can be pasted into the
/// machine's terminal. It stays on one line and scrolls, as in a terminal:
/// a wrapped command reads as two when typed by hand.
struct CommandBlock: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.leading, 10)
                    .padding(.trailing, 20)
                    .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            // A fade, not a hard cut, says the command runs on past the edge.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 20)
                }
            }
            Button {
                UIPasteboard.general.string = command
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            // Full 44-point target without making the block that tall.
            .padding(.vertical, -6)
            .accessibilityLabel(copied ? "Copied" : "Copy Command")
        }
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 8))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
