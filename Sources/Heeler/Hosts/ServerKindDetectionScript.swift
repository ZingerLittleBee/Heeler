import Foundation

/// The one script that detects a Host's Server Kind (ADR 0031), and how to read
/// what it prints. Pure, like the locator it wraps: a caller runs the script in
/// one bounded exec.
///
/// `herdrRead` runs first, in a subshell of its own, so its PATH never reaches
/// the locator. Neither part starts a server.
enum ServerKindDetectionScript {
    /// What one run printed, before anyone decides what it means.
    struct Output: Equatable, Sendable {
        let herdrStatus: Int32
        let herdrOutput: Data
        /// Nil when hc refuses the session's name, so no locator ran.
        let location: HerdrCoreLocator.Location?
    }

    static func script(session: String, nonce: String, herdrRead: String) -> Data {
        var script = Data(
            """
            printf '\\n%s herdr-tui begin\\n' '\(nonce)'
            (
            \(herdrRead)
            ) </dev/null 2>/dev/null
            printf '\\n%s herdr-tui status %s\\n' '\(nonce)' "$?"

            """.utf8)
        if let locator = try? HerdrCoreLocator.script(session: session, nonce: nonce) {
            script.append(locator)
        } else {
            script.append(Data("exit 0\n".utf8))
        }
        return script
    }

    /// A read that lacks either part was cut short. Whatever the user's shell
    /// printed around the markers is ignored, in any encoding.
    static func parse(stdout: Data, session: String, nonce: String) throws -> Output {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let statusPrefix = Data("\(nonce) herdr-tui status ".utf8)
        guard let begin = lines.firstIndex(where: { $0.elementsEqual("\(nonce) herdr-tui begin".utf8) }),
            let statusLine = lines.lastIndex(where: { $0.starts(with: statusPrefix) }), begin < statusLine,
            let status = Int32(String(decoding: lines[statusLine].dropFirst(statusPrefix.count), as: UTF8.self))
        else { throw HerdrCoreLocator.MalformedOutput() }
        let location =
            HerdrCoreSessionName.isValid(session)
            ? try HerdrCoreLocator.parse(stdout: stdout, nonce: nonce) : nil
        return Output(
            herdrStatus: status,
            herdrOutput: Data(lines[(begin + 1)..<statusLine].joined(separator: [UInt8(ascii: "\n")])),
            location: location)
    }
}
