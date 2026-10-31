import Foundation

/// One git command for `HostServices.runGitCommand`, in one directory on the Host.
struct GitCommand: Equatable, Sendable {
    let arguments: [String]
    let directory: String
    /// A read goes through the neutralized `g`, so it runs nothing the repository
    /// configured and changes nothing. A mutation runs plain `git`, as the user's
    /// own would, hooks included, and has a longer bound. It is never sent twice.
    let isMutation: Bool
}

/// What git said. A refusal is an answer, not a thrown error.
struct GitCommandResult: Equatable, Sendable {
    let status: Int32
    let output: String
    /// Git's own error line, when it printed one.
    let message: String?
    /// The output passed its cap, so `status` may only be the cut's.
    var isTruncated = false
}

extension GitProbe.Cap {
    /// A listing of several hundred checkouts. A longer status still says it has changes.
    static let command = 262_144
}

extension GitProbe {
    static let commandSection = "command"

    /// Every word is single-quoted, so what a user typed reaches git as one word.
    static func commandScript(_ command: GitCommand, nonce: String) -> Data {
        var body = Data("dir=".utf8)
        body.append(singleQuoted(Data(command.directory.utf8)))
        let git = command.isMutation ? "git" : "g"
        body.append(Data("\nsec \(Cap.command) \(commandSection) \(git) -C \"$dir\"".utf8))
        for argument in command.arguments {
            body.append(0x20)
            body.append(singleQuoted(Data(argument.utf8)))
        }
        body.append(0x0A)
        return script(nonce: nonce, body: body)
    }

    /// Throws `ChangesReadError.incomplete` when the script did not run to its end,
    /// which for a mutation says nothing about what it did.
    static func parseCommand(stdout: Data, stderr: Data, nonce: String) throws -> GitCommandResult {
        let frames = Frames(stdout: stdout, stderr: stderr, nonce: nonce)
        guard frames.reachedEnd else { throw ChangesReadError.incomplete }
        let section = try frames.requiredSection(commandSection, cap: Cap.command)
        return GitCommandResult(
            status: section.status, output: String(decoding: section.body, as: UTF8.self),
            message: errorLine(section), isTruncated: section.isTruncated)
    }

    /// `git worktree add` prints its progress on standard error ahead of any failure.
    private static func errorLine(_ section: Section) -> String? {
        String(decoding: section.messages, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
            ?? section.firstMessageLine
    }
}
