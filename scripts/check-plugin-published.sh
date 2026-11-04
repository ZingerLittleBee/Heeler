#!/usr/bin/env bash
#
# Print the plugin version HEAD carries if the plugin branch on origin has
# published it, and fail otherwise. scripts/publish.sh runs this before it
# cuts an app release: the app bundles that version and tells every Host with
# an older plugin to update from the plugin branch, so releasing the app first
# would have them reinstall the old version. `make plugin` publishes it.
#
# Equality is enough: the plugin branch is only published from commits on
# main, and main's plugin version only grows.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REMOTE="origin"
PLUGIN_BRANCH="plugin"

die() { printf 'plugin check: %s\n' "$*" >&2; exit 1; }

manifest_version() {
    git show "$1" | awk -F'"' '/^\[/ { exit } /^version *=/ { print $2; exit }'
}

expected="$(manifest_version HEAD:plugin/herdr-plugin.toml)"
[ -n "$expected" ] || die "HEAD's plugin/herdr-plugin.toml has no version"

plugin_ref="refs/remotes/$REMOTE/$PLUGIN_BRANCH"
heads="$(git ls-remote --heads "$REMOTE" "refs/heads/$PLUGIN_BRANCH")" \
    || die "git ls-remote $REMOTE failed"
[ -n "$heads" ] || die "$REMOTE has no $PLUGIN_BRANCH branch; publish plugin $expected with make plugin first"
git fetch --quiet "$REMOTE" "+refs/heads/$PLUGIN_BRANCH:$plugin_ref" \
    || die "git fetch $REMOTE $PLUGIN_BRANCH failed"

published="$(manifest_version "$plugin_ref:herdr-plugin.toml")"
[ "$published" = "$expected" ] \
    || die "$REMOTE/$PLUGIN_BRANCH has plugin ${published:-no version}, but this release bundles $expected; publish it with make plugin first"

printf '%s\n' "$expected"
