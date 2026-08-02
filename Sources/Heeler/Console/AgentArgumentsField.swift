import SwiftUI
import UIKit

/// A wrapping arguments editor with shell-safe text input traits. SwiftUI's
/// autocorrection modifier does not disable smart dashes or smart quotes, so
/// this small UIKit bridge owns those traits explicitly instead of rewriting
/// the bound value while UIKit is editing it.
struct AgentArgumentsField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            AgentArgumentsTextView(text: $text)
        }
        .frame(minHeight: UIFont.preferredFont(forTextStyle: .callout).lineHeight)
        .accessibilityLabel("Arguments")
    }
}

struct AgentArgumentsTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        Self.configure(textView)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        if textView.text != text {
            textView.text = text
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: UITextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 0
        return CGSize(width: width, height: max(fittingSize.height, lineHeight))
    }

    static func configure(_ textView: UITextView) {
        let pointSize = UIFont.preferredFont(forTextStyle: .callout).pointSize
        let font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        textView.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: font)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
        }

        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            let normalized = StartAgentStore.normalizeSmartPunctuation(replacement)
            guard normalized != replacement else { return true }

            let current = textView.text ?? ""
            let currentNSString = current as NSString
            guard range.location <= currentNSString.length,
                range.length <= currentNSString.length - range.location
            else { return false }
            textView.text = currentNSString.replacingCharacters(
                in: range, with: normalized)
            textView.selectedRange = NSRange(
                location: range.location + (normalized as NSString).length,
                length: 0)
            textViewDidChange(textView)
            return false
        }
    }
}
