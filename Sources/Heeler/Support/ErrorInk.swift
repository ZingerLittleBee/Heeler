import SwiftUI
import UIKit

extension ShapeStyle where Self == Color {
    /// The red of error and failure text the user has to read, and of an
    /// icon beside it: a form's or a sheet's error line, a failure label, a
    /// validation message. The system red reads about 3.2:1 on a grouped
    /// form's light background, under WCAG's 4.5:1 for text, so light mode
    /// takes a deeper red; dark mode takes a lighter one, which still reads
    /// on a sheet's raised rows. Red that is not text to read keeps the
    /// system's: destructive buttons, swipe actions, recording, badges and
    /// status dots, diff deletions.
    static var errorInk: Color { errorInkColor }
}

private let errorInkColor = Color(
    uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255, alpha: 1)
            : UIColor(red: 0xC4 / 255, green: 0x16 / 255, blue: 0x1C / 255, alpha: 1)
    })
