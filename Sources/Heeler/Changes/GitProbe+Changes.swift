import Foundation

/// The Changes read: one exec per refresh that probes git's version,
/// resolves the Checkout from the Agent's directory, lists its status, counts
/// lines against HEAD (or the empty tree while HEAD is unborn) and reads the
/// latest commit.
extension GitProbe {
    enum SectionName {
        static let version = "version"
        static let home = "home"
        static let discover = "discover"
        static let status = "status"
        static let numstat = "numstat"
        static let head = "head"
    }

    /// The only path in the script is `directory`, single-quoted. Everything
    /// after discovery runs from the resolved top level, so status paths are
    /// relative to it whatever the Agent's subdirectory.
    static func changesScript(directory: String, nonce: String) -> Data {
        var body = Data(
            """
            sec \(Cap.version) \(SectionName.version) git --version
            sec \(Cap.home) \(SectionName.home) printf '%s' "$HOME"
            dir=
            """.utf8)
        body.append(singleQuoted(Data(directory.utf8)))
        body.append(
            Data(
                """

                sec \(Cap.discover) \(SectionName.discover) g -C "$dir" rev-parse --show-toplevel --show-prefix --absolute-git-dir --git-common-dir
                top=$(g -C "$dir" rev-parse --show-toplevel 2>/dev/null)
                if [ -n "$top" ]; then
                  sec \(Cap.status) \(SectionName.status) g -C "$top" status --porcelain=v2 -z --branch --untracked-files=normal
                  b=$(base "$top")
                  sec \(Cap.numstat) \(SectionName.numstat) g -C "$top" diff "$b" --numstat -z --no-ext-diff --no-textconv --find-renames --submodule=short --
                  sec \(Cap.head) \(SectionName.head) latest "$top"
                fi

                """.utf8))
        return script(nonce: nonce, body: body)
    }

    /// Parses one Changes read. Throws `ChangesReadError`: `.incomplete`
    /// when any framed status or the final marker is missing,
    /// `.notAGitWorkingTree` when git finds no working tree, and
    /// `.gitFailed` with git's first error line otherwise.
    static func parseChanges(
        stdout: Data, stderr: Data, nonce: String, statusCap: Int = Cap.status
    ) throws -> CheckoutChangesRead {
        let frames = Frames(stdout: stdout, stderr: stderr, nonce: nonce)
        guard frames.reachedEnd else { throw ChangesReadError.incomplete }
        try validateChangesFraming(frames)

        let version = try frames.requiredSection(SectionName.version, cap: Cap.version)
        try requireUsableGit(version)
        let home = try frames.requiredSection(SectionName.home, cap: Cap.home)
        guard home.status == 0 else { throw failure(home) }
        guard !home.isTruncated else { throw ChangesReadError.incomplete }

        let discover = try frames.requiredSection(SectionName.discover, cap: Cap.discover)
        guard discover.status == 0 else {
            throw classifyDiscoveryFailure(discover)
        }
        guard !discover.isTruncated else { throw ChangesReadError.incomplete }
        // The script lists status only once git reports a top level. Git
        // older than 2.25 answers inside a git directory with an empty top
        // level and a zero status, which lands here too.
        guard !discover.body.isEmpty, discover.body.first != 0x0A else {
            throw ChangesReadError.notAGitWorkingTree
        }
        let status = try frames.requiredSection(SectionName.status, cap: statusCap)
        let lines = discover.body.split(separator: 0x0A, omittingEmptySubsequences: false)
        // Four newline-terminated lines. A top level containing a newline
        // cannot be split by line and is not supported.
        guard lines.count == 5, lines[4].isEmpty, !lines[0].isEmpty else {
            throw ChangesReadError.gitFailed(
                String(localized: "The Checkout's path contains a line break, which Changes can't read."))
        }
        let topLevel = Data(lines[0])
        let prefix = Data(lines[1])
        let gitDirectory = Data(lines[2])
        let commonDirectory = Data(lines[3])

        // A cut status can end on SIGPIPE; the kept records are still valid.
        guard status.status == 0 || status.isTruncated else { throw failure(status) }
        // Counts require a framed status too, even when git cannot compute them.
        let numstat = parseNumstat(try frames.requiredSection(SectionName.numstat, cap: Cap.numstat))
        let head = try frames.requiredSection(SectionName.head, cap: Cap.head)

        let report = parseStatus(status.body)
        let checkout = CheckoutLocation(
            topLevel: topLevel,
            isLinkedWorktree: isLinkedWorktree(
                gitDirectory: gitDirectory, commonDirectory: commonDirectory),
            displayPath: displayPath(topLevel, home: home.body))
        var changes = CheckoutChanges(
            checkout: checkout,
            head: CheckoutHead(
                branch: report.branch,
                commit: report.commit,
                latestCommit: head.status == 0 ? parseLatestCommit(head.body) : nil,
                upstream: report.upstream,
                isUnborn: report.isUnborn),
            files: countedFiles(report.files, numstat: numstat),
            totals: changesTotals(report.files, numstat: numstat),
            isStatusTruncated: status.isTruncated)
        changes.isMetadataTruncated = try validateChangesMetadata(frames)
        return CheckoutChangesRead(changes: changes, directoryPrefix: prefix)
    }

    /// Classified from the command's framed stderr under the C locale.
    static func classifyDiscoveryFailure(_ section: Section) -> ChangesReadError {
        failure(section)
    }

    static func failure(_ section: Section) -> ChangesReadError {
        classifyCommandFailure(section)
    }

    /// A linked Worktree's common directory is absolute and differs from its
    /// own git directory. A main checkout reports a relative common
    /// directory, and a submodule reports the same absolute path for both.
    static func isLinkedWorktree(gitDirectory: Data, commonDirectory: Data) -> Bool {
        commonDirectory.first == UInt8(ascii: "/") && commonDirectory != gitDirectory
    }

    static func displayPath(_ topLevel: Data, home: Data) -> String {
        var home = home
        while home.count > 1, home.last == UInt8(ascii: "/") { home.removeLast() }
        guard home.count > 1, home.first == UInt8(ascii: "/") else {
            return ChangedFile.displayText(topLevel)
        }
        if topLevel == home { return "~" }
        var homePrefix = home
        homePrefix.append(UInt8(ascii: "/"))
        guard topLevel.starts(with: homePrefix) else {
            return ChangedFile.displayText(topLevel)
        }
        return "~/" + ChangedFile.displayText(topLevel.dropFirst(homePrefix.count))
    }

    /// `<committer epoch> <subject>`; nil when HEAD is unborn (no output).
    static func parseLatestCommit(_ body: Data) -> LatestCommit? {
        var line = body
        if line.last == 0x0A { line.removeLast() }
        guard let space = line.firstIndex(of: UInt8(ascii: " ")),
            let seconds = TimeInterval(
                String(decoding: line[line.startIndex..<space], as: UTF8.self))
        else { return nil }
        return LatestCommit(
            subject: ChangedFile.displayText(line[line.index(after: space)...]),
            committedAt: Date(timeIntervalSince1970: seconds))
    }
}
