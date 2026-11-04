import Foundation

/// The files an OpenCode call changed, from its metadata.
///
/// OpenCode 2.0's file tools record `files[]`, each with its status, its
/// counts and a unified patch that `createTwoFilesPatch` writes under an
/// `Index:` line and a rule. Older rows record one file's patch in `diff`,
/// with its counts in `filediff`. The record source cuts each patch at
/// 64 Ki characters, so the recorded counts stand over the lines a cut
/// patch still holds.
enum OpenCodeFileChanges {
    /// Nil when the metadata records no change a row can show. `callPath`
    /// names the file an older patch changed when `filediff` does not.
    static func changes(_ metadata: OpenCodeToolMetadata?, callPath: String?) -> ChatFileChanges? {
        guard let metadata else { return nil }
        var changes = ChatFileChanges(files: [])
        if !metadata.files.isEmpty {
            for diff in metadata.files {
                guard let path = diff.file, !path.isEmpty else { continue }
                if changes.files.count < ChatFileChanges.maximumFiles {
                    changes.files.append(file(path: path, kind: kind(diff.status), diff: diff, patch: diff.patch))
                } else {
                    changes.moreFiles += 1
                }
            }
        } else if metadata.diff != nil || metadata.filediff != nil,
            let path = metadata.filediff?.file ?? callPath, !path.isEmpty
        {
            changes.files = [file(path: path, kind: .updated, diff: metadata.filediff, patch: metadata.diff)]
        }
        return changes.files.isEmpty && changes.moreFiles == 0 ? nil : changes
    }

    /// One file: the hunks its patch holds, with the counts OpenCode
    /// recorded when it recorded them.
    private static func file(
        path: String, kind: ChatFileChange.Kind, diff: OpenCodeToolMetadata.FileDiff?, patch: String?
    ) -> ChatFileChange {
        var file =
            patch.flatMap { PiFileChanges.unifiedFile(unifiedPatch($0), path: path) }
            ?? ChatFileChange(path: path, kind: kind, added: 0, removed: 0, lineCount: 0)
        file.kind = kind
        if let additions = diff?.additions { file.added = additions }
        if let deletions = diff?.deletions { file.removed = deletions }
        return file
    }

    /// The patch from its `--- ` header on, without the `Index:` line and
    /// the rule above it.
    private static func unifiedPatch(_ patch: String) -> String {
        guard !patch.hasPrefix("--- "), let header = patch.range(of: "\n--- ") else { return patch }
        return String(patch[patch.index(after: header.lowerBound)...])
    }

    /// 2.0 says `added`, `deleted` or `modified`; older rows `add`,
    /// `delete` or `update`.
    private static func kind(_ status: String?) -> ChatFileChange.Kind {
        switch status {
        case "added", "add", "create", "created": .created
        case "deleted", "delete": .deleted
        default: .updated
        }
    }
}
