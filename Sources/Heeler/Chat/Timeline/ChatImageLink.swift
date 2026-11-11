import Foundation

/// An image file on the Host that a message names by its path. Chat draws
/// the path as a link that opens the file in the image preview, as an image
/// row's thumbnail does; nothing is read before the tap.
///
/// A message names an image in one of five ways: an inline code span or a
/// line of a code block that is a path, a link or a Markdown image whose
/// destination is a path, or an absolute or home path spelled out in the
/// text. Paths stay as written, which may be relative to the Agent's
/// directory or start at `~`; the Agent's Chat resolves them when one is
/// opened (`ChatImagePath.resolve`).
enum ChatImageLink {
    /// The path as written, on the runs of message text that name an image.
    enum PathAttribute: AttributedStringKey {
        typealias Value = String
        static let name = "HeelerChatImagePath"
    }

    /// The path a code span or a link's destination names, when it is one
    /// image file. A path from the root or the home directory may hold
    /// spaces, as screenshots' names do; a relative one may not, nor
    /// anything that reads as code, so `UIImage(named: "a.png")` stays code.
    /// Globs, URLs other than `file:`, and bare extensions name no file.
    static func path(written value: String) -> String? {
        let path = value.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path.utf8.count <= 4_096,
            path.rangeOfCharacter(from: .controlCharacters) == nil,
            path.rangeOfCharacter(from: .newlines) == nil
        else { return nil }
        if path.lowercased().hasPrefix("file:") {
            guard let resolved = ChatImagePath.resolve(path, cwd: nil), namesImageFile(resolved) else { return nil }
            return path
        }
        let isRooted = path.hasPrefix("/") || path.hasPrefix("~/")
        if !isRooted {
            guard path.first != "-", path.first != "~", path.rangeOfCharacter(from: relativeExclusions) == nil
            else { return nil }
        }
        guard path.rangeOfCharacter(from: rootedExclusions) == nil, namesImageFile(path) else { return nil }
        return path
    }

    /// The path a link or a Markdown image points at. Web links stay links,
    /// and a web image keeps only its alt text.
    static func path(linkedBy url: URL) -> String? {
        if url.scheme?.lowercased() == "file" { return path(written: url.absoluteString) }
        guard url.scheme == nil, let written = url.relativeString.removingPercentEncoding else { return nil }
        return path(written: written)
    }

    /// Where the absolute and home paths to image files spelled out in
    /// plain text lie. A path ends at whitespace, quotes, brackets or CJK
    /// punctuation, and at the first image extension that ends a name, so
    /// a sentence's period or a following Chinese word stays outside it.
    /// Relative paths are left alone in prose, where `and/or.png` is not a
    /// file; a slash after a letter, digit or URL punctuation starts none.
    static func pathRanges(in text: String) -> [Range<String.Index>] {
        guard text.contains("/") else { return [] }
        var ranges: [Range<String.Index>] = []
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let opensPath = character == "/" || (character == "~" && next < text.endIndex && text[next] == "/")
            guard opensPath, previous.map(Self.mayPrecedePath) ?? true else {
                previous = character
                index = next
                continue
            }
            var end = index
            while end < text.endIndex, !Self.endsPath(text[end]) { end = text.index(after: end) }
            // A candidate without an image is passed over whole, so the
            // slashes inside it start nothing.
            let stop = Self.imageEnd(in: text[index..<end])
            if let stop { ranges.append(index..<stop) }
            index = stop ?? end
            previous = text[text.index(before: index)]
        }
        return ranges
    }

    /// `text` with the paths `pathRanges` finds marked, for text that is
    /// not Markdown, as the user's own messages are.
    static func marking(_ text: String) -> AttributedString {
        var result = AttributedString()
        append(text, attributes: AttributeContainer(), to: &result)
        return result
    }

    /// `text` marked as `marking(_:)` marks it, with each `[Image #N]`
    /// placeholder also marked as the file its image came from, in order,
    /// when there is one file for every placeholder.
    static func marking(_ text: String, imagePaths: [String]) -> AttributedString {
        let placeholders = text.ranges(of: #/\[Image #[0-9]+\]/#)
        guard !placeholders.isEmpty, placeholders.count == imagePaths.count else { return marking(text) }
        var result = AttributedString()
        var start = text.startIndex
        for (range, path) in zip(placeholders, imagePaths) {
            append(String(text[start..<range.lowerBound]), attributes: AttributeContainer(), to: &result)
            var piece = AttributedString(String(text[range]))
            piece[PathAttribute.self] = path
            result.append(piece)
            start = range.upperBound
        }
        append(String(text[start...]), attributes: AttributeContainer(), to: &result)
        return result
    }

    /// A code block's `text` with each line that is, on its own, a path to
    /// one image file marked, as `path(written:)` decides for a code span.
    /// Agents list files one per line in a block; a line that only mentions
    /// one, as `cp a.png b.png` does, stays code. Whatever surrounds the
    /// path on its line stays outside the mark.
    static func markingLines(_ text: String) -> AttributedString {
        var result = AttributedString()
        var plain = ""
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { plain += "\n" }
            guard let path = path(written: String(line)), let range = line.range(of: path, options: .literal) else {
                plain += line
                continue
            }
            plain += line[..<range.lowerBound]
            result.append(AttributedString(plain))
            plain = String(line[range.upperBound...])
            var piece = AttributedString(path)
            piece[PathAttribute.self] = path
            result.append(piece)
        }
        result.append(AttributedString(plain))
        return result
    }

    /// Appends `text` in `attributes`, with the paths `pathRanges` finds
    /// marked.
    static func append(_ text: String, attributes: AttributeContainer, to content: inout AttributedString) {
        var start = text.startIndex
        for range in pathRanges(in: text) {
            if start < range.lowerBound {
                content.append(AttributedString(String(text[start..<range.lowerBound]), attributes: attributes))
            }
            var piece = AttributedString(String(text[range]), attributes: attributes)
            piece[PathAttribute.self] = String(text[range])
            content.append(piece)
            start = range.upperBound
        }
        if start < text.endIndex {
            content.append(AttributedString(String(text[start...]), attributes: attributes))
        }
    }

    /// The paths `content` marks, each once, in reading order.
    static func paths(in content: AttributedString) -> [String] {
        var seen: Set<String> = []
        return content.runs.compactMap { $0[PathAttribute.self] }.filter { seen.insert($0).inserted }
    }

    // MARK: Opening

    private static let scheme = "heeler-chat-image"

    /// The link a marked path is drawn with. It opens nothing outside Chat:
    /// `ChatLinkPolicy` refuses it, and only Chat's handler reads it.
    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The path a link from `url(for:)` opens; nil for every other link.
    static func path(opening url: URL) -> String? {
        guard url.scheme == scheme,
            let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })
        else { return nil }
        return item.value
    }

    // MARK: Matching

    /// Code-like characters; any of them makes a written value no path.
    private static let rootedExclusions = CharacterSet(charactersIn: "*?\"'`<>|$\\")
    /// A relative path also holds no whitespace or punctuation of code.
    private static let relativeExclusions = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()[]{};,=:"))

    /// An image extension ends a name with something before its dot.
    private static func namesImageFile(_ path: String) -> Bool {
        guard ChatImagePath.hasImageExtension(path),
            let name = path.split(separator: "/", omittingEmptySubsequences: false).last,
            let dot = name.lastIndex(of: ".")
        else { return false }
        return dot != name.startIndex
    }

    /// A path in prose follows anything but a letter or digit of a word in
    /// Latin script or URL punctuation: `:` would start one inside
    /// `ftp://`. CJK text may run into a path without a space.
    private static func mayPrecedePath(_ character: Character) -> Bool {
        if character.isASCII, character.isLetter || character.isNumber { return false }
        return !"_-./~:\\@#%&+*$".contains(character)
    }

    private static func endsPath(_ character: Character) -> Bool {
        character.isWhitespace || "\"'`<>()[]{}|*?\\，。；：、！？（）【】「」『』《》“”‘’".contains(character)
    }

    /// The end of the shortest prefix of `candidate` that ends with an
    /// image file's name: its extension, followed by nothing that would
    /// continue the name or the path.
    private static func imageEnd(in candidate: Substring) -> String.Index? {
        var index = candidate.startIndex
        while let dot = candidate[index...].firstIndex(of: ".") {
            var end = candidate.index(after: dot)
            while end < candidate.endIndex, candidate[end].isASCII, candidate[end].isLetter {
                end = candidate.index(after: end)
            }
            let prefix = String(candidate[..<end])
            if end > candidate.index(after: dot), namesImageFile(prefix), endsName(candidate[end...]) {
                return end
            }
            index = candidate.index(after: dot)
        }
        return nil
    }

    /// Whether what follows an extension leaves it ending the name: a
    /// period ending a sentence does, `.bak` or `/thumb.png` does not.
    private static func endsName(_ rest: Substring) -> Bool {
        guard let first = rest.first else { return true }
        if first.isASCII, first.isLetter || first.isNumber { return false }
        if "_-/".contains(first) { return false }
        if first == ".", let second = rest.dropFirst().first, second.isASCII, second.isLetter || second.isNumber {
            return false
        }
        return true
    }
}
