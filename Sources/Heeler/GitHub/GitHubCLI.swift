import Foundation

/// Runs one gh script on a Host over its SSH connection (ADR 0064): one
/// bounded exec of POSIX sh, the same on every Server Kind. Heeler never
/// sees the account's token; gh reads it on the Host as it always does.
protocol GitHubHostCLI: Sendable {
    func runGitHubScript(_ script: Data) async throws -> GitExecResult
}

extension GitHubHostCLI {
    /// A connection without Host commands cannot run gh, and says so.
    func runGitHubScript(_ script: Data) async throws -> GitExecResult {
        throw TransportError.hostFeatureUnavailable(feature: String(localized: "GitHub"))
    }
}

/// One gh command line, as its arguments after `gh`.
struct GitHubCLIRequest: Sendable, Equatable {
    var arguments: [String]
    /// A request that changes something on GitHub. It runs once in one exec
    /// and is never sent again, whatever came back.
    var isMutation: Bool

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

    /// How long the desktop job may take, in tenths of a second.
    static let desktopPollTenths = 300
    /// The most of gh's output and error output the script returns.
    static let outputCap = 4 * 1024 * 1024
    static let errorCap = 4096

    /// Variables the desktop job takes from the exec: where gh, its
    /// configuration and its tools are, gh's own quiet settings, and the
    /// proxy the SSH session reaches GitHub through. A token in the exec's
    /// environment stays there.
    static let desktopVariables = [
        "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "PATH", "TMPDIR",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "MISE_DATA_DIR",
        "GH_CONFIG_DIR", "GH_HOST", "GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER",
        "GH_NO_EXTENSION_UPDATE_NOTIFIER", "GH_SPINNER_DISABLED", "NO_COLOR", "CLICOLOR", "GH_PAGER",
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
        "https_proxy", "http_proxy", "all_proxy", "no_proxy",
        "HEELER_GH",
    ]

    static func script(for request: GitHubCLIRequest, mode: Mode, nonce: String) -> Data {
        let command = (["\"$HEELER_GH\""] + request.arguments.map(GitProbe.singleQuoted))
            .joined(separator: " ")
        let job = "__HEELER_GH_JOB_\(nonce)__"
        let plist = "__HEELER_GH_PLIST_\(nonce)__"
        return Data("""
            N=\(nonce)
            LC_ALL=C
            export LC_ALL
            PATH="\(HerdrHostPath.extraPATH):/snap/bin:$PATH"
            export PATH
            GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1
            GH_SPINNER_DISABLED=1 NO_COLOR=1 CLICOLOR=0 GH_PAGER=cat
            export GH_PROMPT_DISABLED GH_NO_UPDATE_NOTIFIER GH_NO_EXTENSION_UPDATE_NOTIFIER
            export GH_SPINNER_DISABLED NO_COLOR CLICOLOR GH_PAGER
            m() { printf '\\n%s %s\\n' "$N" "$1"; }
            q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\\\\\''/g")"; }
            os=$(uname -s 2>/dev/null)
            m "os $os"
            HEELER_GH=$(command -v gh 2>/dev/null)
            case $HEELER_GH in /*) ;; *) m missing; m done; exit 0 ;; esac
            export HEELER_GH
            D=$(mktemp -d "${TMPDIR:-/tmp}/heeler-gh.XXXXXXXX") || { m 'route failed'; m done; exit 0; }
            trap 'rm -rf "$D"' EXIT
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
                U=$(id -u)
                for v in \(desktopVariables.joined(separator: " ")); do
                    eval "s=\\${$v+x}"
                    if [ -n "$s" ]; then
                        eval "x=\\$$v"
                        printf '%s=%s; export %s\\n' "$v" "$(q "$x")" "$v"
                    fi
                done >"$D/env"
                cat >"$D/job" <<'\(job)'
            . "$1/env"
            cd "$HOME" 2>/dev/null || cd /
            \(command) >"$1/gout" 2>"$1/gerr" </dev/null
            echo $? >"$1/grc.tmp"
            mv "$1/grc.tmp" "$1/grc"
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
                    i=0
                    while [ ! -f "$D/grc" ] && [ "$i" -lt \(desktopPollTenths) ]; do
                        sleep 0.1
                        i=$((i + 1))
                    done
                    launchctl bootout "gui/$U/$L" >/dev/null 2>&1
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
