#!/usr/bin/env bash
#
# Publish `heeler-pair` to npm. Driven by `make pair-cli`; see
# docs/guides/releasing.md.
#
# The package is plugin/pair-cli's manifest and README over plugin/src, of
# which the manifest's `files` names the modules the command loads (ADR 0057).
# It is assembled from a commit on main with git archive, never from the
# working tree, so local edits cannot leak into it. Its version is its own:
# a release of the command does not make the app ask Herdr TUI Hosts to
# update their plugin.
#
# Options arrive as environment variables, as in scripts/publish-plugin.sh.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REMOTE="origin"
DEFAULT_BRANCH="main"
PLUGIN_DIR="plugin"
PACKAGE_DIR="plugin/pair-cli"
# A mirror set for installs must not receive the publish or answer for it.
REGISTRY="https://registry.npmjs.org/"

SOURCE="${SOURCE:-}"
DRY_RUN="${DRY_RUN:-}"
YES="${YES:-}"

die() { printf 'pair-cli: %s\n' "$*" >&2; exit 1; }

work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT

# The 0-based component of an X.Y.Z version.
component() {
    local IFS=.
    # shellcheck disable=SC2206 # splitting on dots is the point
    local parts=($1)
    printf '%s' "$((10#${parts[$2]}))"
}

version_gt() {
    local i
    for i in 0 1 2; do
        [ "$(component "$1" "$i")" -gt "$(component "$2" "$i")" ] && return 0
        [ "$(component "$1" "$i")" -lt "$(component "$2" "$i")" ] && return 1
    done
    return 1
}

field() { node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]]' "$1" "$2"; }

# --- Preflight ---------------------------------------------------------------

for tool in git node npm tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

main_ref="refs/remotes/$REMOTE/$DEFAULT_BRANCH"
git fetch --quiet "$REMOTE" "+refs/heads/$DEFAULT_BRANCH:$main_ref" \
    || die "git fetch $REMOTE $DEFAULT_BRANCH failed"
source="$(git rev-parse --verify --quiet "${SOURCE:-$main_ref}^{commit}")" \
    || die "SOURCE '$SOURCE' does not name a commit"
# A branch can be looked at; only main is published.
if ! git merge-base --is-ancestor "$source" "$main_ref"; then
    [ -n "$DRY_RUN" ] \
        || die "$source is not on $REMOTE/$DEFAULT_BRANCH; heeler-pair is published from $DEFAULT_BRANCH"
fi

# --- Package -----------------------------------------------------------------

work="$(mktemp -d)"
tree="$work/tree"
package="$work/package"
mkdir "$tree" "$package"
git archive "$source" "$PACKAGE_DIR" "$PLUGIN_DIR/src" LICENSE 2>/dev/null | tar -x -C "$tree" \
    || die "$source has no $PACKAGE_DIR/, $PLUGIN_DIR/src/ or LICENSE"
cp "$tree/$PACKAGE_DIR/package.json" "$tree/$PACKAGE_DIR/README.md" "$tree/LICENSE" "$package/"
cp -R "$tree/$PLUGIN_DIR/src" "$package/src"

name="$(field "$package/package.json" name)"
version="$(field "$package/package.json" version)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$PACKAGE_DIR/package.json version '$version' is not X.Y.Z"

# A failed lookup must not read as "never published".
published=""
if ! published="$(npm view "$name" version --registry "$REGISTRY" 2>"$work/view.log")"; then
    grep -q 'E404' "$work/view.log" || { cat "$work/view.log" >&2; die "npm view $name failed"; }
    published=""
fi
if [ -n "$published" ]; then
    version_gt "$version" "$published" \
        || die "$version is not newer than the published $published; bump version in $PACKAGE_DIR/package.json"
fi

# --- Checks ------------------------------------------------------------------

log="$work/check.log"
# The output only matters when a step fails; otherwise it buries the plan.
quietly() { "$@" >"$log" 2>&1 || { cat "$log" >&2; return 1; }; }

echo "==> Checking the package"
tarball="$(cd "$package" && npm pack --silent)" || die "npm pack failed"
tarball="$package/$tarball"
# Install the tarball as npx would, then start what it installed.
install="$work/install"
mkdir "$install"
printf '{"private":true}\n' >"$install/package.json"
(cd "$install" && quietly npm install --no-audit --no-fund --registry "$REGISTRY" "$tarball") \
    || die "the packed tarball does not install"
installed="$install/node_modules/$name"
bin="$install/node_modules/.bin/$name"
# Every static import loads before the first statement, so this starts the
# whole command.
answer="$("$bin" --version)" || die "the installed command does not start"
[ "$answer" = "$name $version" ] || die "the installed command answered '$answer', not '$name $version'"
# sshd starts the Enrollment entrypoint by path; with no pairing to accept
# it answers in its protocol, which proves its own imports load.
refusal="$(HOME="$work" node "$installed/src/pair-accept.js" \
    --state-dir "$work/state" --pairing-id none </dev/null 2>/dev/null || true)"
[ "$refusal" = "HERDR-ENROLL:ERR:unknown_pairing" ] \
    || die "the installed Enrollment entrypoint answered '$refusal'"

# --- Plan --------------------------------------------------------------------

row() { printf '  %-10s %s\n' "$1" "$2"; }

printf '\nPublish %s %s to %s\n\n' "$name" "$version" "$REGISTRY"
row "source" "$(git rev-parse --short=12 "$source") $(git log -1 --format=%s "$source")"
row "published" "${published:-none: this creates the package}"
row "checks" "npm pack, install, --version, Enrollment entrypoint: passed"
echo
echo "Files:"
tar -tzf "$tarball" | sed 's/^package\//  /' | sort
echo

if [ -n "$DRY_RUN" ]; then
    echo "DRY_RUN=1 — nothing was published."
    exit 0
fi

if [ -z "$YES" ]; then
    [ -e /dev/tty ] || die "no terminal to confirm on; re-run with YES=1 after reviewing DRY_RUN=1"
    printf 'Proceed? [y/N] '
    read -r reply </dev/tty || reply=""
    case "$reply" in
        [yY] | [yY][eE][sS]) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# --- Ship --------------------------------------------------------------------

# A version cannot be published twice, and one that was published cannot be
# taken back after 72 hours.
npm publish "$tarball" --access public --registry "$REGISTRY" \
    || die "npm publish failed; run 'npm login' as the package's owner and try again"

printf '\nPublished %s %s.\n' "$name" "$version"
