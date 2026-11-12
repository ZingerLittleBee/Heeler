import Foundation

/// A program on screen asking for a password, read from the last line of
/// text in the viewport: `[sudo] password for zeng:`, `Password:`,
/// `Enter passphrase for key '/home/zeng/.ssh/id_ed25519':`.
///
/// The cursor's position is not available, so the last non-blank line stands
/// in for the line the cursor is on. A prompt ends with a colon and names a
/// password in one of the words below; anything else is not one. The reading
/// only decides whether Heeler offers to fill a password. Any program can
/// print the same words, so it never fills or sends anything by itself.
struct TerminalPasswordPrompt: Equatable, Sendable {
    /// The prompt as the screen shows it, without surrounding blanks.
    let line: String

    /// Longer lines are output that happens to end in a colon, not a prompt.
    static let maximumLength = 160

    /// Words that name a password, lowercased, as prompts print them in the
    /// languages Linux and macOS localize `sudo`, `su` and `passwd` into.
    static let passwordWords = [
        "password", "passphrase", "passcode", "passwort", "mot de passe",
        "contraseña", "senha", "пароль", "密码", "密碼", "口令", "パスワード",
        "비밀번호", "암호",
    ]

    init?(viewport text: String) {
        guard let lastLine = Self.textLines(of: text).last, Self.asksForPassword(lastLine) else {
            return nil
        }
        line = lastLine
    }

    /// The viewport's lines that show text, top to bottom, without
    /// surrounding blanks.
    static func textLines(of viewport: String) -> [String] {
        viewport
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func asksForPassword(_ line: String) -> Bool {
        guard line.count <= maximumLength, line.hasSuffix(":") || line.hasSuffix("：") else {
            return false
        }
        let lowercased = line.lowercased()
        return passwordWords.contains { lowercased.contains($0) }
            // A security key's PIN: `Enter PIN for ECDSA-SK key …:`.
            || lowercased.range(of: #"\bpin\b"#, options: .regularExpression) != nil
    }
}
