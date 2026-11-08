import Foundation

extension GitProbe.SectionName {
    /// The one framed command in an untracked-directory listing.
    static let untracked = "untracked"
}

/// Lists one untracked directory. Same preamble and framing as a Changes
/// read; the body is a single status, capped like the Changes status.
extension GitProbe {
    /// The pathspec is `directory` exactly as status printed it. Nothing in
    /// the body discovers the repository or asks for branch headers.
    static func untrackedDirectoryScript(
        topLevel: Data, directory: Data, nonce: String
    ) -> Data {
        var body = Data("top=".utf8)
        body.append(singleQuoted(topLevel))
        let command =
            "\nsec \(Cap.status) \(SectionName.untracked) "
            + "g -C \"$top\" status --porcelain=v2 -z --untracked-files=all -- "
        body.append(Data(command.utf8))
        body.append(singleQuoted(directory))
        body.append(Data("\n".utf8))
        return script(nonce: nonce, body: body)
    }

    /// Parses one listing. Omitting `displayLimit` uses the list's ceiling;
    /// tests pass a small one. Throws `ChangesReadError`: `.incomplete` when
    /// the framed status or the final marker is missing. A failed status is
    /// classified like a Changes read, so a missing top level is
    /// `.directoryMissing`, and `.gitFailed` carries git's first line only
    /// for an unclassified failure. A status cut short is kept.
    static func parseUntrackedDirectory(
        stdout: Data,
        stderr: Data,
        nonce: String,
        directory: Data,
        displayLimit: Int = CheckoutChanges.displayLimit,
        cap: Int = Cap.status
    ) throws -> UntrackedDirectoryListing {
        let frames = Frames(stdout: stdout, stderr: stderr, nonce: nonce)
        guard frames.reachedEnd else { throw ChangesReadError.incomplete }
        let section = try frames.requiredSection(SectionName.untracked, cap: cap)
        // A cut status can end on SIGPIPE; the kept records are still valid.
        guard section.status == 0 || section.isTruncated else { throw failure(section) }

        var records = section.body.split(separator: 0, omittingEmptySubsequences: false)
        // Complete output ends in NUL, leaving an empty final element; a cut
        // one ends inside its last record.
        if !records.isEmpty { records.removeLast() }
        var isSeparateRepository = false
        var paths: [Data] = []
        var index = records.startIndex
        while index < records.endIndex {
            let record = Data(records[index])
            index += 1
            // A rename or copy is two NUL fields (`2 … path`, then origPath).
            // The original path is not a record: `? dir/original` would
            // otherwise become the untracked file `dir/original`.
            if record.first == UInt8(ascii: "2") {
                if index < records.endIndex { index += 1 }
                continue
            }
            guard let path = untrackedPath(record) else { continue }
            // Git prints the directory itself when it is a nested repository.
            if path == directory {
                isSeparateRepository = true
                continue
            }
            paths.append(path)
        }
        paths.sort { $0.lexicographicallyPrecedes($1) }
        let shown = displayLimit > 0 ? Array(paths.prefix(displayLimit)) : []
        return UntrackedDirectoryListing(
            directory: directory,
            entries: shown.map {
                ChangedFile(path: $0, originalPath: nil, kind: .untracked, staging: nil)
            },
            total: paths.count,
            isTruncated: section.isTruncated,
            isSeparateRepository: isSeparateRepository,
            limitNotice: CheckoutChanges.limitNotice(
                shown: shown.count, total: paths.count,
                isLowerBound: section.isTruncated, noun: .files))
    }

    /// `? <path>`. Tracked rows, headers and ignored records are not entries.
    private static func untrackedPath(_ record: Data) -> Data? {
        guard
            record.count >= 3,
            record[record.startIndex] == UInt8(ascii: "?"),
            record[record.startIndex + 1] == UInt8(ascii: " ")
        else { return nil }
        let path = record.dropFirst(2)
        guard !path.isEmpty else { return nil }
        return Data(path)
    }
}
