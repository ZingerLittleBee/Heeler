import Foundation
import Testing

@testable import Heeler

/// The checkout-root script and the bytes it gets back. Nothing here runs a
/// shell; `HerdrCoreTransportE2ETests` runs it on a real Host.
@Suite("GitProbe checkout roots")
struct GitProbeCheckoutRootsTests {
    private let nonce = GitProbeRecordings.nonce

    private func text(_ script: Data) -> String {
        String(decoding: script, as: UTF8.self)
    }

    /// Each section's body and status, framed as the script frames them.
    private func framed(_ sections: [(body: Data, status: Int)], reachesEnd: Bool = true) -> Data {
        let marker = GitProbe.marker(nonce: nonce)
        var stdout = Data()
        for (index, section) in sections.enumerated() {
            stdout.append(Data("\n\(marker) root\(index) begin\n".utf8))
            stdout.append(section.body)
            stdout.append(Data("\n\(marker) root\(index) rc=\(section.status)\n".utf8))
        }
        if reachesEnd { stdout.append(Data("\n\(marker) done\n".utf8)) }
        return stdout
    }

    @Test func aDirectoryIsOneQuotedWordWhateverItHolds() {
        let awkward = "/work/it's $(touch x) `id`\n; rm -rf \"home\""
        let script = text(GitProbe.checkoutRootsScript(directories: [awkward], nonce: nonce))

        #expect(script.contains("dir='/work/it'\\''s $(touch x) `id`\n; rm -rf \"home\"'\n"))
        #expect(script.contains("g -C \"$dir\" rev-parse --show-toplevel"))
    }

    @Test func oneCallAsksAboutACappedNumberOfDirectoriesOnce() {
        let directories = (0..<40).map { "/work/\($0)" } + ["/work/0"]
        let asked = GitProbe.checkoutRootDirectories(directories)
        let script = text(GitProbe.checkoutRootsScript(directories: directories, nonce: nonce))

        #expect(asked == (0..<16).map { "/work/\($0)" })
        #expect(script.components(separatedBy: "rev-parse --show-toplevel").count == 17)
        #expect(!script.contains("/work/16"))
    }

    @Test func anEmptyDirectoryOrANulIsNeverAPath() {
        #expect(GitProbe.checkoutRootDirectories(["", "/a\u{0}b", "/work"]) == ["/work"])
    }

    @Test func eachDirectoryGetsItsOwnTopLevel() throws {
        let directories = ["/work/repo/src", "/work/plain", "/work/odd", "/work/slash"]
        let stdout = framed([
            (Data("/work/repo\n".utf8), 0),
            // Not a checkout: git says so on stderr and exits 128.
            (Data(), 128),
            // A top level holding a newline keeps it, and loses only git's own.
            (Data("/work/od\nd\n".utf8), 0),
            // Git older than 2.25 inside a git directory: empty, and zero.
            (Data("\n".utf8), 0),
        ])

        let roots = try GitProbe.parseCheckoutRoots(
            stdout: stdout, stderr: Data(), nonce: nonce, directories: directories)

        #expect(roots.mapValues(\.root) == ["/work/repo/src": "/work/repo", "/work/odd": "/work/od\nd"])
    }

    @Test func aRepositoryAnswerNamesTheMainCheckoutAndALinkedWorktree() throws {
        let marker = GitProbe.marker(nonce: nonce)
        func section(_ name: String, _ body: String, status: Int = 0) -> String {
            "\n\(marker) \(name) begin\n\(body)\n\(marker) \(name) rc=\(status)\n"
        }
        let stdout =
            section("root0", "/work/app\n") + section("repo0", "main /work/app/.git\n")
            + section("root1", "/home/dev/.herdr/worktrees/app/x\n")
            + section("repo1", "linked /work/app/.git\n")
            // A submodule's common directory holds no `.git` at its end.
            + section("root2", "/work/app/sub\n")
            + section("repo2", "main /work/app/.git/modules/sub\n")
            // Git said where the top level is and then would not say more.
            + section("root3", "/work/odd\n") + section("repo3", "", status: 128)
            + "\n\(marker) done\n"

        let checkouts = try GitProbe.parseCheckoutRoots(
            stdout: Data(stdout.utf8), stderr: Data(), nonce: nonce,
            directories: ["/work/app", "/home/dev/.herdr/worktrees/app/x", "/work/app/sub", "/work/odd"])

        #expect(checkouts["/work/app"] == HostCheckout(root: "/work/app", mainCheckout: "/work/app"))
        #expect(
            checkouts["/home/dev/.herdr/worktrees/app/x"]
                == HostCheckout(
                    root: "/home/dev/.herdr/worktrees/app/x", mainCheckout: "/work/app",
                    isLinkedWorktree: true))
        #expect(
            checkouts["/work/app/sub"]
                == HostCheckout(root: "/work/app/sub", mainCheckout: "/work/app/.git/modules/sub"))
        #expect(checkouts["/work/odd"] == HostCheckout(root: "/work/odd"))
    }

    @Test func aTopLevelCutShortIsNoAnswer() throws {
        let long = Data(repeating: UInt8(ascii: "a"), count: GitProbe.Cap.checkoutRoot + 1)
        let roots = try GitProbe.parseCheckoutRoots(
            stdout: framed([(long, 0)]), stderr: Data(), nonce: nonce, directories: ["/work"])

        #expect(roots.isEmpty)
    }

    @Test func aScriptThatDidNotRunToItsEndIsIncomplete() {
        #expect(throws: ChangesReadError.incomplete) {
            _ = try GitProbe.parseCheckoutRoots(
                stdout: framed([(Data("/work\n".utf8), 0)], reachesEnd: false), stderr: Data(),
                nonce: nonce, directories: ["/work"])
        }
        #expect(throws: ChangesReadError.incomplete) {
            _ = try GitProbe.parseCheckoutRoots(
                stdout: framed([(Data("/work\n".utf8), 0)]), stderr: Data(),
                nonce: nonce, directories: ["/work", "/never/framed"])
        }
    }

    @Test func outputFromAnotherNonceIsNoAnswer() {
        #expect(throws: ChangesReadError.incomplete) {
            _ = try GitProbe.parseCheckoutRoots(
                stdout: framed([(Data("/work\n".utf8), 0)]), stderr: Data(),
                nonce: "someoneelse", directories: ["/work"])
        }
    }
}
