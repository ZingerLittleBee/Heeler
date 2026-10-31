import CryptoKit
import Foundation

/// A harness configuration file changes only when the user accepts that one
/// change, shown exactly, and every such change can be undone (ADR 0033). This is
/// the one module those edits go through: an edit says what it wants the file to
/// become, and this reads, shows, writes and undoes.
struct HarnessConfigEdit: Sendable {
    /// What a file's bytes, or their absence, want to become.
    enum Transform: Equatable, Sendable {
        case change(to: Data)
        case alreadyApplied
        case refused(reason: String)
    }

    /// Stable across launches, for what the Host's detail lists.
    let id: String
    let harness: String
    let path: String
    let transform: @Sendable (Data?) -> Transform
}

/// One contiguous run of bytes that differs, cut at whole lines. Holds only what
/// changed, so what this device keeps of an edit holds nothing else of the file,
/// which may carry a harness's tokens.
struct HarnessConfigHunk: Codable, Equatable, Sendable {
    let offset: Int
    let removed: Data
    let added: Data

    init(before: Data, after: Data) {
        let old = Self.lines(before)
        let new = Self.lines(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        offset = old[..<prefix].reduce(0) { $0 + $1.count }
        removed = Data(old[prefix..<(old.count - suffix)].joined())
        added = Data(new[prefix..<(new.count - suffix)].joined())
    }

    /// `base` with this change made.
    func applied(to base: Data) -> Data {
        var result = base.prefix(offset)
        result.append(added)
        result.append(base.dropFirst(offset + removed.count))
        return Data(result)
    }

    /// `base`, which holds this change, as it was before it.
    func reverted(from base: Data) -> Data {
        var result = base.prefix(offset)
        result.append(removed)
        result.append(base.dropFirst(offset + added.count))
        return Data(result)
    }

    /// Each line with its terminator.
    static func lines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == UInt8(ascii: "\n") {
            lines.append(Data(data[start...index]))
            start = data.index(after: index)
        }
        if start < data.endIndex { lines.append(Data(data[start...])) }
        return lines
    }
}

/// The lines a change shows: exactly what goes away and what comes, nothing around them.
struct HarnessConfigShownLine: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case removed
        case added
    }

    let kind: Kind
    /// Without its terminator.
    let text: String
    /// The file's last line, with no newline. Adding one is a change too.
    let endsWithoutNewline: Bool

    static func lines(of hunk: HarnessConfigHunk) -> [HarnessConfigShownLine] {
        shown(hunk.removed, as: .removed) + shown(hunk.added, as: .added)
    }

    private static func shown(_ data: Data, as kind: Kind) -> [HarnessConfigShownLine] {
        HarnessConfigHunk.lines(data).map { line in
            var bytes = line[...]
            let endsWithNewline = bytes.last == UInt8(ascii: "\n")
            if endsWithNewline { bytes = bytes.dropLast() }
            if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
            return HarnessConfigShownLine(
                kind: kind, text: String(decoding: bytes, as: UTF8.self),
                endsWithoutNewline: !endsWithNewline)
        }
    }
}

/// An edit read and waiting for the user's word: the bytes it read, the bytes it
/// would write, and the change between them, which is what the user sees.
struct HarnessConfigPendingChange: Equatable, Sendable {
    let editID: String
    let harness: String
    let path: String
    /// Nil when there is no file yet.
    let before: Data?
    let after: Data

    var hunk: HarnessConfigHunk { HarnessConfigHunk(before: before ?? Data(), after: after) }
    var shownLines: [HarnessConfigShownLine] { HarnessConfigShownLine.lines(of: hunk) }
    var createsFile: Bool { before == nil }
}

/// What this device remembers of an edit it wrote, to list it and undo it.
struct HarnessConfigAppliedEdit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let editID: String
    let harness: String
    let path: String
    let hunk: HarnessConfigHunk
    /// Heeler created the file, so undoing removes it.
    let createdFile: Bool
    /// What Heeler wrote. Undo touches a file only while it still holds this.
    let writtenDigest: Data
    let appliedAt: Date

    var shownLines: [HarnessConfigShownLine] { HarnessConfigShownLine.lines(of: hunk) }
}

enum HarnessConfigProposal: Equatable, Sendable {
    case change(HarnessConfigPendingChange)
    /// The file already says this, so nothing is left to write.
    case alreadyApplied(path: String)
    case refused(path: String, reason: String)
}

/// A refusal the user is told about, with nothing written.
enum HarnessConfigEditError: Error, Equatable, LocalizedError {
    case changedSinceRead
    case changedSinceWritten
    case tooLarge
    case unreadable
    case unresolvedPath

    var errorDescription: String? {
        switch self {
        case .changedSinceRead:
            "The file changed after Heeler read it, so nothing was written. Review the change again."
        case .changedSinceWritten:
            "The file changed after Heeler edited it, so nothing was written. Undo the edit by hand if you still want to."
        case .tooLarge:
            "The file is too large for Heeler to edit, so nothing was written."
        case .unreadable:
            "Heeler couldn't read the whole file, so nothing was written."
        case .unresolvedPath:
            "This Agent's configuration folder isn't an absolute path, so Heeler can't tell which file to change."
        }
    }
}

/// Reads, writes and undoes harness edits over a Host's services.
struct HarnessConfigEditor: Sendable {
    /// A configuration file past this is no file Heeler should be rewriting.
    static let maximumFileSize = 1_048_576

    let files: any HostServices
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUID() }

    /// Reads the file and works out the change. Writes nothing.
    func propose(_ edit: HarnessConfigEdit) async throws -> HarnessConfigProposal {
        let before = try await read(edit.path)
        switch edit.transform(before) {
        case .alreadyApplied:
            return .alreadyApplied(path: edit.path)
        case .refused(let reason):
            return .refused(path: edit.path, reason: reason)
        case .change(let after):
            return .change(
                HarnessConfigPendingChange(
                    editID: edit.id, harness: edit.harness, path: edit.path, before: before,
                    after: after))
        }
    }

    /// Writes exactly what was shown, if the file still holds what was read.
    func apply(_ change: HarnessConfigPendingChange) async throws -> HarnessConfigAppliedEdit {
        do {
            try await files.replaceHostTextFile(
                path: change.path, expected: change.before, contents: change.after)
        } catch HostTextFileError.changedSinceRead {
            throw HarnessConfigEditError.changedSinceRead
        }
        return HarnessConfigAppliedEdit(
            id: makeID(), editID: change.editID, harness: change.harness, path: change.path,
            hunk: change.hunk, createdFile: change.createsFile,
            writtenDigest: Self.digest(change.after), appliedAt: now())
    }

    /// Puts the file back exactly as it was, if it still holds what Heeler wrote.
    func undo(_ applied: HarnessConfigAppliedEdit) async throws {
        guard let current = try await read(applied.path),
            Self.digest(current) == applied.writtenDigest
        else { throw HarnessConfigEditError.changedSinceWritten }
        do {
            try await files.replaceHostTextFile(
                path: applied.path, expected: current,
                contents: applied.createdFile ? nil : applied.hunk.reverted(from: current))
        } catch HostTextFileError.changedSinceRead {
            throw HarnessConfigEditError.changedSinceWritten
        }
    }

    private func read(_ path: String) async throws -> Data? {
        let slice = try await files.readHostFileRange(
            RemoteFileRange(path: path, offset: 0, maxBytes: Self.maximumFileSize))
        guard let length = slice.length else { return nil }
        guard length <= UInt64(Self.maximumFileSize) else { throw HarnessConfigEditError.tooLarge }
        guard UInt64(slice.data.count) == length else { throw HarnessConfigEditError.unreadable }
        return slice.data
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
