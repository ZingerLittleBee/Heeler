import Foundation

/// What OpenCode's input box reads as more than a message, beyond the shared
/// rules and its exit words (OpenCode 2.0.32).
///
/// herdr delivers a message as one paste, and OpenCode turns a paste that is
/// only paths to image, PDF or SVG files into attachments instead of text
/// (`tui/src/component/prompt/local-attachment.ts`). Chat cannot tell from
/// here which paths name such files, so it refuses every draft that is only
/// paths, read the way OpenCode reads a paste, and says how to send one:
/// with words first, since a draft that starts with an absolute path, as
/// Add Image and Add File leave one, is refused as a command path (below).
///
/// OpenCode names a command by its file's path under `commands/`, so
/// `.opencode/commands/git/commit.md` is `/git/commit`, and a message whose
/// first word names one runs it (`tui/src/component/prompt/index.tsx`). A
/// command's template can run shell commands without asking. Chat cannot
/// see which commands exist, so a leading `/name` with a slash in it, which
/// the shared rules leave to prose such as `/usr/bin/env`, is refused too.
enum OpenCodeSendRules {
    private static let pathOnlyRefusal = ComposerRefusal.unsafeText(
        "OpenCode can take a message that is only a file path as an attachment instead of text. "
            + "Start with a few words, such as what to do with the file, and OpenCode's agent can read it "
            + "from its path.")

    /// The most paths OpenCode reads from one paste; more is text.
    private static let maximumPaths = 32
    /// The extensions of the files OpenCode attaches.
    private static let attachableExtensions = [".avif", ".gif", ".jpeg", ".jpg", ".pdf", ".png", ".svg", ".webp"]
    /// Starts that make a token a path wherever it points.
    private static let pathPrefixes = ["~/", "./", "../", "file://"]

    /// The refusal of a draft without its invisible characters (`clean`)
    /// that, trimmed, is only paths or starts with a command path; nil for
    /// any other.
    static func refusal(_ clean: String, _ trimmed: String) -> ComposerRefusal? {
        if isOnlyPaths(trimmed) { return pathOnlyRefusal }
        if let name = commandPath(trimmed) {
            return .unsafeText(
                "OpenCode can run a message starting with /\(name) as one of its commands. "
                    + "Start with another word, or open the terminal to run it.")
        }
        return nil
    }

    /// The first word of a draft starting with `/` when it has another
    /// slash, `git/commit` in `/git/commit fix the typo`; nil otherwise.
    private static func commandPath(_ trimmed: String) -> Substring? {
        guard trimmed.hasPrefix("/") else { return nil }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
        return name.contains("/") ? name : nil
    }

    /// Whether OpenCode could read the trimmed draft as paths rather than
    /// text: 1 to 32 tokens that each look like a path, or the whole draft
    /// as one path to an attachable file, which catches a path with spaces.
    private static func isOnlyPaths(_ trimmed: String) -> Bool {
        if let tokens = pathTokens(trimmed), !tokens.isEmpty, tokens.allSatisfy(isPathLike) { return true }
        let whole = wholePath(trimmed)
        return startsLikeAPath(whole) && hasAttachableExtension(whole)
    }

    /// The text split the way OpenCode splits a paste into paths: whitespace
    /// separates, quotes group, a backslash escapes the next character
    /// outside quotes and inside double ones, and a `file://` URL becomes
    /// its path. With a `file://` URL in the text, lines starting with `#`
    /// are comments, as in a URI list. nil when a quote is left open or
    /// there are more than 32 tokens, which OpenCode reads as no paths.
    private static func pathTokens(_ text: String) -> [String]? {
        var input = text
        if input.contains("file://") {
            input = input.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
                .filter { !$0.drop(while: \.isWhitespace).hasPrefix("#") }
                .joined(separator: "\n")
        }
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        func push() {
            guard !current.isEmpty else { return }
            tokens.append(fileURLPath(current) ?? current)
            current = ""
        }
        for character in input {
            if isEscaping {
                current.append(character)
                isEscaping = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    isEscaping = true
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                isEscaping = true
            } else if character.isWhitespace {
                push()
                if tokens.count > maximumPaths { return nil }
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        // A backslash at the very end escapes nothing and stays.
        if isEscaping { current.append("\\") }
        push()
        return tokens.count > maximumPaths ? nil : tokens
    }

    /// Whether a token looks like a path: it starts like one, or names an
    /// attachable file and is not a link with another scheme.
    private static func isPathLike(_ token: String) -> Bool {
        startsLikeAPath(token)
            || (token.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil
                && hasAttachableExtension(token))
    }

    /// `~/`, `./`, `../`, `file://`, or an absolute path of more than one
    /// segment: a single-segment `/name` is left to the command rules.
    private static func startsLikeAPath(_ text: String) -> Bool {
        pathPrefixes.contains(where: text.hasPrefix) || (text.hasPrefix("/") && text.dropFirst().contains("/"))
    }

    private static func hasAttachableExtension(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return attachableExtensions.contains(where: lowered.hasSuffix)
    }

    /// The whole text read as one path, as OpenCode first tries a paste:
    /// quotes at either end dropped, then a `file://` URL decoded, or else
    /// backslash escapes removed.
    private static func wholePath(_ text: String) -> String {
        let unquoted = text.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if let path = fileURLPath(unquoted) { return path }
        var path = ""
        var isEscaping = false
        for character in unquoted {
            if isEscaping {
                // An escaped line break stays as it is.
                if character.isNewline { path.append("\\") }
                path.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                path.append(character)
            }
        }
        if isEscaping { path.append("\\") }
        return path
    }

    /// The path a `file://` URL names, percent escapes decoded; nil for a
    /// URL that names a host other than `localhost`, encodes a slash or a
    /// backslash, or does not decode, which OpenCode keeps as typed.
    private static func fileURLPath(_ text: String) -> String? {
        guard text.hasPrefix("file://") else { return nil }
        var rest = text.dropFirst("file://".count)
        // The query and fragment are not part of the path.
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        guard rest[..<slash].isEmpty || rest[..<slash].lowercased() == "localhost" else { return nil }
        let path = rest[slash...]
        guard path.range(of: "%2f", options: .caseInsensitive) == nil,
            path.range(of: "%5c", options: .caseInsensitive) == nil,
            let decoded = String(path).removingPercentEncoding
        else { return nil }
        return decoded.isEmpty ? "/" : decoded
    }
}
