import Foundation

/// Client-side branch validation for the new-worktree launch (#97): the
/// `git check-ref-format --branch` rules that matter for a hand-typed branch
/// name. herdr collapses every `worktree.create` failure besides
/// `not_git_worktree` into one code carrying raw git stderr, so validating
/// here is the only way to give decent copy; server message passthrough
/// remains the fallback for anything this subset misses.
enum GitBranchName {
    /// Nil when `name` is an acceptable branch name; otherwise a user-facing
    /// message naming the violated rule.
    static func validationError(_ name: String) -> String? {
        if name.isEmpty || name == "@" {
            return "Enter a branch name."
        }
        if name.hasPrefix("-") {
            return "Branch names cannot start with \"-\"."
        }
        if name.contains(where: isForbiddenScalar) {
            return "Branch names cannot contain spaces, control characters, "
                + "or any of ~ ^ : ? * [ \\."
        }
        if name.contains("..") || name.contains("@{") {
            return "Branch names cannot contain \"..\" or \"@{\"."
        }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.contains("//") {
            return "Branch names cannot start or end with \"/\" or contain \"//\"."
        }
        if name.hasSuffix(".") {
            return "Branch names cannot end with \".\"."
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) {
            return "Branch name components cannot start with \".\" or end with \".lock\"."
        }
        return nil
    }

    private static func isForbiddenScalar(_ character: Character) -> Bool {
        if "~^:?*[\\ ".contains(character) { return true }
        return character.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}
