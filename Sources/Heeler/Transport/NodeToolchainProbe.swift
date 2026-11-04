import Foundation

/// Finds the Host's Node.js for a plugin install, whose `npm ci` build runs
/// with the exec's `PATH`. SSH exec reads no interactive shell setup, which
/// is where most Node.js installs put themselves on `PATH`, so the probe
/// looks where each common install method keeps a default `node` and `npm`,
/// in the order an interactive shell usually ends up with: version managers
/// first, then what `PATH` already finds, then system-wide package managers,
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
    static let script = [
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
        "__h_data=\"${XDG_DATA_HOME:-$HOME/.local/share}\"",
        "__h_try \"${MISE_DATA_DIR:-$__h_data/mise}/shims\"",
        "__h_try \"${VOLTA_HOME:-$HOME/.volta}/bin\"",
        // fnm keeps its default version as an alias directory.
        "for __h_d in \"$FNM_DIR\" \"$__h_data/fnm\" \"$HOME/Library/Application Support/fnm\" "
            + "\"$HOME/.fnm\"; do [ -n \"$__h_d\" ] && __h_try \"$__h_d/aliases/default/bin\"; done",
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
        "__h_try \"${NVS_HOME:-$HOME/.nvs}/default/bin\"",
        "__h_try \"$HOME/.nodebrew/current/bin\"",
        "__h_try \"${N_PREFIX:-$HOME/n}/bin\"",
        "__h_try \"${PROTO_HOME:-$HOME/.proto}/shims\"",
        "for __h_d in \"$PNPM_HOME\" \"$HOME/Library/pnpm\" \"$__h_data/pnpm\"; do __h_try \"$__h_d\"; done",
        // Homebrew, the system's packages, and the app's PATH prefixes, then
        // Homebrew itself for a launcher, which gets no prefixes, its
        // versioned formulae, which it keeps off PATH, and the rest.
        "__h_node=$(command -v npm 2>/dev/null) && __h_try \"${__h_node%/*}\"",
        "for __h_d in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin "
            + "/opt/homebrew/opt/node*/bin /usr/local/opt/node*/bin "
            + "/home/linuxbrew/.linuxbrew/opt/node*/bin \"$HOME/.nix-profile/bin\" "
            + "\"/etc/profiles/per-user/$USER/bin\" /run/current-system/sw/bin "
            + "/nix/var/nix/profiles/default/bin /snap/bin /opt/local/bin; do __h_try \"$__h_d\"; done",
        // Last, the login shell's own PATH, from its rc files, kept whole
        // after npm's directory because shims there may need other tools
        // on it (asdf 0.16 runs `asdf`). `env` prints it the same way from
        // all four shells. The output goes to a file, so a process the
        // setup leaves behind cannot hold the exec open, and a watchdog
        // ends a setup that waits, with the commands it started directly
        // (shells without a terminal have no job control to end the rest).
        // The watchdog takes its own `sleep` with it when it is not needed.
        "if [ -z \"$__h_npm\" ] && [ -n \"$SHELL\" ]; then case \"${SHELL##*/}\" in bash|zsh|fish|ksh) "
            + "__h_f=$(mktemp 2>/dev/null) && { "
            + "\"$SHELL\" -lic /usr/bin/env </dev/null >\"$__h_f\" 2>/dev/null & __h_s=$!; "
            + "( sleep \(loginShellSeconds) & __h_z=$!; trap \"kill $__h_z; exit\" TERM; wait \"$__h_z\"; "
            + "pkill -9 -P \"$__h_s\"; kill -9 \"$__h_s\" ) </dev/null >/dev/null 2>&1 & __h_w=$!; "
            + "{ wait \"$__h_s\"; kill \"$__h_w\"; wait \"$__h_w\"; } 2>/dev/null; "
            + "__h_lp=$(sed -n \"s/^PATH=//p\" \"$__h_f\" | tail -n 1 | tr -d \"\\r\"); rm -f \"$__h_f\"; "
            + "__h_node=$(PATH=\"$__h_lp\"; command -v npm 2>/dev/null); "
            + "case \"$__h_node\" in /*) __h_try \"${__h_node%/*}\" \"$__h_lp\";; esac; }; ;; esac; fi",
        // Without an npm, a node alone still says what to fix.
        "if [ -z \"$__h_npm\" ]; then if [ -z \"$__h_old\" ]; then "
            + "__h_v=$(PATH=\"${__h_lp:+$__h_lp:}$PATH\"; node -p process.versions.node </dev/null 2>/dev/null); "
            + "if [ \"${__h_v%%.*}\" -ge \(minimumMajorVersion) ] 2>/dev/null; then "
            + "printf \"%s%s\\n\" \(npmMissingMarker) \"$__h_v\" >&2; exit \(failureExitStatus); fi; "
            + "__h_old=\"$__h_v\"; fi; "
            + "if [ -n \"$__h_old\" ]; then printf \"%s%s\\n\" \(tooOldMarker) \"$__h_old\" >&2; "
            + "else printf \"%s\\n\" \(missingMarker) >&2; fi; exit \(failureExitStatus); fi",
        "PATH=\"$__h_npm:$PATH\"; export PATH",
    ].map { $0 + "; " }.joined()
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
