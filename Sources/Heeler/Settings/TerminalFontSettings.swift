import CoreText
import Foundation
import Observation

enum TerminalFontOption: String, CaseIterable, Identifiable, Sendable {
    case system
    case jetBrainsMono = "jetbrains-mono"
    case ibmPlexMono = "ibm-plex-mono"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .jetBrainsMono: "JetBrains Mono"
        case .ibmPlexMono: "IBM Plex Mono"
        }
    }

    var detail: String {
        switch self {
        case .system: "Menlo, whatever iOS resolves for a monospace face"
        case .jetBrainsMono: "Tall, open letterforms drawn for reading code"
        case .ibmPlexMono: "A quieter, more humanist monospace"
        }
    }

    /// The CoreText family name ghostty resolves. `nil` sets no `font-family`
    /// at all, leaving the platform's own choice in place.
    var familyName: String? {
        switch self {
        case .system: nil
        case .jetBrainsMono: "JetBrains Mono"
        case .ibmPlexMono: "IBM Plex Mono"
        }
    }
}

/// Registers the faces shipped inside the app so CoreText — and therefore
/// ghostty's `font-family` lookup — can find them by family name.
///
/// Registration happens in code rather than through an `UIAppFonts` entry
/// because the app's Info.plist is generated from build settings, which
/// cannot express an array.
enum TerminalFontCatalog {
    private static let bundledFaces = [
        "JetBrainsMono-Regular",
        "JetBrainsMono-Bold",
        "IBMPlexMono-Regular",
        "IBMPlexMono-Bold",
    ]

    /// The family names that are actually resolvable after registration.
    /// A face that failed to register is deliberately not reported, so the
    /// UI can hide a font it cannot honour instead of offering a choice that
    /// silently renders as something else.
    static func registerBundledFonts(in bundle: Bundle = .main) -> Set<String> {
        let urls = bundledFaces.compactMap {
            bundle.url(forResource: $0, withExtension: "ttf")
        }
        guard !urls.isEmpty else { return [] }
        // Re-registering an already-registered URL fails, which is expected
        // and harmless: what matters is whether the family resolves after.
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)

        return Set(
            urls.compactMap { url in
                (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?
                    .compactMap {
                        CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
                    }
            }.flatMap { $0 })
    }
}

/// The app-wide terminal font family. Like `TerminalZoomSettings`, it applies
/// to current and future Attach terminals without reconnecting.
@MainActor
@Observable
final class TerminalFontSettings {
    private static let defaultsKey = "terminal-font-family"

    private(set) var selection: TerminalFontOption
    /// `.system` plus whichever bundled families registered successfully.
    let availableOptions: [TerminalFontOption]
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let families = TerminalFontCatalog.registerBundledFonts(in: bundle)
        availableOptions = TerminalFontOption.allCases.filter { option in
            guard let family = option.familyName else { return true }
            return families.contains(family)
        }

        let stored =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(TerminalFontOption.init(rawValue:)) ?? .system
        selection = availableOptions.contains(stored) ? stored : .system
    }

    var familyName: String? {
        selection.familyName
    }

    func select(_ selection: TerminalFontOption) {
        guard selection != self.selection, availableOptions.contains(selection) else { return }
        self.selection = selection
        defaults.set(selection.rawValue, forKey: Self.defaultsKey)
    }
}
