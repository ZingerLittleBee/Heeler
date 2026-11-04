import SwiftUI
import UIKit

/// The face Chat's conversation is set in. Code, paths and diffs stay
/// monospaced whatever the choice: their columns are measured in it.
enum ChatFontOption: String, CaseIterable, Identifiable, Sendable {
    case system
    case rounded
    case serif
    case monospaced

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// Chat's text size and font, kept apart from the terminal's. The size is
/// a number of Dynamic Type steps from the system's own, so Chat keeps
/// following Larger Text and each text style keeps Apple's proportions.
enum ChatTextSettings {
    static let sizeOffsetKey = "chat.text-size-offset"
    static let fontKey = "chat.font"

    /// Two steps below the system, body 15 pt at the default Large: the
    /// conversation is dense reading, and one step barely shows.
    static let defaultSizeOffset = -2
    static let sizeOffsetRange = -3...3

    /// The system's size moved by `offset` steps, held within Dynamic Type.
    static func size(system: DynamicTypeSize, offset: Int) -> DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        let current = sizes.firstIndex(of: system) ?? sizes.startIndex
        let clampedOffset = min(max(offset, sizeOffsetRange.lowerBound), sizeOffsetRange.upperBound)
        let index = min(max(current + clampedOffset, sizes.startIndex), sizes.index(before: sizes.endIndex))
        return sizes[index]
    }

    /// The body text's size at `size`, as Settings shows it.
    static func bodyPointSize(at size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
    }
}

/// Chat's font as a UIKit trait, so the timeline's hosted cells read it
/// from their trait collection, like the text size, and a change reaches
/// every cell and re-measures it on the same path.
struct ChatFontTrait: UITraitDefinition {
    static let defaultValue = ChatFontOption.system
    static let identifier = "dev.bybee.heeler.chat-font"
    static let name = "ChatFont"
}

extension UITraitCollection {
    var chatFont: ChatFontOption { self[ChatFontTrait.self] }
}

extension UIMutableTraits {
    var chatFont: ChatFontOption {
        get { self[ChatFontTrait.self] }
        set { self[ChatFontTrait.self] = newValue }
    }
}

private struct ChatFontEnvironmentKey: EnvironmentKey, UITraitBridgedEnvironmentKey {
    static let defaultValue = ChatFontOption.system

    static func read(from traitCollection: UITraitCollection) -> ChatFontOption {
        traitCollection.chatFont
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: ChatFontOption) {
        mutableTraits.chatFont = value
    }
}

extension EnvironmentValues {
    var chatFont: ChatFontOption {
        get { self[ChatFontEnvironmentKey.self] }
        set { self[ChatFontEnvironmentKey.self] = newValue }
    }
}

/// Sets Chat's font on its content, from the environment the timeline's
/// cells bridge from their traits, or the monospaced design for code.
struct ChatFontDesign: ViewModifier {
    var isCode = false
    @Environment(\.chatFont) private var font

    func body(content: Content) -> some View {
        content.fontDesign(isCode ? .monospaced : font.design)
    }
}
