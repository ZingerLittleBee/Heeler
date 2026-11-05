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

/// A native Windows Host's read of the same, through PowerShell, since the script
/// above needs a POSIX shell. It asks only for the top level, which names a space:
/// which repository a Checkout belongs to is for Worktrees, off there (ADR 0032).
/// Nothing here has run on a Windows machine. See `docs/agents/herdr-compatibility.md`.
extension GitProbe {
    /// What `cmd.exe` takes, and OpenSSH starts an exec through the account's shell.
    private static let windowsCommandLimit = 8_191

    /// Each directory is entered, not handed to `-C`: Windows PowerShell 5.1 ends a
    /// quoted native argument early at a trailing backslash. A directory it cannot
    /// enter stays unanswered rather than asking about wherever this already is.
    /// PowerShell finds `git` on PATH and never in the folder it just entered.
    static func windowsCheckoutRootsCommand(directories: [String], nonce: String) -> String {
        let options = neutralizingOptions.map(PowerShellCommand.literal).joined(separator: " ")
        let list = directories.map(PowerShellCommand.literal).joined(separator: "\n")
        return PowerShellCommand.encoded(
            """
            \(HerdrCoreLocator.windowsPrelude)
            say ''
            say \(PowerShellCommand.literal("\(nonce) begin"))
            Remove-Item Env:GIT_DIR, Env:GIT_WORK_TREE, Env:GIT_COMMON_DIR
            $env:GIT_TERMINAL_PROMPT = '0'
            $dirs = @(
            \(list)
            )
            for ($i = 0; $i -lt $dirs.Count; $i++) {
                try { Set-Location -LiteralPath $dirs[$i] -ErrorAction Stop } catch { continue }
                $global:LASTEXITCODE = 1
                $r = git \(options) rev-parse --show-toplevel 2>$null
                if ($LASTEXITCODE -eq 0 -and $r) { say ("root $i " + $r) }
            }
            say \(PowerShellCommand.literal("\(nonce) end"))
            exit 0
            """)
    }

    /// The commands one call takes, in the order asked: long paths can fill one
    /// long before `checkoutRootsPerCall` does. A path no command can carry has no
    /// entry, so it names itself.
    static func windowsCheckoutRootBatches(_ directories: [String], nonce: String) -> [[String]] {
        func fits(_ batch: [String]) -> Bool {
            windowsCheckoutRootsCommand(directories: batch, nonce: nonce).count <= windowsCommandLimit
        }
        var batches: [[String]] = []
        var batch: [String] = []
        for directory in checkoutRootDirectories(directories) where fits([directory]) {
            if fits(batch + [directory]) {
                batch.append(directory)
            } else {
                batches.append(batch)
                batch = [directory]
            }
        }
        return batch.isEmpty ? batches : batches + [batch]
    }

    /// Throws `ChangesReadError.incomplete` unless this read's own end marker came.
    /// Git for Windows prints `/`, and a Host's paths compare with its own `\\`.
    static func parseWindowsCheckoutRoots(
        stdout: Data, nonce: String, directories: [String]
    ) throws -> [String: HostCheckout] {
        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard let begin = lines.firstIndex(of: "\(nonce) begin"),
            let end = lines[begin...].firstIndex(of: "\(nonce) end")
        else { throw ChangesReadError.incomplete }
        var checkouts: [String: HostCheckout] = [:]
        for line in lines[begin..<end] {
            let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3, fields[0] == "root", let index = Int(fields[1]),
                directories.indices.contains(index)
            else { continue }
            checkouts[directories[index]] = HostCheckout(
                root: fields[2].replacingOccurrences(of: "/", with: "\\"))
        }
        return checkouts
    }
}
