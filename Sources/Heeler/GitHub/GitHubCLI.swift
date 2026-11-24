import Foundation

/// Runs one gh script on a Host over its SSH connection (ADR 0064): one
/// bounded exec of POSIX sh, the same on every Server Kind. Heeler never
/// sees the account's token; gh reads it on the Host as it always does.
protocol GitHubHostCLI: Sendable {
    /// `isMutation` marks a script that changes something on GitHub. It is
    /// sent once, and a failure after it was handed to SSH throws
    /// `TransportError.coreMutationOutcomeUnknown`: it may have run.
    func runGitHubScript(_ script: Data, isMutation: Bool) async throws -> GitExecResult
}

extension GitHubHostCLI {
    /// A connection without Host commands cannot run gh, and says so.
    func runGitHubScript(_ script: Data, isMutation: Bool) async throws -> GitExecResult {
        throw TransportError.hostFeatureUnavailable(feature: String(localized: "GitHub"))
    }
}

/// One gh command line, as its arguments after `gh`.
struct GitHubCLIRequest: Sendable, Equatable {
    var arguments: [String]
    /// A request that changes something on GitHub. It runs once in one exec
    /// and is never sent again, whatever came back.
    var isMutation: Bool
    /// What the user typed, for gh's `--body-file`. The script writes these
    /// bytes to a file in its private folder as printf's octal escapes, so
    /// none of them is ever shell syntax, and the command names that file.
    var body: String?

    /// A GraphQL read through `gh api graphql`, with the response headers so
    /// a rate limit can say when it ends. Each variable goes as a string
    /// (`-f`), as GitHub's node ids are.
    static func graphQL(_ query: String, variables: [String: String] = [:]) -> GitHubCLIRequest {
        // One line keeps the script small; GraphQL ignores the whitespace.
        let compact = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var arguments = ["api", "graphql", "-i", "-f", "query=\(compact)"]
        for (name, value) in variables.sorted(by: { $0.key < $1.key }) {
            arguments += ["-f", "\(name)=\(value)"]
        }
        return GitHubCLIRequest(arguments: arguments, isMutation: false)
    }
}

/// Where gh ran on the Host.
enum GitHubCLIRoute: Sendable, Equatable {
    /// In the SSH exec itself.
    case exec
    /// In a one-shot job in the macOS desktop session's launchd domain,
    /// whose gh can read the login keychain an SSH session cannot.
    case desktop
}

/// The gh script: find gh, run the request once and, on a Mac where the
/// exec's gh has no usable token, run it once more in the desktop session.
/// gh runs in the script's private temporary folder, with git kept from
/// finding a checkout around it, so no gh command acts on a local
/// repository (`gh pr merge --delete-branch` would delete a local branch).
/// A write runs again in the desktop session only on that same proof that
/// the first gh did nothing: with no token it could change nothing.
///
/// The folder holds what the user typed, gh's output and the desktop job's
/// environment, so the script boots its job out and removes the folder on
/// any exit it can trap. An exec whose connection or channel closed gets
/// only SIGPIPE, at its next write to standard output, and dash runs no
/// EXIT trap for it, so SIGPIPE is trapped too. The watchdog's SIGKILL
/// cannot be, and the next run's sweep removes what it left.
enum GitHubCLIScript {
    /// How a run may use the desktop session.
    enum Mode: String, Sendable {
        /// The exec first; the desktop session only when gh there has no
        /// usable token, on a Mac.
        case auto
        /// Straight to the desktop session, on a Host whose connection
        /// already needed it.
        case desktop
    }

    /// What GitHub adds to a rate limit it applied to a request with no token,
    /// which is what gh sends on a Mac over SSH when it cannot read the
    /// keychain and its configuration names an account: a 401, or once the
    /// address's few requests without a token are spent, this.
    static let unauthenticatedMark = "Authenticated requests get a higher rate limit"

    /// How long the exec may run before the remote watchdog kills it, with
    /// no cleanup: no trap runs on SIGKILL, and a later run's sweep removes
    /// what it left.
    static let execSeconds: Int64 = 50
    /// How long the desktop job may take, in seconds of wall time. 300
    /// rounds of `sleep 0.1` took 33 to 43 seconds on a Mac, so the poll
    /// reads the clock.
    static let desktopWaitSeconds = 30
    /// When, in seconds from the script's start, the desktop wait ends
    /// however long gh took in the exec first: early enough to boot the job
    /// out and remove the folder before the watchdog.
    static let desktopWaitEnd = Int(execSeconds) - 6
    /// How old, by its folder's last change, a run's folder or finished
    /// desktop job must be before a later run removes it: more than this
    /// many minutes by GNU find, and a minute more by macOS's and BusyBox's,
    /// which count whole minutes. Either is more than twice `execSeconds`,
    /// so it belongs to no run still reading it.
    static let staleMinutes = 2
    /// The most of gh's output and error output the script returns.
    static let outputCap = 4 * 1024 * 1024
    static let errorCap = 4096

    /// Variables the desktop job takes from the exec: where gh, its
    /// configuration and its tools are, gh's own quiet settings, the proxy
    /// the SSH session reaches GitHub through, and git's ceiling. A token in
    /// the exec's environment stays there.
    static let desktopVariables = [
        "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "PATH", "TMPDIR",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "MISE_DATA_DIR",
        "GH_CONFIG_DIR", "GH_HOST", "GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER",
        "GH_NO_EXTENSION_UPDATE_NOTIFIER", "GH_SPINNER_DISABLED", "NO_COLOR", "CLICOLOR", "GH_PAGER",
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
        "https_proxy", "http_proxy", "all_proxy", "no_proxy",
        "GIT_CEILING_DIRECTORIES", "HEELER_GH",
    ]

    /// Bytes of a body per printf line.
    private static let bodyLineBytes = 256

    /// Removes what earlier runs could not: the watchdog's SIGKILL runs no
    /// trap, so its run's folder and desktop job stay. A folder goes once
    /// its last change is `staleMinutes` old and its run's job is not
    /// running; a desktop job of this user once it has run and stopped and
    /// its folder is gone or as old. A running job, a write's included, is
    /// left to finish, and a later run removes it.
    private static let sweep = #"""
        for f in "${TMPDIR:-/tmp}"/heeler-gh.*; do
            [ -d "$f" ] && [ ! -L "$f" ] || continue
            [ -n "$(find "$f" -prune -user "$U" -mmin +\#(staleMinutes) 2>/dev/null)" ] || continue
            if [ "$os" = Darwin ]; then
                n=${f##*/heeler-gh.}
                l=dev.bybee.heeler.gh.${n%%.*}
                s=$(launchctl print "gui/$U/$l" 2>/dev/null)
                case $s in *'state = running'*) continue ;; esac
                [ -n "$s" ] && launchctl bootout "gui/$U/$l" >/dev/null 2>&1
            fi
            rm -rf "$f"
        done
        if [ "$os" = Darwin ]; then
            for l in $(launchctl print "gui/$U" 2>/dev/null | grep -o 'dev\.bybee\.heeler\.gh\.[0-9A-F]*'); do
                s=$(launchctl print "gui/$U/$l" 2>/dev/null) || continue
                case $s in *'state = running'*|*'(never exited)'*) continue ;; esac
                f=$(printf '%s\n' "$s" | sed -n 's|^[[:space:]]*path = \(.*/heeler-gh\.[^/]*\)/job\.plist$|\1|p')
                if [ -n "$f" ] && [ -d "$f" ] && [ -z "$(find "$f" -prune -mmin +\#(staleMinutes) 2>/dev/null)" ]; then
                    continue
                fi
                launchctl bootout "gui/$U/$l" >/dev/null 2>&1
                [ -n "$f" ] && [ -d "$f" ] && [ ! -L "$f" ] && rm -rf "$f"
            done
        fi
        """#

    static func script(for request: GitHubCLIRequest, mode: Mode, nonce: String) -> Data {
        var words = ["\"$HEELER_GH\""] + request.arguments.map(GitProbe.singleQuoted)
        if request.body != nil { words += ["--body-file", "\"$D/body\""] }
        let command = words.joined(separator: " ")
        let job = "__HEELER_GH_JOB_\(nonce)__"
        let plist = "__HEELER_GH_PLIST_\(nonce)__"
        return Data("""
            N=\(nonce)
            T=$(date +%s 2>/dev/null)
            LC_ALL=C
            export LC_ALL
            PATH="\(HerdrHostPath.extraPATH):/snap/bin:$PATH"
            export PATH
            GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1
            GH_SPINNER_DISABLED=1 NO_COLOR=1 CLICOLOR=0 GH_PAGER=cat
            export GH_PROMPT_DISABLED GH_NO_UPDATE_NOTIFIER GH_NO_EXTENSION_UPDATE_NOTIFIER
            export GH_SPINNER_DISABLED NO_COLOR CLICOLOR GH_PAGER
            unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
            m() { printf '\\n%s %s\\n' "$N" "$1"; }
            q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\\\\\''/g")"; }
            os=$(uname -s 2>/dev/null)
            m "os $os"
            U=$(id -u)
            L=
            \(sweep)
            HEELER_GH=$(command -v gh 2>/dev/null)
            case $HEELER_GH in /*) ;; *) m missing; m done; exit 0 ;; esac
            export HEELER_GH
            D=$(mktemp -d "${TMPDIR:-/tmp}/heeler-gh.$N.XXXXXXXX") || { m 'route failed'; m done; exit 0; }
            c() {
                [ -n "$L" ] && launchctl bootout "gui/$U/$L" >/dev/null 2>&1
                rm -rf "$D"
            }
            trap c EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 141' PIPE
            trap 'exit 143' TERM
            GIT_CEILING_DIRECTORIES=${D%/*}
            export GIT_CEILING_DIRECTORIES
            cd "$D" || { m 'route failed'; m done; exit 0; }
            \(bodyFile(request.body))
            route=exec
            rc=
            if [ "$os" = Darwin ] && [ \(mode.rawValue) = desktop ]; then
                route=desktop
            else
                \(command) >"$D/out" 2>"$D/err" </dev/null
                rc=$?
                if [ "$os" = Darwin ] && [ \(mode.rawValue) = auto ]; then
                    if [ "$rc" = 4 ] || grep -q -e 'HTTP 401' -e '\(unauthenticatedMark)' "$D/err"; then
                        route=desktop
                    fi
                fi
            fi
            if [ "$route" = desktop ]; then
                case $D in *[!A-Za-z0-9/._-]*) route=unavailable ;; esac
            fi
            if [ "$route" = desktop ]; then
                L=dev.bybee.heeler.gh.$N
                for v in \(desktopVariables.joined(separator: " ")); do
                    eval "s=\\${$v+x}"
                    if [ -n "$s" ]; then
                        eval "x=\\$$v"
                        printf '%s=%s; export %s\\n' "$v" "$(q "$x")" "$v"
                    fi
                done >"$D/env"
                cat >"$D/job" <<'\(job)'
            . "$1/env"
            D=$1
            cd "$D" || exit 1
            \(command) >"$D/gout" 2>"$D/gerr" </dev/null
            echo $? >"$D/grc.tmp"
            mv "$D/grc.tmp" "$D/grc"
            \(job)
                cat >"$D/job.plist" <<\(plist)
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>$L</string>
            <key>ProgramArguments</key><array><string>/bin/sh</string><string>$D/job</string><string>$D</string></array>
            <key>RunAtLoad</key><true/>
            </dict></plist>
            \(plist)
                if launchctl bootstrap "gui/$U" "$D/job.plist" >/dev/null 2>&1; then
                    E=$(($(date +%s) + \(desktopWaitSeconds)))
                    [ "$E" -gt $((T + \(desktopWaitEnd))) ] && E=$((T + \(desktopWaitEnd)))
                    i=0
                    while [ ! -f "$D/grc" ]; do
                        sleep 0.1
                        i=$((i + 1))
                        [ $((i % 10)) = 0 ] && [ "$(date +%s)" -ge "$E" ] && break
                    done
                    launchctl bootout "gui/$U/$L" >/dev/null 2>&1
                    L=
                    if [ -f "$D/grc" ]; then
                        rc=$(cat "$D/grc")
                        mv "$D/gout" "$D/out"
                        mv "$D/gerr" "$D/err"
                    else
                        route=timeout
                    fi
                else
                    route=unavailable
                fi
            fi
            m "route $route"
            m "rc $rc"
            m out
            head -c \(outputCap) "$D/out" 2>/dev/null
            m err
            head -c \(errorCap) "$D/err" 2>/dev/null
            m done

            """.utf8)
    }

    /// The lines that write `body` to `$D/body`, each byte as an octal
    /// escape in printf's format, which POSIX printf turns back into that
    /// byte. Nothing the user typed reaches the shell as text. A failed
    /// write ends the script before gh runs.
    private static func bodyFile(_ body: String?) -> String {
        guard let body else { return "" }
        let bytes = Array(body.utf8)
        var lines = [":"]
        for start in stride(from: 0, to: bytes.count, by: bodyLineBytes) {
            let escapes = bytes[start..<min(start + bodyLineBytes, bytes.count)].map { byte in
                let digits = String(byte, radix: 8)
                return "\\" + String(repeating: "0", count: 3 - digits.count) + digits
            }
            lines.append("printf '\(escapes.joined())'")
        }
        return "{ \(lines.joined(separator: "; ")); } >\"$D/body\" || { m 'route failed'; m done; exit 0; }"
    }
}

/// What one gh script reported.
struct GitHubCLIOutcome: Sendable, Equatable {
    enum Route: Sendable, Equatable {
        case ran(GitHubCLIRoute)
        /// gh in the exec had no usable token and the Mac has no desktop
        /// session to run it in: no one is logged in at the desktop.
        case desktopUnavailable
        /// The desktop job did not finish in its time.
        case desktopTimedOut
        /// The script could not make its private temporary folder.
        case failed
    }

    /// `uname -s`: `Darwin`, `Linux`, ...
    let system: String
    /// Nil when gh is not on the exec's PATH.
    let run: Run?

    struct Run: Sendable, Equatable {
        let route: Route
        /// gh's exit status, nil when gh never finished.
        let exitStatus: Int32?
        let output: Data
        let errorOutput: String
    }

    var isMac: Bool { system == "Darwin" }

    /// The script's frames. Nil when they are not all there: the script did
    /// not finish, or something else wrote to its output.
    init?(stdout: Data, nonce: String) {
        let lead = Data("\n\(nonce) ".utf8)
        var frames: [(name: String, contentStart: Int, markerStart: Int)] = []
        var cursor = stdout.startIndex
        while let range = stdout.range(of: lead, in: cursor..<stdout.endIndex) {
            guard let lineEnd = stdout[range.upperBound...].firstIndex(of: 0x0A) else { return nil }
            let name = String(decoding: stdout[range.upperBound..<lineEnd], as: UTF8.self)
            frames.append((name, lineEnd + 1, range.lowerBound))
            cursor = lineEnd
        }
        func content(after index: Int) -> Data {
            let start = frames[index].contentStart
            let end = index + 1 < frames.count ? frames[index + 1].markerStart : stdout.endIndex
            return start <= end ? Data(stdout[start..<end]) : Data()
        }
        guard frames.last?.name == "done",
            let osFrame = frames.first, osFrame.name.hasPrefix("os")
        else { return nil }
        system = String(osFrame.name.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let names = frames.map(\.name)
        if names.contains("missing") {
            run = nil
            return
        }
        guard let routeName = names.first(where: { $0.hasPrefix("route ") }) else { return nil }
        let route: Route =
            switch routeName.dropFirst("route ".count) {
            case "exec": .ran(.exec)
            case "desktop": .ran(.desktop)
            case "unavailable": .desktopUnavailable
            case "timeout": .desktopTimedOut
            default: .failed
            }
        let status = names.first { $0.hasPrefix("rc") }.flatMap { Int32($0.dropFirst(2).trimmingCharacters(in: .whitespaces)) }
        let output = names.firstIndex(of: "out").map(content(after:)) ?? Data()
        let errorOutput = names.firstIndex(of: "err").map(content(after:)) ?? Data()
        run = Run(
            route: route, exitStatus: status, output: output,
            errorOutput: String(decoding: errorOutput, as: UTF8.self))
    }
}

/// `gh api -i` output: the status line and headers, then the body.
struct GitHubHTTPResponse: Sendable, Equatable {
    let status: Int?
    /// Header names in lower case.
    let headers: [String: String]
    let body: Data

    init(including output: Data) {
        guard output.starts(with: Data("HTTP/".utf8)) else {
            status = nil
            headers = [:]
            body = output
            return
        }
        let separator = output.range(of: Data("\r\n\r\n".utf8)) ?? output.range(of: Data("\n\n".utf8))
        let head = separator.map { output[..<$0.lowerBound] } ?? output[...]
        body = separator.map { Data(output[$0.upperBound...]) } ?? Data()
        let lines = String(decoding: head, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        status = lines.first.flatMap { line in
            line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }
}
