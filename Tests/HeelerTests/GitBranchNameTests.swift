import Testing

@testable import Heeler

/// Client-side branch validation for the new-worktree launch (#97): a
/// `git check-ref-format --branch` subset, so the form can give decent copy
/// before herdr collapses the failure into raw git stderr.
@Suite("Git branch name")
struct GitBranchNameTests {
    @Test func acceptsOrdinaryBranchNames() {
        for name in [
            "main", "feature/start-worktree", "worktree/calm-field-cc11",
            "fix-97", "user/deep/nested/branch", "v1.2.3", "UPPER_case-mix",
        ] {
            #expect(GitBranchName.validationError(name) == nil, "\(name)")
        }
    }

    @Test func rejectsForbiddenCharacters() {
        for name in [
            "has space", "tab\there", "control\u{01}char",
            "tilde~1", "caret^2", "colon:ref", "question?", "star*", "bracket[",
            #"back\slash"#,
        ] {
            #expect(GitBranchName.validationError(name) != nil, "\(name)")
        }
    }

    @Test func rejectsForbiddenSequences() {
        for name in ["double..dot", "at@{brace", "@"] {
            #expect(GitBranchName.validationError(name) != nil, "\(name)")
        }
        // A lone "@" elsewhere is fine.
        #expect(GitBranchName.validationError("release@2024") == nil)
    }

    @Test func rejectsBadSlashPlacement() {
        for name in ["/leading", "trailing/", "double//slash"] {
            #expect(GitBranchName.validationError(name) != nil, "\(name)")
        }
    }

    @Test func rejectsBadComponentEdges() {
        for name in [
            ".hidden", "dir/.hidden", "ends.lock", "dir/ends.lock/more",
            "trailing.", "-leading-dash",
        ] {
            #expect(GitBranchName.validationError(name) != nil, "\(name)")
        }
        // Dots inside a component are fine; ".lock" inside one too.
        #expect(GitBranchName.validationError("v1.2") == nil)
        #expect(GitBranchName.validationError("has.lockfile") == nil)
    }

    @Test func rejectsEmpty() {
        #expect(GitBranchName.validationError("") != nil)
    }
}
