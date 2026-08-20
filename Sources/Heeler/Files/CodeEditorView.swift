import SwiftUI
import UIKit

@MainActor
final class SaveHandlingTextView: UITextView {
    var onSave: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: "Save",
                image: nil,
                action: #selector(saveFromKeyboard),
                input: "s",
                modifierFlags: .command,
                propertyList: nil)
        ]
    }

    @objc private func saveFromKeyboard() {
        onSave?()
    }
}

/// UIKit supplies the editing behaviour SwiftUI's multiline field does not:
/// predictable keyboard preferences, hardware save, and attributed text that
/// can be refreshed without replacing the remote file draft.
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    let path: String
    let isEditable: Bool
    let fontFamily: String?
    let palette: TerminalThemePalette?
    typealias UIViewType = SaveHandlingTextView

    let onSave: (@MainActor @Sendable () -> Void)?

    init(
        text: Binding<String>,
        path: String,
        isEditable: Bool = true,
        fontFamily: String? = nil,
        palette: TerminalThemePalette? = nil,
        onSave: (@MainActor @Sendable () -> Void)? = nil
    ) {
        _text = text

        self.path = path
        self.isEditable = isEditable
        self.fontFamily = fontFamily
        self.palette = palette
        self.onSave = onSave
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SaveHandlingTextView {
        let textView = SaveHandlingTextView()
        textView.delegate = context.coordinator
        textView.onSave = { [weak coordinator = context.coordinator] in
            coordinator?.saveFromKeyboard()
        }
        textView.alwaysBounceVertical = true
        textView.backgroundColor = colors.background
        textView.font = resolvedFont
        textView.textColor = colors.foreground
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityLabel = "Code editor"
        return textView
    }

    func updateUIView(_ textView: SaveHandlingTextView, context: Context) {
        context.coordinator.parent = self
        textView.onSave = { [weak coordinator = context.coordinator] in
            coordinator?.saveFromKeyboard()
        }
        let editorColors = colors
        let editorFont = resolvedFont
        context.coordinator.attach(to: textView)
        context.coordinator.updateStyle(colors: editorColors, font: editorFont)
        let textChanged = textView.text != text
        if textChanged {
            textView.text = text
        }
        textView.isEditable = isEditable
        textView.backgroundColor = editorColors.background
        textView.font = editorFont
        textView.textColor = editorColors.foreground
        if textChanged || context.coordinator.needsRestyling {
            context.coordinator.needsRestyling = false
            context.coordinator.scheduleHighlighting(
                text: textView.text,
                language: CodeSyntaxHighlighter.language(forPath: path),
                immediately: textChanged)
        }
    }
    static func dismantleUIView(_ textView: SaveHandlingTextView, coordinator: Coordinator) {
        textView.delegate = nil
        textView.onSave = nil
        coordinator.cancelHighlighting()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        var needsRestyling = true
        private var lastColors: EditorColors?
        private var lastFont: UIFont?

        private var highlightTask: Task<Void, Never>?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            highlightTask?.cancel()
        }

        func attach(to textView: UITextView) {
            view = textView
        }
        func updateStyle(colors: EditorColors, font: UIFont) {
            defer {
                lastColors = colors
                lastFont = font
            }
            guard let lastColors, let lastFont else { return }
            if !lastColors.matches(colors) || !lastFont.isEqual(font) {
                needsRestyling = true
            }
        }


        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            scheduleHighlighting(
                text: textView.text,
                language: CodeSyntaxHighlighter.language(forPath: parent.path),
                immediately: false)
        }

        @objc func saveFromKeyboard() {
            parent.onSave?()
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            highlightTask = nil
        }

        func scheduleHighlighting(
            text: String,
            language: CodeSyntaxHighlighter.Language,
            immediately: Bool
        ) {
            cancelHighlighting()
            let colors = parent.colors
            let font = parent.resolvedFont
            highlightTask = Task { [weak self] in
                if !immediately {
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                let tokens = await Task.detached(priority: .utility) {
                    CodeSyntaxHighlighter.tokens(in: text, language: language)
                }.value
                guard !Task.isCancelled else { return }
                self?.apply(tokens: tokens, for: text, colors: colors, font: font)
            }
        }

        private func apply(
            tokens: [CodeSyntaxHighlighter.Token],
            for text: String,
            colors: EditorColors,
            font: UIFont
        ) {
            guard let textView = view, textView.text == text else { return }
            let textStorage = textView.textStorage
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.beginEditing()
            defer { textStorage.endEditing() }
            if fullRange.length > 0 {
                textStorage.setAttributes(
                    [.font: font, .foregroundColor: colors.foreground], range: fullRange)
            }
            for token in tokens where NSMaxRange(token.range) <= textStorage.length {
                textStorage.addAttribute(
                    .foregroundColor, value: colors.color(for: token.kind), range: token.range)
            }
        }

        private weak var view: UITextView?

        func textViewDidBeginEditing(_ textView: UITextView) {
            view = textView
        }
    }

    private var resolvedFont: UIFont {
        if let fontFamily, let font = UIFont(name: fontFamily, size: 15) {
            return font
        }
        return .monospacedSystemFont(ofSize: 15, weight: .regular)
    }

    private var colors: EditorColors {
        if let palette {
            return EditorColors(
                background: UIColor(palette.background),
                foreground: UIColor(palette.foreground),
                comment: .secondaryLabel,
                string: UIColor(palette.success),
                keyword: UIColor(palette.accent),
                number: .systemOrange)
        }
        return .system
    }

    struct EditorColors {
        let background: UIColor
        let foreground: UIColor
        let comment: UIColor
        let string: UIColor
        let keyword: UIColor
        let number: UIColor

        static let system = EditorColors(
            background: .systemBackground,
            foreground: .label,
            comment: .secondaryLabel,
            string: .systemGreen,
            keyword: .systemBlue,
            number: .systemOrange)


        func matches(_ other: EditorColors) -> Bool {
            background.isEqual(other.background)
                && foreground.isEqual(other.foreground)
                && comment.isEqual(other.comment)
                && string.isEqual(other.string)
                && keyword.isEqual(other.keyword)
                && number.isEqual(other.number)
        }
        func color(for kind: CodeSyntaxHighlighter.Kind) -> UIColor {
            switch kind {
            case .comment: comment
            case .string: string
            case .number: number
            case .keyword, .heading, .codeFence: keyword
            }
        }
    }
}
