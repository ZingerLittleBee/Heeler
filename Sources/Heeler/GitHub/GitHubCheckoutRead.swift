import Foundation

/// One directory as git sees it: the checkout it is in, its branch and
/// where its remotes point.
struct GitHubCheckout: Sendable, Equatable {
    struct Remote: Sendable, Equatable {
        let name: String
        let url: String
    }

    /// One of the repository's Worktrees, its main checkout among them.
    struct Worktree: Sendable, Equatable {
        let path: String
        /// Nil on a detached HEAD.
        let branch: String?
    }

    let topLevel: String
    /// Nil on a detached HEAD.
    let branch: String?
    /// Every remote's name and URL, as git has them.
    let remotes: [Remote]
    /// Every Worktree of the repository, as `git worktree list` has them:
    /// git checks a branch out in only one of them.
    var worktrees: [Worktree] = []

    /// The first remote that points at `repository` (`owner/name`) on
    /// GitHub's `host`.
    func remote(for repository: String, host: String) -> Remote? {
        remotes.first { remote in
            GitHubRemote.repository(fromURL: remote.url, host: host)?.caseInsensitiveCompare(repository) == .orderedSame
        }
    }

    func isCheckout(of repository: String, host: String) -> Bool {
        remote(for: repository, host: host) != nil
    }
}

/// Which repository and branch the Agents' directories are checkouts of,
/// for Send to Agent (ADR 0065): one script through the gh seam, so a Rex
/// Host answers too. git only, read-only, and nothing about the account.
enum GitHubCheckoutRead {
    /// The most directories one read asks about.
    static let directoryLimit = 24
    static let cap = 4_096

    private static let commands = [
        ("top", "rev-parse --show-toplevel"),
        ("branch", "symbolic-ref -q --short HEAD"),
        ("remotes", "config --get-regexp '^remote\\..*\\.url$'"),
        ("worktrees", "worktree list --porcelain"),
    ]

    static func script(for directories: [String], nonce: String) -> Data {
        var body = Data()
        for (index, directory) in directories.prefix(directoryLimit).enumerated() {
            let quoted = GitProbe.singleQuoted(Data(directory.utf8))
            for (name, command) in commands {
                body.append(Data("sec \(cap) \(name)\(index) g -C ".utf8))
                body.append(quoted)
                body.append(Data(" \(command)\n".utf8))
            }
        }
        return GitProbe.script(nonce: nonce, body: body)
    }

    /// The checkouts among `directories`, by directory. A directory that is
    /// not in one, or that the script did not reach, is left out.
    static func checkouts(in result: GitExecResult, directories: [String], nonce: String) -> [String: GitHubCheckout] {
        let frames = GitProbe.Frames(stdout: result.stdout, stderr: result.stderr, nonce: nonce)
        var checkouts: [String: GitHubCheckout] = [:]
        for (index, directory) in directories.prefix(directoryLimit).enumerated() {
            guard let top = try? frames.section("top\(index)", cap: cap), top.status == 0,
                let topLevel = firstLine(top.body)
            else { continue }
            let branch = (try? frames.section("branch\(index)", cap: cap)).flatMap { section in
                section.status == 0 ? firstLine(section.body) : nil
            }
            let remotes = (try? frames.section("remotes\(index)", cap: cap)).map { section -> [GitHubCheckout.Remote] in
                var lines = String(decoding: section.body, as: UTF8.self).split(whereSeparator: \.isNewline)
                // A cut can end inside a URL that still parses, naming
                // another repository.
                if section.isTruncated, !lines.isEmpty { lines.removeLast() }
                return lines.compactMap(remote)
            } ?? []
            let worktrees = (try? frames.section("worktrees\(index)", cap: cap)).map { section -> [GitHubCheckout.Worktree] in
                guard section.status == 0 else { return [] }
                let worktrees = Self.worktrees(section.body)
                return section.isTruncated ? Array(worktrees.dropLast()) : worktrees
            } ?? []
            checkouts[directory] = GitHubCheckout(
                topLevel: topLevel, branch: branch, remotes: remotes, worktrees: worktrees)
        }
        return checkouts
    }

    /// `remote.<name>.url <url>`; a remote's name can hold a space, its URL
    /// rarely does.
    private static func remote(_ line: Substring) -> GitHubCheckout.Remote? {
        guard let space = line.lastIndex(of: " ") else { return nil }
        let key = line[..<space]
        let url = line[line.index(after: space)...]
        guard key.hasPrefix("remote."), key.hasSuffix(".url"), !url.isEmpty else { return nil }
        let name = key.dropFirst("remote.".count).dropLast(".url".count)
        guard !name.isEmpty else { return nil }
        return GitHubCheckout.Remote(name: String(name), url: String(url))
    }

    /// `git worktree list --porcelain`: a `worktree <path>` line opens each
    /// entry, and `branch refs/heads/<name>` names its branch.
    private static func worktrees(_ data: Data) -> [GitHubCheckout.Worktree] {
        var worktrees: [GitHubCheckout.Worktree] = []
        var path: String?
        var branch: String?
        func close() {
            if let path { worktrees.append(GitHubCheckout.Worktree(path: path, branch: branch)) }
            path = nil
            branch = nil
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                close()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.isEmpty {
                close()
            }
        }
        return worktrees
    }

    private static func firstLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

/// A git remote's URL as a GitHub repository.
enum GitHubRemote {
    /// `owner/name` when `url` points at a repository on `host` (GitHub's,
    /// `github.com`): https, scp-like `git@host:owner/name` and `ssh://`
    /// forms, with or without `.git`. Nil for any other host or shape.
    static func repository(fromURL url: String, host: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespaces)
        let authority: Substring
        let path: Substring
        if let scheme = url.range(of: "://") {
            let rest = url[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        } else {
            // scp-like: `[user@]host:path`, with no slash before the colon.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            authority = url[..<colon]
            path = url[url.index(after: colon)...]
        }
        var name = authority
        if let at = name.lastIndex(of: "@") { name = name[name.index(after: at)...] }
        if let port = name.firstIndex(of: ":") { name = name[..<port] }
        let hostName = name.lowercased()
        let host = host.lowercased()
        let hosts = host == "github.com" ? [host, "www.github.com", "ssh.github.com"] : [host, "www.\(host)"]
        guard hosts.contains(hostName) else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        var repository = parts[1]
        if repository.hasSuffix(".git") { repository = repository.dropLast(4) }
        guard !parts[0].isEmpty, !repository.isEmpty else { return nil }
        return "\(parts[0])/\(repository)"
    }
}
