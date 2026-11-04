#!/usr/bin/env bash
# Tests scripts/publish-plugin.sh, and scripts/check-plugin-published.sh,
# which make publish runs, against a throwaway repository and remote.
# A fake npm stands in for the network; node is real.
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat >"$work/bin/npm" <<'EOF'
#!/bin/sh
case "$1" in
    ci)
        [ ! -e test ] || { echo "npm ci ran with test/ present" >&2; exit 1; }
        mkdir -p node_modules ;;
    test)
        [ -e test ] || { echo "npm test ran without test/" >&2; exit 1; }
        [ -e ../scripts/generate-usage-pricing.mjs ] \
            || { echo "npm test ran without the price generator" >&2; exit 1; }
        exit "${FAKE_NPM_TEST_STATUS:-0}" ;;
esac
EOF
chmod +x "$work/bin/npm"
PATH="$work/bin:$PATH"

git init --quiet --bare "$work/remote.git"
git init --quiet "$work/repo"
cd "$work/repo"
git symbolic-ref HEAD refs/heads/main
git config user.name test
git config user.email test@invalid
git config commit.gpgsign false
mkdir -p plugin/src plugin/test plugin/test-vectors scripts Sources
cp "$scripts/publish-plugin.sh" "$scripts/check-plugin-published.sh" scripts/
echo '// generator' > scripts/generate-usage-pricing.mjs
echo 'Apache License' > LICENSE
echo 'let a = 1' > Sources/App.swift
printf 'id = "heeler"\nversion = "0.1.0"\n\n[[build]]\ncommand = ["npm", "ci"]\n' > plugin/herdr-plugin.toml
printf '{"name": "heeler-pairing", "version": "0.1.0", "private": true}\n' > plugin/package.json
echo '{}' > plugin/package-lock.json
echo '# heeler' > plugin/README.md
echo 'export const answer = 1;' > plugin/src/index.js
echo 'import "../src/index.js";' > plugin/test/index.test.js
echo '{}' > plugin/test-vectors/vector.json
git add .
git commit --quiet --message initial
git remote add origin "$work/remote.git"
git push --quiet origin main
first_main=$(git rev-parse HEAD)

failures=0
pass() { echo "ok - $1"; }
fail() {
    echo "not ok - $1"
    sed 's/^/    /' "$work/out"
    failures=$((failures + 1))
}

# Runs the script with the given environment; the status lands in $status.
publish() {
    status=0
    env "$@" bash scripts/publish-plugin.sh >"$work/out" 2>&1 || status=$?
}

expect_refused() {
    description=$1
    message=$2
    shift 2
    before=$(published rev-parse --verify --quiet plugin)
    publish "$@"
    after=$(published rev-parse --verify --quiet plugin)
    if [ "$status" -ne 0 ] && grep -qF "$message" "$work/out" && [ "$before" = "$after" ]; then
        pass "$description"
    else
        fail "$description: expected a refusal mentioning '$message' that leaves the branch alone"
    fi
}

# Reads the remote; a missing branch reads as empty so every case still reports.
published() { git --git-dir "$work/remote.git" "$@" 2>/dev/null || true; }

# The app release check: passes with the version, or fails with a message.
expect_check() {
    description=$1
    expected=$2
    status=0
    bash scripts/check-plugin-published.sh >"$work/out" 2>&1 || status=$?
    if case "$expected" in
        pass:*) [ "$status" -eq 0 ] && [ "$(cat "$work/out")" = "${expected#pass:}" ] ;;
        *) [ "$status" -ne 0 ] && grep -qF "$expected" "$work/out" ;;
    esac; then
        pass "$description"
    else
        fail "$description: expected '$expected'"
    fi
}

# Local work must not leak into the published tree: neither an unpushed
# commit nor an uncommitted edit.
echo 'export const answer = 2;' > plugin/src/index.js
git commit --quiet --all --message unpushed
unpushed=$(git rev-parse HEAD)
echo 'export const answer = 3;' > plugin/src/index.js

publish DRY_RUN=1
if [ "$status" -eq 0 ] && grep -qF "creates plugin on origin as an orphan branch" "$work/out" \
    && [ -z "$(published rev-parse --verify --quiet plugin)" ]; then
    pass "a dry run plans the orphan branch and pushes nothing"
else
    fail "a dry run plans the orphan branch and pushes nothing"
fi

expect_check "the app release check fails before the first publish" \
    "origin has no plugin branch; publish plugin 0.1.0 with make plugin first"

publish YES=1
files=$(published ls-tree -r --name-only plugin | tr '\n' ' ')
expected_files="LICENSE README.md herdr-plugin.toml package-lock.json package.json src/index.js "
if [ "$status" -eq 0 ] && [ "$files" = "$expected_files" ]; then
    pass "the first publish ships the runtime files and LICENSE at the branch root"
else
    fail "the first publish ships the runtime files and LICENSE at the branch root: got '$files'"
fi
if [ "$(published rev-list --count plugin)" = 1 ]; then
    pass "the first publish creates an orphan branch"
else
    fail "the first publish creates an orphan branch"
fi
if [ "$(published show plugin:src/index.js)" = 'export const answer = 1;' ]; then
    pass "the tree comes from origin/main, not local commits or edits"
else
    fail "the tree comes from origin/main, not local commits or edits"
fi
message=$(published log -1 --format=%B plugin)
if [ "$(printf '%s\n' "$message" | head -1)" = "chore(plugin): publish 0.1.0" ] \
    && printf '%s' "$message" | grep -qF "$first_main"; then
    pass "the commit names the version and the source commit"
else
    fail "the commit names the version and the source commit: got '$message'"
fi
first_publish=$(published rev-parse plugin)
expect_check "the app release check passes once the version is published" "pass:0.1.0"

publish YES=1
if [ "$status" -eq 0 ] && grep -qF "nothing to publish" "$work/out" \
    && [ "$(published rev-parse plugin)" = "$first_publish" ]; then
    pass "an unchanged tree publishes nothing"
else
    fail "an unchanged tree publishes nothing"
fi

expect_refused "a source that is not on origin/main is refused" \
    "is not on origin/main" YES=1 SOURCE="$unpushed"

git reset --quiet --hard "$first_main"
echo 'export const answer = 4;' > plugin/src/index.js
git commit --quiet --all --message "change without a bump"
git push --quiet origin main
expect_refused "new content under the published version is refused" \
    "0.1.0 is not newer than the published 0.1.0" YES=1

sed -i.bak 's/0\.1\.0/0.2.0/' plugin/herdr-plugin.toml && rm plugin/herdr-plugin.toml.bak
git commit --quiet --all --message "bump the manifest only"
git push --quiet origin main
expect_refused "a manifest and package.json that disagree are refused" \
    "herdr-plugin.toml says 0.2.0 but plugin/package.json says 0.1.0" YES=1

sed -i.bak 's/0\.1\.0/0.2.0/' plugin/package.json && rm plugin/package.json.bak
git commit --quiet --all --message "bump package.json"
git push --quiet origin main
expect_refused "failing plugin tests stop the publish" \
    "plugin tests failed" YES=1 FAKE_NPM_TEST_STATUS=1
expect_check "the app release check fails while a bumped version is unpublished" \
    "origin/plugin has plugin 0.1.0, but this release bundles 0.2.0"

publish YES=1
if [ "$status" -eq 0 ] && [ "$(published rev-parse plugin^)" = "$first_publish" ] \
    && [ "$(published show plugin:herdr-plugin.toml | grep '^version')" = 'version = "0.2.0"' ]; then
    pass "a newer version appends one commit to the branch"
else
    fail "a newer version appends one commit to the branch"
fi
expect_check "the app release check passes after publishing the bump" "pass:0.2.0"

echo 'registry=https://example.invalid' > plugin/.npmrc
git add plugin/.npmrc
git commit --quiet --message "add an unlisted file"
git push --quiet origin main
expect_refused "an entry that is neither shipped nor dev-only is refused" \
    "plugin/.npmrc is neither shipped nor dev-only" YES=1

if [ "$failures" -ne 0 ]; then
    echo "$failures plugin publishing test(s) failed" >&2
    exit 1
fi
