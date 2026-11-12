import CoreGraphics
import Foundation

/// One control on Direct Input's shortcut strip. Views project this; they do
/// not decide which keys belong on the strip.
enum InputShortcutStripItem: Hashable, Sendable {
    case key(AgentQuickKey)
    case paste
    case more
}

/// Ordered shortcut-strip contents. One layout on every device and with or
/// without a hardware keyboard: the scrolling key row with Enter (and More,
/// where the surface has it) pinned at the trailing edge. The view must not
/// recompute this inline.
struct InputShortcutStripPresentation: Equatable, Sendable {
    enum SizeClass: Equatable, Sendable, CaseIterable {
        case compact
        case regular
    }

    /// Which input chrome hosts the strip.
    enum Surface: Equatable, Sendable, CaseIterable {
        /// Agent detail's Direct Input: the strip carries Paste and More.
        case directInput
        /// The Shell Terminal: its input row, directly below, already has
        /// Paste and More, so the strip carries keys only.
        case shellTerminal
    }

    /// Keys that scroll horizontally.
    let leadingItems: [InputShortcutStripItem]
    /// Pinned trailing keys (Enter + More).
    let trailingItems: [InputShortcutStripItem]

    var items: [InputShortcutStripItem] { leadingItems + trailingItems }

    /// The Direct Input strip: navigation keys plus paste, Enter, More.
    static let allItems: [InputShortcutStripItem] = [
        .key(.escape), .key(.tab), .key(.shiftTab),
        .key(.up), .key(.down), .key(.left), .key(.right),
        .key(.backspace), .key(.shiftEnter),
        .paste, .key(.enter), .more,
    ]

    /// The Shell Terminal strip: the same keys, without Paste and More.
    static let shellTerminalItems: [InputShortcutStripItem] = allItems.filter {
        $0 != .paste && $0 != .more
    }

    init(surface: Surface = .directInput) {
        switch surface {
        case .directInput:
            leadingItems = Array(Self.allItems.dropLast(2))
            trailingItems = Array(Self.allItems.suffix(2))
        case .shellTerminal:
            leadingItems = Array(Self.shellTerminalItems.dropLast())
            trailingItems = Array(Self.shellTerminalItems.suffix(1))
        }
    }
}

/// Named layout constants for the five input chromes. Raw pixel widths stay
/// here so the views do not embed magic numbers.
enum InputChromeLayout {
    /// Shortcut row and its key caps. Matches the pre-iPad compact height.
    static let shortcutRowHeight: CGFloat = 44

    static let compactEscapeTabWidth: CGFloat = 38
    static let compactShiftTabWidth: CGFloat = 46
    static let compactShiftEnterWidth: CGFloat = 54
    static let compactEnterWidth: CGFloat = 42
    static let compactArrowWidth: CGFloat = 30
    /// Backspace and other wide utility caps on the compact strip.
    static let compactWideKeyWidth: CGFloat = 72
    static let compactMoreWidth: CGFloat = compactArrowWidth
    /// `UIPasteControl` disables itself below this side length.
    static let pasteControlSide: CGFloat = 34
    /// Visual width after scaling the paste control down to the key-cap size.
    static let pasteVisualWidth: CGFloat = 30
    /// The Shell Terminal input row's paste control after scaling, so its
    /// glyph matches the row's 12-point symbols.
    static let shellPasteVisualSide: CGFloat = 26
    static let pinnedFadeWidth: CGFloat = 8

    /// Caps Agent and Skills keyboard wells and centers them in wider windows.
    /// The full Terminal keyboard adapts to the entire dock width separately.
    static let maxKeyboardContentWidth: CGFloat = 768

    /// Context-menu skill preview has no parent width. This is the card cap
    /// so a short description still reads as a card, not a 370 pt iPhone well.
    static let skillPreviewMaxWidth: CGFloat = 420

    static let shellAccessoryButtonWidth: CGFloat = 44
    /// Compact Text/Keys segmented control. Unchanged from the iPhone row.
    static let compactModePickerMaxWidth: CGFloat = 184
    /// Regular Text/Keys control. Grows for iPad but does not span the row.
    static let regularModePickerMaxWidth: CGFloat = 360

    /// Page-dot cluster on the Agent tools pager.
    static let keyboardPageIndicatorWidth: CGFloat = 15

    static func compactWidth(for key: AgentQuickKey) -> CGFloat {
        switch key {
        case .escape, .tab:
            compactEscapeTabWidth
        case .shiftTab:
            compactShiftTabWidth
        case .shiftEnter:
            compactShiftEnterWidth
        case .enter:
            compactEnterWidth
        case .left, .up, .down, .right:
            compactArrowWidth
        case .backspace, .home, .end, .pageUp, .pageDown,
            .insert, .forwardDelete, .function, .character:
            compactWideKeyWidth
        }
    }

    static func compactWidth(for item: InputShortcutStripItem) -> CGFloat {
        switch item {
        case .key(let key):
            compactWidth(for: key)
        case .paste:
            pasteVisualWidth
        case .more:
            compactMoreWidth
        }
    }

    static func modePickerMaxWidth(
        for sizeClass: InputShortcutStripPresentation.SizeClass
    ) -> CGFloat {
        switch sizeClass {
        case .compact: compactModePickerMaxWidth
        case .regular: regularModePickerMaxWidth
        }
    }
}
