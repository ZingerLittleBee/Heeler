import GhosttyTerminal
import UIKit

/// Decides whether a ghostty-core-initiated clipboard request needs an
/// explicit user prompt. Pure so it stays unit-testable without UIKit.
///
/// - `.osc52Write` prompts once per surface; an allowed write is remembered
///   for that surface's lifetime and later writes pass silently. Deny is
///   never remembered.
/// - `.osc52Read` always prompts (privacy-sensitive direction).
/// - `.paste` (unsafe paste) always prompts.
enum TerminalClipboardConfirmationPolicy: Sendable {
    static func requiresPrompt(
        for kind: TerminalClipboardRequestKind,
        osc52WriteApproved: Bool
    ) -> Bool {
        switch kind {
        case .paste, .osc52Read:
            return true
        case .osc52Write:
            return !osc52WriteApproved
        }
    }
}

/// Names control characters for the unsafe-paste prompt and truncates long
/// contents previews. Pure so it stays unit-testable without UIKit.
enum TerminalClipboardControlCharacters: Sendable {
    /// How many distinct control-character names the paste prompt lists
    /// before collapsing the rest into a count.
    static let maxReportedControls = 5
    /// How many characters of pasted contents the prompt previews.
    static let previewLimit = 200

    static func shortName(for scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x00: return "NUL"
        case 0x01: return "SOH"
        case 0x02: return "STX"
        case 0x03: return "ETX"
        case 0x04: return "EOT"
        case 0x05: return "ENQ"
        case 0x06: return "ACK"
        case 0x07: return "BEL"
        case 0x08: return "BS"
        case 0x09: return "HT"
        case 0x0A: return "LF"
        case 0x0B: return "VT"
        case 0x0C: return "FF"
        case 0x0D: return "CR"
        case 0x0E: return "SO"
        case 0x0F: return "SI"
        case 0x10: return "DLE"
        case 0x11: return "DC1"
        case 0x12: return "DC2"
        case 0x13: return "DC3"
        case 0x14: return "DC4"
        case 0x15: return "NAK"
        case 0x16: return "SYN"
        case 0x17: return "ETB"
        case 0x18: return "CAN"
        case 0x19: return "EM"
        case 0x1A: return "SUB"
        case 0x1B: return "ESC"
        case 0x1C: return "FS"
        case 0x1D: return "GS"
        case 0x1E: return "RS"
        case 0x1F: return "US"
        case 0x7F: return "DEL"
        default: return nil
        }
    }

    /// Distinct control-character short names in first-seen order.
    static func distinctControlNames(in contents: String) -> [String] {
        var seen: [String] = []
        for scalar in contents.unicodeScalars {
            guard let name = shortName(for: scalar), !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen
    }

    /// One-line summary for the paste prompt, e.g. `"ESC, CR"`.
    /// Caps the list at ``maxReportedControls`` and notes how many more
    /// distinct controls were found.
    static func summary(in contents: String) -> String {
        let names = distinctControlNames(in: contents)
        guard !names.isEmpty else { return "none" }
        let shown = names.prefix(maxReportedControls).joined(separator: ", ")
        let hidden = names.count - min(names.count, maxReportedControls)
        guard hidden > 0 else { return shown }
        return "\(shown), +\(hidden) more"
    }

    /// Truncates long contents with an ellipsis plus the remaining
    /// character count so the prompt stays readable.
    static func preview(of contents: String, limit: Int = previewLimit) -> String {
        guard contents.count > limit else { return contents }
        let head = String(contents.prefix(limit))
        return "\(head)… (+\(contents.count - limit) more characters)"
    }
}

@MainActor
enum TerminalClipboardConfirmationPresenter {
    /// Presents the confirmation alert and answers `request` exactly once:
    /// Allow responds true, Don't Allow responds false, and a missing
    /// presenter responds false immediately. `onCompletion` reports the
    /// decision so the caller can update per-view state.
    static func present(
        _ request: TerminalClipboardConfirmationRequest,
        from sourceView: UIView,
        onCompletion: @escaping (Bool) -> Void
    ) {
        guard let presentingViewController = sourceView.clipboardConfirmationPresenter else {
            request.respond(allow: false)
            onCompletion(false)
            return
        }
        let alert = UIAlertController(
            title: title(for: request.kind),
            message: message(for: request),
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Don't Allow", style: .cancel) { _ in
                request.respond(allow: false)
                onCompletion(false)
            })
        alert.addAction(
            UIAlertAction(title: "Allow", style: .default) { _ in
                request.respond(allow: true)
                onCompletion(true)
            })
        presentingViewController.present(alert, animated: true)
    }

    private static func title(for kind: TerminalClipboardRequestKind) -> String {
        switch kind {
        case .paste:
            return "Allow unsafe paste?"
        case .osc52Read:
            return "Allow clipboard read?"
        case .osc52Write:
            return "Allow clipboard write?"
        }
    }

    private static func message(for request: TerminalClipboardConfirmationRequest) -> String {
        switch request.kind {
        case .osc52Write:
            return """
                The program wants to copy text to the device clipboard. \
                Allow, and you won't be asked again for this terminal.
                """
        case .osc52Read:
            return """
                The program wants to READ the device clipboard. Only allow \
                this if you trust it with whatever you have copied.
                """
        case .paste:
            let controls = TerminalClipboardControlCharacters.summary(in: request.contents)
            let preview = TerminalClipboardControlCharacters.preview(of: request.contents)
            return """
                The program wants to paste text containing control \
                characters (\(controls)). Review before allowing:\n\n\(preview)
                """
        }
    }
}

extension UIView {
    fileprivate var clipboardConfirmationPresenter: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController.topmostForClipboardConfirmation
            }
            responder = current.next
        }
        return window?.rootViewController?.topmostForClipboardConfirmation
    }
}

extension UIViewController {
    fileprivate var topmostForClipboardConfirmation: UIViewController {
        if let presentedViewController {
            return presentedViewController.topmostForClipboardConfirmation
        }
        if let navigation = self as? UINavigationController,
            let visible = navigation.visibleViewController
        {
            return visible.topmostForClipboardConfirmation
        }
        if let tab = self as? UITabBarController,
            let selected = tab.selectedViewController
        {
            return selected.topmostForClipboardConfirmation
        }
        return self
    }
}
