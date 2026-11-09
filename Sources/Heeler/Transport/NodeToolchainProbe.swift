import Foundation

/// Finds the Host's Node.js for a plugin install, whose `npm ci` build runs
/// with the exec's `PATH`. SSH exec reads no interactive shell setup, which
/// is where most Node.js installs put themselves on `PATH`, so the probe
/// looks where each common install method keeps a default `node` and `npm`,
/// in the order an interactive shell usually ends up with: version managers
/// first, then each directory on `PATH`, then system-wide package managers,
/// and last the login shell itself, bounded by a watchdog.
///
/// A directory counts only when its `npm` runs and the `node` it would start
/// is at least ``minimumMajorVersion``, so a shim with no version selected
/// (mise, asdf, nodenv) or an old default is passed over. The chosen
/// directory goes first on `PATH`. Without one the probe exits
/// ``failureExitStatus`` before herdr fetches anything, printing
/// ``missingMarker``, ``tooOldMarker`` and the first old version it saw, or
/// ``npmMissingMarker`` and the version of a new enough node without npm.
enum NodeToolchainProbe {
    /// The plugin's `engines.node`.
    static let minimumMajorVersion = 20
    static let missingMarker = "__HEELER_NODE_NOT_FOUND__"
    static let tooOldMarker = "__HEELER_NODE_TOO_OLD__="
    static let npmMissingMarker = "__HEELER_NPM_NOT_FOUND__="
    static let failureExitStatus: Int32 = 3
    /// How long the login shell may take to say where `npm` is.
    static let loginShellSeconds = 10

    /// Where the probe looks, for the failure message.
    static let searchedPlaces =
        "mise, Volta, fnm, nvm, asdf, nodenv, nvs, nodebrew, n, proto, pnpm, Homebrew, "
        + "the SSH PATH, Nix, snap, MacPorts and the login shell"

    /// A bare `herdr …` (``HerdrCommandLine/render(session:endpoint:arguments:)``
    /// without an endpoint) under `/bin/sh` with the app's PATH prefixes, as
    /// ``HerdrHostPath/wrappingBareHerdr(_:)`` runs it, and the probe's
    /// directory first. `herdr` is resolved before the probe changes `PATH`,
    /// so a `herdr` beside Node.js cannot replace the one Heeler runs
    /// elsewhere; a missing one still exits 127.
    static func wrappingBareHerdr(_ command: String) -> String {
        guard HerdrHostPath.isBareHerdrCommand(command), command.hasPrefix("herdr") else {
            return command
        }
        let arguments = command.dropFirst("herdr".count)
            .replacingOccurrences(of: "'", with: "'\\''")
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "__h_herdr=$(command -v herdr) || exit 127; "
            + "\(script)exec \"$__h_herdr\"\(arguments)'"
    }

    /// POSIX sh statements ending in `; `, free of single quotes so they fit
    /// inside a single-quoted `/bin/sh -c` body. Variables use a `__h_`
    /// prefix to stay clear of the Host's environment; the function's `$1`
    /// leaves the body's own positional parameters alone.
    static let script = ([
        // Accepts the npm in $1, with $2 when its shims need another
        // directory, when it runs and the node it would start is new enough.
        // That node is the one `PATH` finds with $1 first, as npm's
        // `#!/usr/bin/env node` does, so an npm upgraded into its own prefix
        // still pairs with the system's node. The first success wins, and
        // the first old version is kept to report.
        "__h_npm=",
        "__h_old=",
        "__h_try() { [ -z \"$__h_npm\" ] || return 0; [ -n \"$1\" ] && [ -x \"$1/npm\" ] || return 1; "
            + "__h_p=\"$1${2:+:$2}\"; "
            + "__h_v=$(PATH=\"$__h_p:$PATH\"; node -p process.versions.node </dev/null 2>/dev/null) "
            + "|| return 1; "
            + "if ! [ \"${__h_v%%.*}\" -ge \(minimumMajorVersion) ] 2>/dev/null; then "
            + "[ -n \"$__h_old\" ] || __h_old=\"$__h_v\"; return 1; fi; "
            + "PATH=\"$__h_p:$PATH\" \"$1/npm\" --version </dev/null >/dev/null 2>&1 || return 1; "
            + "__h_npm=\"$__h_p\"; }",
    ] + searches + [
        // Without an npm, a node alone still says what to fix.
        "if [ -z \"$__h_npm\" ]; then if [ -z \"$__h_old\" ]; then "
            + "__h_v=$(PATH=\"${__h_lp:+$__h_lp:}$PATH\"; node -p process.versions.node </dev/null 2>/dev/null); "
            + "if [ \"${__h_v%%.*}\" -ge \(minimumMajorVersion) ] 2>/dev/null; then "
            + "printf \"%s%s\\n\" \(npmMissingMarker) \"$__h_v\" >&2; exit \(failureExitStatus); fi; "
            + "__h_old=\"$__h_v\"; fi; "
            + "if [ -n \"$__h_old\" ]; then printf \"%s%s\\n\" \(tooOldMarker) \"$__h_old\" >&2; "
            + "else printf \"%s\\n\" \(missingMarker) >&2; fi; exit \(failureExitStatus); fi",
        "PATH=\"$__h_npm:$PATH\"; export PATH",
    ]).map { $0 + "; " }.joined()

    /// The same search for a program that needs only Node.js, as the Host
    /// Helper does (ADR 0033). It prints one line: `node <absolute path>`,
    /// which a service names; `node-old <version>`; or `node-missing`. It always
    /// exits 0 and leaves the caller's `PATH` alone, so run it in a subshell.
    ///
    /// A directory counts only when the binary its `node` runs sits in a
    /// Node.js install's `bin` under a Node.js name: `node`, `nodejs`, or a
    /// versioned one, as Fedora's `/usr/bin/node` leads to `node-22`. So
    /// another program's private runtime, such as cursor-agent's
    /// `dist-package/node` behind a mise shim, is passed over before its
    /// version is read. The path printed is a manager's own stable link where
    /// the search found one (fnm's default alias, Homebrew's `bin`,
    /// `/usr/bin`, whether `PATH` or the fixed list reached it), which follows
    /// that manager's upgrades. Otherwise it is the binary itself: a shim
    /// (mise, Volta, asdf, nodenv, proto) cannot run under a service, and any
    /// other directory from `PATH` or the login shell can be one shell's own,
    /// as fnm's per-shell links are.
    static let nodeOnlyScript = ([
        "__h_npm=",
        "__h_old=",
        "__h_at=",
        "__h_try() { [ -z \"$__h_npm\" ] || return 0; [ -n \"$1\" ] && [ -x \"$1/node\" ] || return 1; "
            + "__h_p=\"$1${2:+:$2}\"; "
            + "__h_e=$(PATH=\"$__h_p:$PATH\"; node -p process.execPath </dev/null 2>/dev/null) || return 1; "
            + "case \"${__h_e%/*}\" in /*/bin) ;; *) return 1 ;; esac; "
            + "case \"${__h_e##*/}\" in node|nodejs|node[0-9]*|node-[0-9]*|nodejs[0-9]*|nodejs-[0-9]*) ;; "
            + "*) return 1 ;; esac; "
            + "__h_v=$(PATH=\"$__h_p:$PATH\"; node -p process.versions.node </dev/null 2>/dev/null) "
            + "|| return 1; "
            + "if ! [ \"${__h_v%%.*}\" -ge \(minimumMajorVersion) ] 2>/dev/null; then "
            + "[ -n \"$__h_old\" ] || __h_old=\"$__h_v\"; return 1; fi; "
            + "__h_npm=\"$__h_p\"; __h_at=\"$__h_e\"; "
            + "if [ \"$3\" = keep ]; then case \"$1\" in /*) __h_at=\"$1/node\" ;; esac; fi; }",
    ] + searches + [
        "if [ -n \"$__h_npm\" ]; then printf \"node %s\\n\" \"$__h_at\"; "
            + "elif [ -n \"$__h_old\" ]; then printf \"node-old %s\\n\" \"$__h_old\"; "
            + "else printf \"node-missing\\n\"; fi",
    ]).map { $0 + "; " }.joined()

    /// Homebrew's, with its versioned formulae, Nix's profiles, snap's and
    /// MacPorts' directories, `/usr/local/bin` and `/usr/bin`: each keeps its
    /// `node` in place across its manager's upgrades, as Fedora's and
    /// openSUSE's `/usr/bin/node` is the alternatives link to the current
    /// versioned binary, and none is one shell's own, so they are named as
    /// found however the search reaches them.
    private static let stableDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin",
        "/opt/homebrew/opt/node*/bin", "/usr/local/opt/node*/bin", "/home/linuxbrew/.linuxbrew/opt/node*/bin",
        "\"$HOME/.nix-profile/bin\"", "\"/etc/profiles/per-user/$USER/bin\"", "/run/current-system/sw/bin",
        "/nix/var/nix/profiles/default/bin", "/snap/bin", "/opt/local/bin", "/usr/bin",
    ]

    /// Tries each common install method's directory, in the order the type's
    /// documentation gives. A third word `keep` marks a link its manager keeps
    /// in place across versions, which only ``nodeOnlyScript`` reads.
    private static let searches = [
        "__h_data=\"${XDG_DATA_HOME:-$HOME/.local/share}\"",
        "__h_try \"${MISE_DATA_DIR:-$__h_data/mise}/shims\"",
        "__h_try \"${VOLTA_HOME:-$HOME/.volta}/bin\"",
        // fnm keeps its default version as an alias directory.
        "for __h_d in \"$FNM_DIR\" \"$__h_data/fnm\" \"$HOME/Library/Application Support/fnm\" "
            + "\"$HOME/.fnm\"; do [ -n \"$__h_d\" ] && __h_try \"$__h_d/aliases/default/bin\" \"\" keep; done",
        // nvm resolves its own default alias (lts/*, node, 22, …); without
        // one, any installed version will do.
        "__h_nvm=\"${NVM_DIR:-$HOME/.nvm}\"",
        "if [ -z \"$__h_npm\" ] && [ -s \"$__h_nvm/nvm.sh\" ]; then "
            + "__h_node=$(NVM_DIR=\"$__h_nvm\"; export NVM_DIR; . \"$__h_nvm/nvm.sh\" >/dev/null 2>&1; "
            + "nvm which default 2>/dev/null </dev/null); "
            + "case \"$__h_node\" in /*) __h_try \"${__h_node%/*}\";; esac; fi",
        "for __h_d in \"$__h_nvm\"/versions/node/v*/bin; do __h_try \"$__h_d\"; done",
        // asdf's shims run `asdf` from PATH.
        "__h_try \"${ASDF_DATA_DIR:-$HOME/.asdf}/shims\" \"${ASDF_DIR:-$HOME/.asdf}/bin\"",
        "__h_try \"${NODENV_ROOT:-$HOME/.nodenv}/shims\"",
        "__h_try \"${NVS_HOME:-$HOME/.nvs}/default/bin\" \"\" keep",
        "__h_try \"$HOME/.nodebrew/current/bin\" \"\" keep",
        "__h_try \"${N_PREFIX:-$HOME/n}/bin\" \"\" keep",
        "__h_try \"${PROTO_HOME:-$HOME/.proto}/shims\"",
        "for __h_d in \"$PNPM_HOME\" \"$HOME/Library/pnpm\" \"$__h_data/pnpm\"; do __h_try \"$__h_d\" \"\" keep; done",
        // Each directory on PATH in turn, Homebrew's, the system's and the
        // app's PATH prefixes among them, so one passed over leaves the rest
        // to try. Then Homebrew itself for a launcher, which gets no
        // prefixes, its versioned formulae, which it keeps off PATH, and the
        // rest.
        eachDirectory(of: "$PATH", with: ""),
        "for __h_d in \(stableDirectories.joined(separator: " ")); do __h_try \"$__h_d\" \"\" keep; done",
        // Last, each directory on the login shell's own PATH, from its rc
        // files, with that PATH kept whole after it because shims there may
        // need other tools on it (asdf 0.16 runs `asdf`). `env` prints it
        // the same way from all four shells. The output goes to a file, so
        // a process the setup leaves behind cannot hold the exec open, and a
        // watchdog ends a setup that waits, with the commands it started
        // directly (shells without a terminal have no job control to end the
        // rest). The watchdog takes its own `sleep` with it when it is not
        // needed.
        "if [ -z \"$__h_npm\" ] && [ -n \"$SHELL\" ]; then case \"${SHELL##*/}\" in bash|zsh|fish|ksh) "
            + "__h_f=$(mktemp 2>/dev/null) && { "
            + "\"$SHELL\" -lic /usr/bin/env </dev/null >\"$__h_f\" 2>/dev/null & __h_s=$!; "
            + "( sleep \(loginShellSeconds) & __h_z=$!; trap \"kill $__h_z; exit\" TERM; wait \"$__h_z\"; "
            + "pkill -9 -P \"$__h_s\"; kill -9 \"$__h_s\" ) </dev/null >/dev/null 2>&1 & __h_w=$!; "
            + "{ wait \"$__h_s\"; kill \"$__h_w\"; wait \"$__h_w\"; } 2>/dev/null; "
            + "__h_lp=$(sed -n \"s/^PATH=//p\" \"$__h_f\" | tail -n 1 | tr -d \"\\r\"); rm -f \"$__h_f\"; "
            + eachDirectory(of: "$__h_lp", with: "$__h_lp") + "; }; ;; esac; fi",
    ]

    /// Tries each absolute directory on the `:`-separated `list` in order,
    /// with `extra` after it, until one is chosen. One of
    /// ``stableDirectories`` keeps its link however the search reaches it.
    /// The list is split by hand, leaving `IFS`, globbing and a launcher's
    /// positional parameters alone.
    private static func eachDirectory(of list: String, with extra: String) -> String {
        "__h_r=\"\(list):\"; while [ -n \"$__h_r\" ] && [ -z \"$__h_npm\" ]; do "
            + "__h_d=\"${__h_r%%:*}\"; __h_r=\"${__h_r#*:}\"; case \"$__h_d\" in "
            + "\(stableDirectories.joined(separator: "|"))) __h_try \"$__h_d\" \"\(extra)\" keep ;; "
            + "/*) __h_try \"$__h_d\" \"\(extra)\" ;; esac; done"
    }
}

/// Why a plugin install stopped before herdr ran: the probe's marker in
/// what the step printed.
enum NodeToolchainProblem: Equatable, Sendable {
    case missing
    case tooOld(version: String)
    case npmMissing(nodeVersion: String)

    init?(exitStatus: Int32, output: String) {
        guard exitStatus == NodeToolchainProbe.failureExitStatus else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            if line == NodeToolchainProbe.missingMarker {
                self = .missing
                return
            }
            if line.hasPrefix(NodeToolchainProbe.tooOldMarker) {
                self = .tooOld(version: String(line.dropFirst(NodeToolchainProbe.tooOldMarker.count)))
                return
            }
            if line.hasPrefix(NodeToolchainProbe.npmMissingMarker) {
                self = .npmMissing(
                    nodeVersion: String(line.dropFirst(NodeToolchainProbe.npmMissingMarker.count)))
                return
            }
        }
        return nil
    }
}
