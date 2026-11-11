import Foundation
import Testing

@testable import Heeler

/// Where a core Host's Worktree goes and the git commands that make and remove
/// it: the same as the Herdr desktop app's worktree mod at v0.1.9, so both
/// clients share one checkout (ADR 0032).
struct HerdrCoreWorktreeBuilderTests {
    @Test(arguments: [
        ("main", "main"),
        ("feature/login", "feature-login"),
        ("a/b/c", "a-b-c"),
        ("Fix_1.2-rc", "Fix_1.2-rc"),
    ])
    func anOrdinaryOrNestedBranchKeepsItsCharactersAndLosesItsSlashes(branch: String, slug: String) {
        #expect(HerdrCoreWorktrees.slug(branch) == slug)
    }

    /// Worked out by hand against the mod's two replacements: each run of other
    /// characters becomes one `-`, and `-` at either end goes.
    @Test(arguments: [
        ("a;b'c", "a-b-c"),
        ("$(id)", "id"),
        ("`id`", "id"),
        ("x&&y||z", "x-y-z"),
        ("功能/登录", ""),
        ("功能/x", "x"),
        ("x/功能", "x"),
        ("a@@b", "a-b"),
        ("--a", "a"),
        ("a--b", "a--b"),
    ])
    func aHostileBranchBecomesOneHarmlessFolderName(branch: String, slug: String) {
        #expect(HerdrCoreWorktrees.slug(branch) == slug)
    }

    @Test func theCheckoutGoesUnderTheHomeByRepositoryAndSlug() {
        #expect(
            HerdrCoreWorktrees.checkoutPath(
                home: "/home/dev", mainCheckout: "/work/my app", branch: "feature/login")
                == "/home/dev/.herdr/worktrees/my app/feature-login")
        #expect(
            HerdrCoreWorktrees.checkoutPath(
                home: "/home/dev", mainCheckout: "/srv/bare.git", branch: "x")
                == "/home/dev/.herdr/worktrees/bare.git/x")
    }

    /// tmux Hosts share the slug and the folder layout, under `~/.heeler` (ADR 0043).
    @Test func aTmuxCheckoutGoesUnderHeelerWhileTheDefaultStaysUnderHerdr() {
        #expect(
            HerdrCoreWorktrees.checkoutPath(
                home: "/home/dev", mainCheckout: "/work/my app", branch: "feature/login",
                root: ".heeler")
                == "/home/dev/.heeler/worktrees/my app/feature-login")
        #expect(
            HerdrCoreWorktrees.checkoutPath(
                home: "/home/dev", mainCheckout: "/work/app", branch: "功.功", root: ".heeler")
                == nil)
    }

    /// `功.功` is a branch git takes, and its slug would be the repository's folder.
    @Test(arguments: ["功能", "功.功", "功..功", "/"])
    func aBranchWithNoUsableFolderNameHasNoCheckout(branch: String) {
        #expect(
            HerdrCoreWorktrees.checkoutPath(
                home: "/home/dev", mainCheckout: "/work/app", branch: branch) == nil)
    }

    @Test func aBranchThatExistsIsCheckedOutAndANewOneStartsFromHead() {
        let path = "/home/dev/.herdr/worktrees/app/feature-login"
        #expect(
            HerdrCoreWorktrees.addArguments(path: path, branch: "feature/login", branchExists: true)
                == ["worktree", "add", path, "feature/login"])
        #expect(
            HerdrCoreWorktrees.addArguments(path: path, branch: "feature/login", branchExists: false)
                == ["worktree", "add", "-b", "feature/login", path, "HEAD"])
    }

    @Test func removalForcesOnlyWhenAskedAndNamesNoBranch() {
        #expect(
            HerdrCoreWorktrees.removeArguments(path: "/wt", force: false)
                == ["worktree", "remove", "/wt"])
        #expect(
            HerdrCoreWorktrees.removeArguments(path: "/wt", force: true)
                == ["worktree", "remove", "--force", "/wt"])
    }

    @Test func aListingReadsEachCheckoutMainFirst() {
        let porcelain = """
            worktree /work/app
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /home/dev/.herdr/worktrees/app/feature-login
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/feature/login

            worktree /home/dev/.herdr/worktrees/app/loose
            HEAD 3333333333333333333333333333333333333333
            detached

            worktree /gone
            HEAD 4444444444444444444444444444444444444444
            branch refs/heads/gone
            prunable gitdir file points to non-existent location

            """

        let entries = HerdrCoreWorktrees.parseList(porcelain)

        #expect(entries.map(\.path) == [
            "/work/app", "/home/dev/.herdr/worktrees/app/feature-login",
            "/home/dev/.herdr/worktrees/app/loose", "/gone",
        ])
        #expect(entries.map(\.branch) == ["main", "feature/login", nil, "gone"])
        #expect(entries.map(\.isLinkedWorktree) == [false, true, true, true])
        #expect(entries.map(\.isDetached) == [false, false, true, false])
        #expect(entries.map(\.isPrunable) == [false, false, false, true])
    }
}

/// The command script: every word quoted, git's answer framed, and a mutation run
/// as the user's own git would run it.
struct GitCommandScriptTests {
    private let nonce = "0123456789abcdef0123456789abcdef"

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func framed(_ body: String, status: Int32, message: String = "") -> (Data, Data) {
        let marker = GitProbe.marker(nonce: nonce)
        let name = GitProbe.commandSection
        return (
            Data("\n\(marker) \(name) begin\n\(body)\n\(marker) \(name) rc=\(status)\n\n\(marker) done\n".utf8),
            Data("\n\(marker) \(name) begin\n\(message)\n\(marker) \(name) end\n".utf8)
        )
    }

    @Test func everyWordIsQuotedSoNoneReachesTheShell() {
        let script = text(
            GitProbe.commandScript(
                GitCommand(
                    arguments: ["worktree", "add", "-b", "a'b$(id)", "/home/it's", "HEAD"],
                    directory: "/work/it's", isMutation: true),
                nonce: nonce))

        #expect(script.contains(#"dir='/work/it'\''s'"#))
        #expect(script.contains(#"'worktree' 'add' '-b' 'a'\''b$(id)' '/home/it'\''s' 'HEAD'"#))
    }

    @Test func aMutationRunsPlainGitAndAReadRunsTheNeutralizedOne() {
        let mutation = text(
            GitProbe.commandScript(
                GitCommand(arguments: ["worktree", "prune"], directory: "/w", isMutation: true),
                nonce: nonce))
        let read = text(
            GitProbe.commandScript(
                GitCommand(arguments: ["status"], directory: "/w", isMutation: false), nonce: nonce))

        #expect(mutation.contains(#" git -C "$dir" 'worktree' 'prune'"#))
        #expect(read.contains(#" g -C "$dir" 'status'"#))
    }

    @Test func theAnswerCarriesGitsStatusOutputAndFirstError() throws {
        let (stdout, stderr) = framed("out", status: 128, message: "fatal: nope\nmore")

        let result = try GitProbe.parseCommand(stdout: stdout, stderr: stderr, nonce: nonce)

        #expect(result == GitCommandResult(status: 128, output: "out", message: "fatal: nope"))
    }

    @Test func aScriptThatDidNotRunToItsEndIsIncomplete() {
        #expect(throws: ChangesReadError.incomplete) {
            _ = try GitProbe.parseCommand(
                stdout: Data("nothing framed".utf8), stderr: Data(), nonce: nonce)
        }
    }
}
