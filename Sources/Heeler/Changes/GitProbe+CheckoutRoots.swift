import Foundation

extension GitProbe.Cap {
    /// One directory's top level: well past any platform's longest path.
    static let checkoutRoot = 8_192
}

/// The Checkout a directory is in, as git says.
struct HostCheckout: Equatable, Sendable {
    /// The Checkout's top level.
    let root: String
    /// The repository's main checkout, nil when git did not say. A bare
    /// repository's own folder stands in for one, as in the desktop app.
    var mainCheckout: String?
    var isLinkedWorktree = false
}

/// The Checkout of each directory, in one script: what names a Herdr desktop
/// space nobody named and tells a linked Worktree from a main checkout (ADR
/// 0032). The call is capped so one exec stays short whatever a core's Terminals
/// hold, and a directory git has no answer for has no entry, as outside a
/// checkout it names itself.
extension GitProbe {
    static let checkoutRootsPerCall = 16

    /// The directories one call asks about. No path is empty or holds a NUL,
    /// and either would mean something else to the script.
    static func checkoutRootDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        let askable = directories.filter { directory in
            !directory.isEmpty && !directory.utf8.contains(0) && seen.insert(directory).inserted
        }
        return Array(askable.prefix(checkoutRootsPerCall))
    }

    private static func checkoutRootSection(_ index: Int) -> String {
        "root\(index)"
    }

    private static func repositorySection(_ index: Int) -> String {
        "repo\(index)"
    }

    /// A linked Worktree's git directory is its own, inside the common one. A
    /// submodule's common directory is not named `.git` either, and it is no
    /// Worktree. Both are resolved here because git prints relative paths, and
    /// `--path-format` is newer than the git this app takes.
    private static let repositoryFunction = """
        repository() (
          unset CDPATH
          cd -- "$1" || exit
          c=$(g rev-parse --git-common-dir) && d=$(g rev-parse --git-dir) || exit
          c=$(cd -- "$c" && pwd -P) && d=$(cd -- "$d" && pwd -P) || exit
          if [ "$c" = "$d" ]; then printf 'main %s\\n' "$c"; else printf 'linked %s\\n' "$c"; fi
        )

        """

    /// Each path is single-quoted and goes to `-C` as one word, whatever it holds.
    static func checkoutRootsScript(directories: [String], nonce: String) -> Data {
        var body = Data(repositoryFunction.utf8)
        for (index, directory) in checkoutRootDirectories(directories).enumerated() {
            body.append(Data("dir=".utf8))
            body.append(singleQuoted(Data(directory.utf8)))
            let section = checkoutRootSection(index)
            let repository = repositorySection(index)
            let command = """

                sec \(Cap.checkoutRoot) \(section) g -C "$dir" rev-parse --show-toplevel
                sec \(Cap.checkoutRoot + repositoryWordLength) \(repository) repository "$dir"

                """
            body.append(Data(command.utf8))
        }
        return script(nonce: nonce, body: body)
    }

    /// `linked `, the longer word `repository` starts its line with.
    private static let repositoryWordLength = 7

    /// Throws `ChangesReadError.incomplete` when the script did not run to its
    /// end. One directory's failure is that directory's alone.
    static func parseCheckoutRoots(
        stdout: Data, stderr: Data, nonce: String, directories: [String]
    ) throws -> [String: HostCheckout] {
        let frames = Frames(stdout: stdout, stderr: stderr, nonce: nonce)
        guard frames.reachedEnd else { throw ChangesReadError.incomplete }
        var checkouts: [String: HostCheckout] = [:]
        for (index, directory) in checkoutRootDirectories(directories).enumerated() {
            let section = try frames.requiredSection(
                checkoutRootSection(index), cap: Cap.checkoutRoot)
            guard section.status == 0, !section.isTruncated else { continue }
            var body = section.body
            if body.last == 0x0A { body.removeLast() }
            guard !body.isEmpty else { continue }
            var checkout = HostCheckout(root: String(decoding: body, as: UTF8.self))
            if let repository = try frames.section(
                repositorySection(index), cap: Cap.checkoutRoot + repositoryWordLength),
                repository.status == 0, !repository.isTruncated
            {
                let line = String(decoding: repository.body, as: UTF8.self)
                if line.hasPrefix("main ") {
                    checkout.mainCheckout = mainCheckout(ofCommonDirectory: line.dropFirst(5))
                } else if line.hasPrefix("linked ") {
                    checkout.mainCheckout = mainCheckout(ofCommonDirectory: line.dropFirst(7))
                    checkout.isLinkedWorktree = true
                }
            }
            checkouts[directory] = checkout
        }
        return checkouts
    }

    private static func mainCheckout(ofCommonDirectory line: Substring) -> String {
        let path = line.hasSuffix("\n") ? line.dropLast() : line
        return String(path.hasSuffix("/.git") ? path.dropLast(5) : path)
    }
}
