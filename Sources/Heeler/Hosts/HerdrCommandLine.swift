import Foundation

/// A herdr command line for the user to run on a Host, aimed at the herdr
/// instance the Host targets.
enum HerdrCommandLine {
    /// `herdr <arguments>` for the default session, or
    /// `herdr --session <name> <arguments>` for a named one.
    ///
    /// `session` is the Host's session name, trimmed as `Host.socketLocation`
    /// trims it, so a blank name means the default session, as it does for
    /// the Transport. herdr reads `--session` anywhere before `--`
    /// (`session::configure_from_args`, checked at 0.7.5 and 0.9.4), so the
    /// flag goes right after `herdr`.
    ///
    /// The user pastes the line into a shell on the Host, which may be sh,
    /// bash, zsh or fish, so every word, the session name included, reads the
    /// same in all four. Valid session names and herdr's own ids stay bare;
    /// anything else is single-quoted. herdr still takes a word that
    /// `readsAsGlobalOption` matches as its own option, however it was
    /// quoted, so such a word cannot be passed as an argument: a caller
    /// passing a value Heeler did not choose, such as a herdr id, checks it
    /// with `readsAsGlobalOption` and offers no command when it matches.
    /// An endpoint overrides `session`. Pass its socket, launcher and argv
    /// as separate words, keeping shell syntax out of the POSIX wrapper.
    static func render(
        session: String, endpoint: HerdrEndpoint? = nil, arguments: [String]
    ) -> String {
        if let endpoint {
            return "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; shift; exec \"$@\"' herdr "
                + ([endpoint.socketPath, endpoint.executablePath] + arguments)
                    .map(word).joined(separator: " ")
        }
        let name = session.trimmingCharacters(in: .whitespaces)
        let scope = name.isEmpty ? [] : ["--session", name]
        return (["herdr"] + (scope + arguments).map(word)).joined(separator: " ")
    }

    /// Whether herdr takes `word` as one of its own options wherever it
    /// appears before `--`, however it was quoted: a word that is
    /// `--handoff`, `--session`, `--remote` or `--remote-keybindings`, or
    /// that starts with one of the last three and `=`
    /// (`session::configure_from_args` and `remote::extract_remote_args`,
    /// checked at 0.9.3 and 0.9.4). herdr compares bytes, so this does too.
    static func readsAsGlobalOption(_ word: String) -> Bool {
        let bytes = word.utf8
        return bytes.elementsEqual("--handoff".utf8)
            || ["--session", "--remote", "--remote-keybindings"].contains { option in
                bytes.elementsEqual(option.utf8) || bytes.starts(with: (option + "=").utf8)
            }
    }

    /// Inside single quotes fish reads `\'` and `\\` as escapes and POSIX
    /// shells read neither, so each `'` and `\` goes outside the quotes as
    /// `\'` or `\\`, which all four shells read alike. It walks Unicode
    /// scalars, not Characters, so a combining mark cannot hide a quote.
    private static func word(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.utf8.allSatisfy(isShellSafe) { return value }
        var quoted = String.UnicodeScalarView()
        var isInsideQuotes = false
        for scalar in value.unicodeScalars {
            if scalar == "'" || scalar == "\\" {
                if isInsideQuotes { quoted.append("'") }
                isInsideQuotes = false
                quoted.append("\\")
            } else if !isInsideQuotes {
                quoted.append("'")
                isInsideQuotes = true
            }
            quoted.append(scalar)
        }
        if isInsideQuotes { quoted.append("'") }
        return String(quoted)
    }

    /// herdr's session name characters plus the `:` in its tab and pane
    /// ids, all literal anywhere in a word in the four shells. `~` and `=`
    /// stay out: all four expand a leading `~`, and zsh a leading `=`.
    private static func isShellSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"),
            UInt8(ascii: "-"), UInt8(ascii: ":"):
            true
        default:
            false
        }
    }
}
