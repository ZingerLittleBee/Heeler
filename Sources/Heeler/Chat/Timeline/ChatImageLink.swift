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

    /// Short display title for a numbered image reference (such as `Image #1`),
    /// used by the preview sheet and menus in place of generic staged filenames.
    enum TitleAttribute: AttributedStringKey {
        typealias Value = String
        static let name = "HeelerChatImageTitle"
    }

    struct Reference: Equatable, Sendable {
        let path: String
        let title: String?

        init(path: String, title: String? = nil) {
            self.path = path
            self.title = title
        }
    }

    static func stagedImageLabel(number: Int) -> String {
        let formatted = number.formatted()
        return String(
            localized: "Image #\(formatted)",
            comment: "Short label shown in a sent Chat message bubble in place of a staged image's temporary Host path, numbered in order within the message (e.g. Image #1).")
    }

    /// Whether `path` is a temporary Host path created when Heeler stages an
    /// image (POSIX `.../heeler.../stage-.../...` or native Windows `herdr-core`
    /// `...\herdr-core\...\files\<terminal>\image...`).
    static func isStagedImagePath(_ path: String) -> Bool {
        if RemoteHostPath.isWindowsAbsolute(path) {
            let parts = path.split { $0 == "\\" || $0 == "/" }.map { $0.lowercased() }
            guard parts.count >= 5,
                let filename = parts.last,
                filename.hasPrefix("image"),
                ChatImagePath.hasImageExtension(filename),
                let coreIndex = parts.firstIndex(of: "herdr-core"),
                let filesIndex = parts[coreIndex...].firstIndex(of: "files"),
                filesIndex + 2 == parts.count - 1
            else { return false }
            return true
        }
        guard namesImageFile(path) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3 else { return false }
        let stage = components[components.count - 2]
        let parent = components[components.count - 3]
        guard stage.hasPrefix("stage-"), stage.count > 6 else { return false }
        return parent == "heeler" || parent.hasPrefix("heeler.") || parent.hasPrefix("heeler-")
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
    /// not Markdown, as the user's own messages are, and with each
    /// `[Image #N]` placeholder also marked as the file its image came from
    /// when there is one file for every placeholder. Staged image paths from
    /// Heeler's Composer are shortened to localized `Image #n` labels while
    /// keeping their underlying Host paths for preview.
    static func marking(
        _ text: String,
        imagePaths: [String] = [],
        stagedImagePaths: [String] = []
    ) -> AttributedString {
        let placeholderMatches = text.matches(of: #/\[Image #([0-9]+)\]/#)
        let highestPlaceholder = placeholderMatches.compactMap { Int($0.output.1) }.max() ?? 0
        var numbering = StagedNumbering(
            startingAfter: highestPlaceholder,
            knownStagedPaths: Set(stagedImagePaths.filter { !$0.isEmpty }))

        guard !placeholderMatches.isEmpty, placeholderMatches.count == imagePaths.count else {
            var result = AttributedString()
            appendUserText(text, numbering: &numbering, trimsTrailingSpaceAfterStaged: true, to: &result)
            return result
        }

        var result = AttributedString()
        var start = text.startIndex
        for (match, path) in zip(placeholderMatches, imagePaths) {
            let range = match.range
            appendUserText(
                String(text[start..<range.lowerBound]),
                numbering: &numbering,
                trimsTrailingSpaceAfterStaged: false,
                to: &result)
            var piece = AttributedString(String(text[range]))
            piece[PathAttribute.self] = path
            if numbering.isStaged(path), let number = Int(match.output.1) {
                piece[TitleAttribute.self] = stagedImageLabel(number: number)
            }
            result.append(piece)
            start = range.upperBound
        }
        appendUserText(
            String(text[start...]),
            numbering: &numbering,
            trimsTrailingSpaceAfterStaged: true,
            to: &result)
        return result
    }

    /// UTF-8 byte count of `text` as `marking(_:imagePaths:)` displays it, for
    /// user bubble height estimation.
    static func displayedByteCount(of text: String, imagePaths: [String] = []) -> Int {
        guard text.localizedCaseInsensitiveContains("heeler")
            || text.localizedCaseInsensitiveContains("herdr-core")
        else {
            return text.utf8.count
        }
        return String(marking(text, imagePaths: imagePaths).characters).utf8.count
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

    /// The image references `content` marks, each path once, in reading order.
    static func references(in content: AttributedString) -> [Reference] {
        var seen: Set<String> = []
        var result: [Reference] = []
        for run in content.runs {
            guard let path = run[PathAttribute.self], seen.insert(path).inserted else { continue }
            result.append(Reference(path: path, title: run[TitleAttribute.self]))
        }
        return result
    }

    /// The paths `content` marks, each once, in reading order.
    static func paths(in content: AttributedString) -> [String] {
        references(in: content).map(\.path)
    }

    // MARK: Opening

    private static let scheme = "heeler-chat-image"

    /// The link a marked path is drawn with. It opens nothing outside Chat:
    /// `ChatLinkPolicy` refuses it, and only Chat's handler reads it.
    static func url(for path: String, title: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let title, !title.isEmpty {
            items.append(URLQueryItem(name: "title", value: title))
        }
        components.queryItems = items
        return components.url
    }

    /// The image reference a link from `url(for:title:)` opens; nil for every
    /// other link.
    static func opening(_ url: URL) -> Reference? {
        guard url.scheme == scheme,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let path = items.first(where: { $0.name == "path" })?.value
        else { return nil }
        let title = items.first(where: { $0.name == "title" })?.value
        return Reference(path: path, title: title?.isEmpty == true ? nil : title)
    }

    /// The path a link from `url(for:)` opens; nil for every other link.
    static func path(opening url: URL) -> String? {
        opening(url)?.path
    }

    // MARK: Staged Numbering

    private struct StagedNumbering {
        private var nextNumber: Int
        private var assigned: [String: Int] = [:]
        let knownStagedPaths: Set<String>

        init(startingAfter highestPlaceholder: Int = 0, knownStagedPaths: Set<String> = []) {
            self.nextNumber = max(1, highestPlaceholder + 1)
            self.knownStagedPaths = knownStagedPaths
        }

        func isStaged(_ path: String) -> Bool {
            knownStagedPaths.contains(path) || ChatImageLink.isStagedImagePath(path)
        }

        mutating func label(for path: String) -> String {
            if let existing = assigned[path] {
                return ChatImageLink.stagedImageLabel(number: existing)
            }
            let number = nextNumber
            nextNumber += 1
            assigned[path] = number
            return ChatImageLink.stagedImageLabel(number: number)
        }
    }

    private static func appendUserText(
        _ text: String,
        numbering: inout StagedNumbering,
        trimsTrailingSpaceAfterStaged: Bool,
        to content: inout AttributedString
    ) {
        let ranges = userPathRanges(in: text, knownStagedPaths: numbering.knownStagedPaths)
        var start = text.startIndex
        var lastWasStaged = false
        for range in ranges {
            if start < range.lowerBound {
                content.append(AttributedString(String(text[start..<range.lowerBound])))
            }
            let path = String(text[range])
            if numbering.isStaged(path) {
                let label = numbering.label(for: path)
                var piece = AttributedString(label)
                piece[PathAttribute.self] = path
                piece[TitleAttribute.self] = label
                content.append(piece)
                lastWasStaged = true
            } else {
                var piece = AttributedString(path)
                piece[PathAttribute.self] = path
                content.append(piece)
                lastWasStaged = false
            }
            start = range.upperBound
        }
        guard start < text.endIndex else { return }
        let tail = text[start...]
        if trimsTrailingSpaceAfterStaged, lastWasStaged,
            tail.allSatisfy({ $0 == " " || $0 == "\t" })
        {
            return
        }
        content.append(AttributedString(String(tail)))
    }

    private static func userPathRanges(in text: String, knownStagedPaths: Set<String>) -> [Range<String.Index>] {
        if knownStagedPaths.isEmpty, !text.contains(":\\") {
            return pathRanges(in: text)
        }
        var accepted: [Range<String.Index>] = []
        func overlaps(_ candidate: Range<String.Index>) -> Bool {
            accepted.contains { $0.overlaps(candidate) }
        }
        for known in knownStagedPaths.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                let range = text.range(of: known, options: .literal, range: searchStart..<text.endIndex)
            {
                let validStart =
                    range.lowerBound == text.startIndex
                    || mayPrecedePath(text[text.index(before: range.lowerBound)])
                let validEnd = endsName(text[range.upperBound...])
                if validStart, validEnd, !overlaps(range) {
                    accepted.append(range)
                    searchStart = range.upperBound
                } else {
                    searchStart = text.index(after: range.lowerBound)
                }
            }
        }
        if text.contains(":\\") {
            let windowsPattern =
                #/[A-Za-z]:\\(?:[^\\\r\n"'<>|*?]+\\)*herdr-core\\(?:[^\\\r\n"'<>|*?]+\\)*files\\[^\\\r\n\s"'<>|*?]+\\image[^\\\r\n\s"'<>|*?]*\.(?:avif|bmp|gif|heic|heif|jpe?g|png|tiff?|webp)/#
                .ignoresCase()
            for match in text.matches(of: windowsPattern) {
                let range = match.range
                let validStart =
                    range.lowerBound == text.startIndex
                    || mayPrecedePath(text[text.index(before: range.lowerBound)])
                let validEnd = endsName(text[range.upperBound...])
                if validStart, validEnd, !overlaps(range) {
                    accepted.append(range)
                }
            }
        }
        for range in pathRanges(in: text) where !overlaps(range) {
            accepted.append(range)
        }
        return accepted.sorted { $0.lowerBound < $1.lowerBound }
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
