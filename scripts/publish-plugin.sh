#!/usr/bin/env bash
#
# Publish the herdr plugin to the `plugin` branch. Driven by `make plugin`;
# see docs/guides/releasing.md.
#
# Development and tests stay in main's plugin/. The plugin branch only ever
# receives commits made here: plugin/'s runtime files plus the repository
# LICENSE, at the branch root, so `herdr plugin install` fetches the plugin
# instead of the whole repository. Each publish appends one commit and never
# rewrites the branch, so earlier versions stay installable with --ref <sha>.
#
# The tree is assembled from a commit on main with git plumbing, never from
# the working tree: local edits cannot leak into it, and the checkout, its
# index and its branch are left alone.
#
# Independent of the app release: `make publish` and release.yml never call
# this script.
#
# Options arrive as environment variables, as in scripts/publish.sh.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REMOTE="origin"
DEFAULT_BRANCH="main"
PLUGIN_BRANCH="plugin"
PLUGIN_DIR="plugin"
# Every entry of plugin/ belongs to exactly one list, so a new entry is a
# decision rather than a silent omission or an accidental upload.
SHIPPED="herdr-plugin.toml package.json package-lock.json README.md src"
DEV_ONLY="test test-vectors"
# Repository tools the plugin tests run, placed where they sit on main.
TEST_TOOLS="scripts/generate-usage-pricing.mjs"

SOURCE="${SOURCE:-}"
DRY_RUN="${DRY_RUN:-}"
YES="${YES:-}"

die() { printf 'plugin: %s\n' "$*" >&2; exit 1; }

work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT

listed() {
    local word
    for word in $2; do
        [ "$word" = "$1" ] && return 0
    done
    return 1
}

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

manifest_version() {
    git show "$1:herdr-plugin.toml" | awk -F'"' '/^\[/ { exit } /^version *=/ { print $2; exit }'
}

# --- Preflight ---------------------------------------------------------------

for tool in git node npm tar awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

main_ref="refs/remotes/$REMOTE/$DEFAULT_BRANCH"
plugin_ref="refs/remotes/$REMOTE/$PLUGIN_BRANCH"

git fetch --quiet "$REMOTE" "+refs/heads/$DEFAULT_BRANCH:$main_ref" \
    || die "git fetch $REMOTE $DEFAULT_BRANCH failed"
parent=""
# A failed lookup must not read as "no branch yet" and plan an orphan.
published_head="$(git ls-remote --heads "$REMOTE" "refs/heads/$PLUGIN_BRANCH")" \
    || die "git ls-remote $REMOTE failed"
if [ -n "$published_head" ]; then
    git fetch --quiet "$REMOTE" "+refs/heads/$PLUGIN_BRANCH:$plugin_ref" \
        || die "git fetch $REMOTE $PLUGIN_BRANCH failed"
    parent="$(git rev-parse "$plugin_ref")"
fi

source="$(git rev-parse --verify --quiet "${SOURCE:-$main_ref}^{commit}")" \
    || die "SOURCE '$SOURCE' does not name a commit"
# The commit message cites the source, so it must be one everybody can see.
git merge-base --is-ancestor "$source" "$main_ref" \
    || die "$source is not on $REMOTE/$DEFAULT_BRANCH; the plugin is published from $DEFAULT_BRANCH"

# --- Tree --------------------------------------------------------------------

listing="$(git ls-tree "$source:$PLUGIN_DIR" 2>/dev/null)" \
    || die "$source has no $PLUGIN_DIR/ directory"
entries=""
while IFS= read -r line; do
    name="${line#*$'\t'}"
    if listed "$name" "$SHIPPED"; then
        entries="$entries$line"$'\n'
    elif ! listed "$name" "$DEV_ONLY"; then
        die "$PLUGIN_DIR/$name is neither shipped nor dev-only; add it to SHIPPED or DEV_ONLY in scripts/publish-plugin.sh"
    fi
done <<<"$listing"
for name in $SHIPPED; do
    printf '%s' "$entries" | grep -q $'\t'"$name\$" || die "$source has no $PLUGIN_DIR/$name"
done
license="$(git ls-tree "$source" LICENSE)"
[ -n "$license" ] || die "$source has no LICENSE"
tree="$(printf '%s%s\n' "$entries" "$license" | git mktree)"

# --- Version -----------------------------------------------------------------

version="$(manifest_version "$tree")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "$PLUGIN_DIR/herdr-plugin.toml version '$version' is not X.Y.Z"
package_version="$(git show "$tree:package.json" \
    | node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).version')"
[ "$package_version" = "$version" ] \
    || die "$PLUGIN_DIR/herdr-plugin.toml says $version but $PLUGIN_DIR/package.json says $package_version"

published_version=""
if [ -n "$parent" ]; then
    if [ "$(git rev-parse "$parent^{tree}")" = "$tree" ]; then
        printf '%s/%s already has %s from %s; nothing to publish.\n' \
            "$REMOTE" "$PLUGIN_BRANCH" "$version" "$(git rev-parse --short=12 "$source")"
        exit 0
    fi
    published_version="$(manifest_version "$parent")"
    [[ "$published_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "$REMOTE/$PLUGIN_BRANCH has version '$published_version', which is not X.Y.Z"
    # Heeler compares versions to tell users their plugin is outdated, so new
    # content under an old number would never reach them.
    version_gt "$version" "$published_version" \
        || die "$version is not newer than the published $published_version; bump version in $PLUGIN_DIR/herdr-plugin.toml and $PLUGIN_DIR/package.json"
fi

# --- Checks ------------------------------------------------------------------

# Install exactly what herdr will fetch, then run the suite against it.
work="$(mktemp -d)"
check="$work/plugin"
mkdir "$check"
log="$work/check.log"
git archive "$tree" | tar -x -C "$check"

# The output only matters when a step fails; otherwise it buries the plan.
quietly() { (cd "$check" && "$@") >"$log" 2>&1 || { cat "$log" >&2; return 1; }; }

echo "==> Checking the published tree"
quietly npm ci --no-audit --no-fund || die "npm ci failed in the published tree"
for file in "$check"/src/*.js; do
    node --check "$file" || die "${file#"$check"/} does not parse"
done
# shellcheck disable=SC2086 # DEV_ONLY is a word list
git archive "$source:$PLUGIN_DIR" $DEV_ONLY | tar -x -C "$check"
# shellcheck disable=SC2086 # TEST_TOOLS is a word list
git archive "$source" $TEST_TOOLS | tar -x -C "$work"
quietly npm test || die "plugin tests failed against the published tree"

# --- Plan --------------------------------------------------------------------

row() { printf '  %-10s %s\n' "$1" "$2"; }

subject="chore(plugin): publish $version"
source_short="$(git rev-parse --short=12 "$source")"

printf '\nPublish plugin %s to %s/%s\n\n' "$version" "$REMOTE" "$PLUGIN_BRANCH"
row "source" "$source_short $(git log -1 --format=%s "$source")"
if [ -n "$parent" ]; then
    row "parent" "$(git rev-parse --short=12 "$parent") ($published_version)"
else
    row "parent" "none: creates $PLUGIN_BRANCH on $REMOTE as an orphan branch"
fi
row "checks" "npm ci, node --check src, npm test: passed"
row "commit" "$subject"
row "push" "git push $REMOTE <commit>:refs/heads/$PLUGIN_BRANCH (fast-forward only)"
echo
if [ -n "$parent" ]; then
    echo "Changes:"
    git diff --stat "$parent" "$tree" | sed 's/^/  /'
else
    echo "Files:"
    git ls-tree -r --name-only "$tree" | sed 's/^/  /'
fi
echo

if [ -n "$DRY_RUN" ]; then
    echo "DRY_RUN=1 — nothing was pushed."
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

message="$subject

Built from $PLUGIN_DIR/ at $source on $DEFAULT_BRANCH."
# shellcheck disable=SC2086 # an empty parent adds no -p
commit="$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "$message")"

# Never forced: a publish that raced another one is rejected as a
# non-fast-forward, and the next run builds on top of it.
git push "$REMOTE" "$commit:refs/heads/$PLUGIN_BRANCH" \
    || die "push failed; nothing was published. Run make plugin again."

printf '\nPublished plugin %s as %s on %s/%s.\n' \
    "$version" "$(git rev-parse --short=12 "$commit")" "$REMOTE" "$PLUGIN_BRANCH"
