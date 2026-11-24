import Foundation

/// One directory as git sees it: the checkout it is in, its branch and
/// where its remotes point.
struct GitHubCheckout: Sendable, Equatable {
    let topLevel: String
    /// Nil on a detached HEAD.
    let branch: String?
    /// Every remote's URL, as git has them.
    let remoteURLs: [String]

    /// A remote points at `repository` (`owner/name`) on GitHub's `host`.
    func isCheckout(of repository: String, host: String) -> Bool {
        remoteURLs.contains { url in
            GitHubRemote.repository(fromURL: url, host: host)?.caseInsensitiveCompare(repository) == .orderedSame
        }
    }
}

/// Which repository and branch the Agents' directories are checkouts of,
/// for Send to Agent (ADR 0064): one script through the gh seam, so a Rex
/// Host answers too. git only, read-only, and nothing about the account.
enum GitHubCheckoutRead {
    /// The most directories one read asks about.
    static let directoryLimit = 24
    static let cap = 4_096

    private static let commands = [
        ("top", "rev-parse --show-toplevel"),
        ("branch", "symbolic-ref -q --short HEAD"),
        ("remotes", "config --get-regexp '^remote\\..*\\.url$'"),
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
            // `remote.<name>.url <url>`; a remote's name can hold a space, its URL rarely does.
            let urls = (try? frames.section("remotes\(index)", cap: cap)).map { section in
                String(decoding: section.body, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
                    line.split(separator: " ").last.map(String.init)
                }
            } ?? []
            checkouts[directory] = GitHubCheckout(topLevel: topLevel, branch: branch, remoteURLs: urls)
        }
        return checkouts
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
