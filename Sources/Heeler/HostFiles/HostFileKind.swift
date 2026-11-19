import Foundation

/// How Files opens a Host file, read from its name before any byte is. A
/// name that says nothing is `.other`, which is read for text
/// (`HostFileText`).
enum HostFileKind: Equatable, Sendable {
    case markdown
    case image
    case video
    case audio
    /// A document the system previews: PDF, RTF and office files.
    case document
    case other

    init(name: String) {
        let ending = Self.pathExtension(of: name)
        if Self.markdownExtensions.contains(ending) {
            self = .markdown
        } else if ChatImagePath.hasImageExtension(name) {
            self = .image
        } else if Self.videoExtensions.contains(ending) {
            self = .video
        } else if Self.audioExtensions.contains(ending) {
            self = .audio
        } else if Self.documentExtensions.contains(ending) {
            self = .document
        } else {
            self = .other
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .other: "doc"
        }
    }

    /// The lowercased ending after the last dot; empty for a dot file's own
    /// name (`.env`) and for a name with no dot.
    static func pathExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mdx"]
    /// The containers the system player opens; anything else is shared or
    /// saved instead.
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
    private static let documentExtensions: Set<String> = [
        "pdf", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
    ]
}

/// Whether bytes from the start of a file read as text, and the text itself.
enum HostFileText {
    /// How much of a file's start decides.
    static let sampleBytes = 8 << 10

    /// Text has no NUL and is UTF-8. `data` may stop inside a character, as
    /// the first part of a longer file does.
    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(sampleBytes)
        guard !sample.contains(0) else { return false }
        return String(data: trimmingCutCharacter(sample), encoding: .utf8) != nil
    }

    /// The bytes as text. A character cut at either end of a part of a file
    /// is dropped; any other byte that is not UTF-8 shows as U+FFFD.
    static func decode(_ data: Data, cutAtStart: Bool = false, cutAtEnd: Bool = false) -> String {
        var bytes = data
        if cutAtStart {
            // Continuation bytes belong to a character that began earlier.
            var start = bytes.startIndex
            while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80, start - bytes.startIndex < 3 {
                start += 1
            }
            bytes = bytes[start...]
        }
        if cutAtEnd { bytes = trimmingCutCharacter(bytes) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Drops a multi-byte character the data ends inside.
    private static func trimmingCutCharacter(_ data: Data) -> Data {
        var index = data.endIndex
        var continuations = 0
        while index > data.startIndex, continuations < 4 {
            let byte = data[index - 1]
            if byte & 0xC0 == 0x80 {
                continuations += 1
                index -= 1
                continue
            }
            let expected: Int
            switch byte {
            case 0xC0...0xDF: expected = 1
            case 0xE0...0xEF: expected = 2
            case 0xF0...0xF7: expected = 3
            default: return data
            }
            return continuations < expected ? data[..<(index - 1)] : data
        }
        return data
    }
}

/// The words Files puts beside a name.
enum HostFileFormat {
    /// A change this recent is marked, so what an Agent just wrote stands out.
    static let recentInterval: TimeInterval = 10 * 60

    static func size(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    static func isRecent(_ modified: Date?, now: Date = .now) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < recentInterval
    }

    /// A week of relative times, then the date. A Host clock ahead of this
    /// device's reads as now.
    static func modified(_ date: Date, now: Date = .now) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return String(localized: "Just now") }
        if age < 7 * 24 * 3_600 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(
            sameYear
                ? .dateTime.month(.abbreviated).day()
                : .dateTime.year().month(.abbreviated).day())
    }

    /// `4.2 KB · 2 min. ago`, with whichever part the Host reported.
    static func detail(size: UInt64?, modified: Date?, now: Date = .now) -> String {
        [size.map(Self.size), modified.map { Self.modified($0, now: now) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
