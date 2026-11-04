import CoreText
import Foundation
import Observation
import UIKit

enum TerminalFontOption: String, CaseIterable, Identifiable, Sendable {
    /// libghostty's own JetBrains Mono, embedded in its binary: no
    /// `font-family` at all. Stored as "system", the name this choice had
    /// while it was taken for the platform's monospace face.
    case jetBrainsMono = "system"
    case ibmPlexMono = "ibm-plex-mono"
    case menlo
    case courierNew = "courier-new"

    var id: Self { self }

    /// Stored values of choices since folded into another.
    static let retiredRawValues: [String: TerminalFontOption] = [
        // A bundled copy of the face libghostty already embeds.
        "jetbrains-mono": .jetBrainsMono,
    ]

    var title: String {
        switch self {
        case .jetBrainsMono: "JetBrains Mono"
        case .ibmPlexMono: "IBM Plex Mono"
        case .menlo: "Menlo"
        case .courierNew: "Courier New"
        }
    }

    /// The CoreText family name ghostty resolves. `nil` sets no `font-family`
    /// at all, leaving libghostty's embedded default in place.
    var familyName: String? {
        switch self {
        case .jetBrainsMono: nil
        case .ibmPlexMono: "IBM Plex Mono"
        case .menlo: "Menlo"
        case .courierNew: "Courier New"
        }
    }

    /// Whether the face ships inside the app, rather than with libghostty or
    /// iOS.
    var isBundled: Bool { self == .ibmPlexMono }
}

/// Registers the faces shipped inside the app so CoreText — and therefore
/// ghostty's `font-family` lookup — can find them by family name.
///
/// Registration happens in code rather than through an `UIAppFonts` entry
/// because the app's Info.plist is generated from build settings, which
/// cannot express an array.
enum TerminalFontCatalog {
    private static let bundledFaces = [
        "IBMPlexMono-Regular",
        "IBMPlexMono-Bold",
    ]

    /// Family names read from the bundled face files after a registration
    /// attempt. URL-derived descriptors describe the file; they do not prove
    /// CoreText matching will resolve the face. Missing files are omitted so
    /// the UI does not offer a choice we did not ship.
    static func registerBundledFonts(in bundle: Bundle = .main) -> Set<String> {
        let urls = bundledFaces.compactMap {
            bundle.url(forResource: $0, withExtension: "ttf")
        }
        guard !urls.isEmpty else { return [] }
        // Deliberately retain the deprecated CTFontManagerRegisterFontsForURLs:
        // CTFontManagerRegisterFontURLs reports completion and errors only via
        // an async registrationHandler, while this catalog must know
        // registration has finished before returning available families. A
        // nil errors out-parameter ignores expected re-registration failures.
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
    /// libghostty's default, bundled options whose face files are present in
    /// the bundle, and iOS faces the system has.
    let availableOptions: [TerminalFontOption]
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let bundled = TerminalFontCatalog.registerBundledFonts(in: bundle)
        let system = Set(UIFont.familyNames)
        availableOptions = TerminalFontOption.allCases.filter { option in
            guard let family = option.familyName else { return true }
            return option.isBundled ? bundled.contains(family) : system.contains(family)
        }

        let stored = defaults.string(forKey: Self.defaultsKey).flatMap {
            TerminalFontOption(rawValue: $0) ?? TerminalFontOption.retiredRawValues[$0]
        } ?? .jetBrainsMono
        selection = availableOptions.contains(stored) ? stored : .jetBrainsMono
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
