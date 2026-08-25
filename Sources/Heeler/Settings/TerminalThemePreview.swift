import GhosttyTerminal
import SwiftUI
import UIKit

/// A real terminal surface rendering canned output, for previewing the theme
/// and font size in settings without connecting anywhere.
struct TerminalThemePreview: UIViewRepresentable {
    let theme: TerminalTheme
    let fontSize: Float

    func makeUIView(context _: Context) -> TerminalThemePreviewView {
        TerminalThemePreviewView(theme: theme, fontSize: fontSize)
    }

    func updateUIView(_ view: TerminalThemePreviewView, context _: Context) {
        view.applyTheme(theme)
        view.applyFontSize(fontSize)
    }
}

@MainActor
final class TerminalThemePreviewView: UITerminalView {
    private static let previewLines: [String] = [
        "\u{1B}[2J\u{1B}[H\u{1B}[1;36mheeler\u{1B}[0m",
        "\u{1B}[32m● connected\u{1B}[0m  mac-studio",
        "",
        "\u{1B}[34m~/Projects/herdr\u{1B}[0m",
        "\u{1B}[35m›\u{1B}[0m codex --continue",
        "\u{1B}[2mReady for input\u{1B}[0m",
    ]
    private static let preview = Data(previewLines.joined(separator: "\r\n").utf8)

    private let previewSession: InMemoryTerminalSession
    private let themeController: TerminalController
    private var hasLoadedPreview = false

    init(theme: TerminalTheme, fontSize: Float) {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        previewSession = session
        themeController = TerminalController(theme: theme) { builder in
            builder.withWindowPaddingX(12)
            builder.withWindowPaddingY(10)
            builder.withFontSize(TerminalZoomSettings.clamped(fontSize))
        }
        super.init(frame: .zero)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        controller = themeController
        delegate = self
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Terminal theme preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasLoadedPreview else { return }
        hasLoadedPreview = true
        previewSession.receive(Self.preview)
    }

    func applyTheme(_ theme: TerminalTheme) {
        _ = themeController.setTheme(theme)
    }

    func applyFontSize(_ fontSize: Float) {
        _ = themeController.setTerminalConfiguration(
            TerminalConfiguration().fontSize(TerminalZoomSettings.clamped(fontSize)))
    }
}

extension TerminalThemePreviewView: TerminalSurfaceLifecycleDelegate {
    func terminalDidAttachSurface(_: TerminalSurface) {}

    func terminalDidDetachSurface() {
        removeOrphanedSurfaceLayers()
    }
}
