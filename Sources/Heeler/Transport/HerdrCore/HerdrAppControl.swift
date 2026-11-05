import Foundation

/// Asks the Herdr desktop app on a Host to name a space, through its own control
/// client over SSH exec (ADR 0032). Pure: it builds the script a caller runs in
/// one bounded exec and judges what comes back. Nothing here sends anything
/// twice, and neither `status` nor `do` opens a window or starts a core.
enum HerdrAppControl {
    /// Whether Rename and applying a typed name are offered at all. The owner's
    /// check on a desktop Mac passed over SSH (ADR 0032); turn this off if a
    /// desktop app release stops answering `herdr-app do` from an SSH session.
    static let isRenameOn = true

    /// What the app answered to `do`.
    enum DoOutcome: Equatable, Sendable {
        case done
        /// The client said no. `reason` is its own words, when it gave any.
        case refused(reason: String?)
        /// The output was cut short, so the command may have run.
        case unknown
    }

    /// The desktop app's own refusal of a rename.
    struct Refused: Error, Equatable {
        let reason: String?
    }

    // MARK: Scripts

    /// One JSON object as one argument: with flags the client reads a name that
    /// parses as JSON, such as `2026`, as a value of that type.
    static func renameScript(spaceID: String, name: String, nonce: String) throws -> Data {
        let arguments = try JSONSerialization.data(
            withJSONObject: ["id": spaceID, "name": name], options: [.sortedKeys, .withoutEscapingSlashes])
        return script(
            arguments: "do space.rename \(HerdrCoreLocator.quoted(String(decoding: arguments, as: UTF8.self)))",
            nonce: nonce)
    }

    static func statusScript(nonce: String) -> Data {
        script(arguments: "status", nonce: nonce)
    }

    /// Where the desktop app's installers put it, after the exec's PATH: their
    /// link in `~/.local/bin`, Linux's data folder, and macOS's two Applications
    /// folders. A DMG install makes no link. The client takes its socket from the
    /// same variables as the app, so what it reaches is this account's window.
    private static func script(arguments: String, nonce: String) -> Data {
        let word = HerdrCoreLocator.quoted(nonce)
        return Data(
            """
            __app=
            __try() {
                [ -z "$__app" ] || return 0
                case "$1" in /*) ;; *) return 0 ;; esac
                [ -d "$1" ] || { [ -x "$1" ] && __app=$1; }
                return 0
            }
            __try "$(command -v herdr-app 2>/dev/null)"
            __try "${HOME:-}/.local/bin/herdr-app"
            __try "${XDG_DATA_HOME:-${HOME:-}/.local/share}/herdr-app/herdr-app"
            __try "${HOME:-}/Applications/Herdr.app/Contents/MacOS/Herdr"
            __try /Applications/Herdr.app/Contents/MacOS/Herdr
            if [ -z "$__app" ]; then
                printf '\\n%s absent\\n' \(word)
                exit 0
            fi
            printf '\\n%s begin\\n' \(word)
            "$__app" \(arguments) </dev/null 2>/dev/null
            __status=$?
            printf '\\n%s end %s\\n' \(word) "$__status"
            exit 0
            """.utf8)
    }

    // MARK: Answers

    /// The client's answer, between the markers: startup files may print
    /// anything around them.
    private enum Answer {
        case absent
        case exited(status: Int32, reply: [String: Any]?)
        case cutShort
    }

    private static func answer(stdout: Data, nonce: String) -> Answer {
        let lines = stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let absent = "\(nonce) absent".utf8
        if lines.contains(where: { $0.elementsEqual(absent) }) { return .absent }
        let closing = Array("\(nonce) end ".utf8)
        guard let begin = lines.firstIndex(where: { $0.elementsEqual("\(nonce) begin".utf8) }),
            let end = lines.lastIndex(where: { $0.starts(with: closing) }), begin < end,
            let status = Int32(String(decoding: lines[end].dropFirst(closing.count), as: UTF8.self))
        else { return .cutShort }
        let body = Data(lines[(begin + 1)..<end].joined(separator: [UInt8(ascii: "\n")]))
        let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return .exited(status: status, reply: reply)
    }

    /// True only when the app itself answered, with no error. No client, no
    /// window, a window that did not answer, or a cut-short read all read as not
    /// running: the field and Rename then stay hidden.
    static func isRunning(_ result: GitExecResult, nonce: String) -> Bool {
        guard result.exitStatus == 0,
            case .exited(0, let reply?) = answer(stdout: result.stdout, nonce: nonce)
        else { return false }
        return reply["error"] == nil
    }

    static func doOutcome(_ result: GitExecResult, nonce: String) -> DoOutcome {
        guard result.exitStatus == 0 else { return .unknown }
        switch answer(stdout: result.stdout, nonce: nonce) {
        case .absent:
            return .refused(reason: nil)
        case .cutShort:
            return .unknown
        case .exited(let status, let reply):
            if let reply, reply["error"] != nil {
                return .refused(reason: reply["error"] as? String)
            }
            if status != 0 { return .refused(reason: nil) }
            return reply == nil ? .unknown : .done
        }
    }
}
