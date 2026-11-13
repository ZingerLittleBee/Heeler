import SwiftUI
import UIKit

/// UIKit's paste control, pinned edge to edge inside a plain view that
/// takes SwiftUI's frame. SwiftUI's `PasteButton` sizes its control from the
/// control's own measurement, which can come back 0×0 when it is first laid
/// out, leaving a blank slot where the glyph belongs. Pinned, the control is
/// always exactly the frame SwiftUI gives it, and follows that frame if it
/// changes. Its colors are set here too: `PasteButton`'s glyph is always
/// white, and in light mode iOS darkens a light tint behind it.
///
/// The control draws dynamic colors in the system's appearance, not in the
/// window's override that draws Heeler in its terminal theme's (see
/// `SceneAppearance`), so a dark theme under a light system got a light
/// capsule. Its colors are resolved here, once, against SwiftUI's color
/// scheme, and callers rebuild it when that changes.
struct PinnedPasteControl: UIViewRepresentable {
    /// Painted opaque by the control behind its glyph.
    let backgroundColor: UIColor
    /// A fixed corner radius, or nil for a capsule.
    var cornerRadius: CGFloat? = nil
    let paste: (String) -> Void

    /// The Direct Input key caps' translucent `secondarySystemFill`
    /// flattened onto the row's `secondarySystemBackground`, because the
    /// control paints its background opaque.
    static let keyCapFill = UIColor { traits in
        let fill = UIColor.secondarySystemFill.resolvedColor(with: traits)
        let base = UIColor.secondarySystemBackground.resolvedColor(with: traits)
        var (fillRed, fillGreen, fillBlue, fillAlpha): (CGFloat, CGFloat, CGFloat, CGFloat) =
            (0, 0, 0, 0)
        var (baseRed, baseGreen, baseBlue, baseAlpha): (CGFloat, CGFloat, CGFloat, CGFloat) =
            (0, 0, 0, 0)
        fill.getRed(&fillRed, green: &fillGreen, blue: &fillBlue, alpha: &fillAlpha)
        base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha)
        let blend = { (top: CGFloat, bottom: CGFloat) in
            top * fillAlpha + bottom * (1 - fillAlpha)
        }
        return UIColor(
            red: blend(fillRed, baseRed),
            green: blend(fillGreen, baseGreen),
            blue: blend(fillBlue, baseBlue),
            alpha: 1)
    }

    func makeUIView(context: Context) -> PinnedPasteView {
        let traits = UITraitCollection(
            userInterfaceStyle: context.environment.colorScheme == .dark ? .dark : .light)
        return PinnedPasteView(
            backgroundColor: backgroundColor.resolvedColor(with: traits),
            foregroundColor: UIColor.label.resolvedColor(with: traits),
            cornerRadius: cornerRadius, paste: paste)
    }

    func updateUIView(_ view: PinnedPasteView, context: Context) {
        view.onPaste = paste
    }
}

final class PinnedPasteView: UIView {
    var onPaste: (String) -> Void

    init(
        backgroundColor: UIColor, foregroundColor: UIColor, cornerRadius: CGFloat?,
        paste: @escaping (String) -> Void
    ) {
        onPaste = paste
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        if let cornerRadius {
            configuration.cornerStyle = .fixed
            configuration.cornerRadius = cornerRadius
        } else {
            configuration.cornerStyle = .capsule
        }
        configuration.baseForegroundColor = foregroundColor
        configuration.baseBackgroundColor = backgroundColor
        let control = UIPasteControl(configuration: configuration)
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: topAnchor),
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) })
        else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text, !text.isEmpty else { return }
            Task { @MainActor in self?.onPaste(text) }
        }
    }
}
