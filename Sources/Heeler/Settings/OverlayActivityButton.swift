import SwiftUI
import UIKit

/// A UIKit button for the steps that take a while (signing in, connecting,
/// signing out): `UIButton.Configuration.showsActivityIndicator` puts the
/// system spinner in the button itself, which SwiftUI's `Button` has no
/// equivalent for. `.gray` sits where a network's switch goes; `.filled`
/// spans the status card.
struct OverlayActivityButton: UIViewRepresentable {
    enum Style {
        case gray
        case filled
    }

    let title: String
    var style = Style.gray
    var isLoading = false
    /// Spoken instead of the title, which may not say what it acts on.
    var accessibilityLabel: String?
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let coordinator = context.coordinator
        let button = UIButton(
            configuration: .gray(), primaryAction: UIAction { _ in coordinator.action() })
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        var configuration: UIButton.Configuration = style == .filled ? .filled() : .gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.buttonSize = style == .filled ? .large : .medium
        configuration.imagePadding = 6
        configuration.showsActivityIndicator = isLoading
        let font = Self.font(style == .filled ? .body : .subheadline)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = font
            return attributes
        }
        button.configuration = configuration
        button.isEnabled = context.environment.isEnabled
        // A spinning button has already been tapped; it stays at full
        // strength, unlike a disabled one, but takes no second tap.
        button.isUserInteractionEnabled = !(isLoading && style == .filled)
        button.accessibilityLabel = accessibilityLabel ?? title
        button.accessibilityValue = isLoading ? "In progress" : nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let fitting = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        guard style == .filled, let width = proposal.width, width.isFinite else { return fitting }
        return CGSize(width: width, height: fitting.height)
    }

    /// The text style's current size, semibold like SwiftUI's button titles.
    private static func font(_ style: UIFont.TextStyle) -> UIFont {
        .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: .semibold)
    }

    @MainActor
    final class Coordinator {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }
    }
}
