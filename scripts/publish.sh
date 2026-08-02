#!/usr/bin/env bash
#
# Cut a release. Driven by `make publish`; see docs/guides/releasing.md.
#
# CHANGELOG.md is the source. Its [Unreleased] section names what ships and
# becomes the release notes verbatim; every version string elsewhere is
# derived from the version this script resolves.
#
# Publish mode: local build. The archive is signed with the developer's Apple
# credentials and uploaded to App Store Connect, neither of which exists on a
# CI runner, so a tag-triggered workflow cannot produce the artifact. The
# GitHub release therefore carries the notes and the tag only; the build ships
# through TestFlight.
#
# Options arrive as environment variables because make consumes flags of its
# own (--dry-run is make's -n) and rejects unknown long options, so a flag
# never reaches the recipe.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CHANGELOG="CHANGELOG.md"
PROJECT_YML="project.yml"
XCODEPROJ="HerdrMobile.xcodeproj"
DEFAULT_BRANCH="main"
REMOTE="origin"

VERSION="${VERSION:-}"
DRY_RUN="${DRY_RUN:-}"
YES="${YES:-}"

die() { printf 'publish: %s\n' "$*" >&2; exit 1; }

# Tracks how far we got, so a failure can name the right recovery. Anything
# before `mutating` leaves the working tree untouched.
stage="preflight"
notes_file=""
tag=""

on_exit() {
    local code=$?
    if [ -n "$notes_file" ]; then rm -f "$notes_file"; fi
    if [ "$code" -eq 0 ]; then return 0; fi
    case "$stage" in
        mutating)
            printf '\npublish: failed before anything was pushed. Undo the local edits with:\n'
            printf '  git checkout -- %s %s %s\n' "$CHANGELOG" "$PROJECT_YML" "$XCODEPROJ"
            ;;
        tagged)
            printf '\npublish: %s is already pushed — do NOT re-run publish.\n' "$tag"
            printf 'Finish by creating the release against the existing tag:\n'
            printf '  gh release create %s --title %s --notes "<the [%s] section of %s>"\n' \
                "$tag" "$tag" "${tag#v}" "$CHANGELOG"
            ;;
    esac
    return 0
}
trap on_exit EXIT

# --- Preflight ---------------------------------------------------------------

for tool in git gh xcodegen xcodebuild awk sed; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

[ -z "$(git status --porcelain)" ] || die "working tree is not clean"

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "$DEFAULT_BRANCH" ] || die "on branch '$branch', expected '$DEFAULT_BRANCH'"

git rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null || die "no $DEFAULT_BRANCH branch"
git fetch --quiet --tags "$REMOTE"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$REMOTE/$DEFAULT_BRANCH")" ] \
    || die "$DEFAULT_BRANCH differs from $REMOTE/$DEFAULT_BRANCH; pull or push first"

grep -q '^## \[Unreleased\]' "$CHANGELOG" || die "$CHANGELOG has no '## [Unreleased]' heading"

# The [Unreleased] body: everything up to the next '## ' heading.
notes="$(awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
' "$CHANGELOG")"
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] \
    || die "[Unreleased] is empty — there is nothing to release. Entries belong there as they merge."

# Drop the blank line that follows the heading; $( ) already ate the trailing ones.
notes="$(printf '%s\n' "$notes" | awk 'NF == 0 && !seen { next } { seen = 1; print }')"

# --- Version resolution ------------------------------------------------------

# The newest released heading and the newest tag must agree: if they disagree
# one of them is lying, and guessing which is how a release gets cut from the
# wrong base.
released_heading="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | tr -d '#[] ' || true)"
latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"

if [ -n "$released_heading" ] || [ -n "$latest_tag" ]; then
    [ -n "$released_heading" ] || die "git has tag $latest_tag but $CHANGELOG has no released section"
    [ -n "$latest_tag" ] || die "$CHANGELOG has [$released_heading] but there is no matching git tag"
    [ "v$released_heading" = "$latest_tag" ] \
        || die "$CHANGELOG's newest release [$released_heading] disagrees with the newest tag $latest_tag"
fi

if [ -n "$VERSION" ]; then
    version="${VERSION#v}"
    bump_reason="explicit"
elif [ -n "$released_heading" ]; then
    IFS=. read -r major minor patch <<<"$released_heading"
    version="$major.$minor.$((patch + 1))"
    bump_reason="patch bump from $released_heading"
else
    die "no released version to bump from — pass the first version explicitly, e.g. make publish VERSION=0.1.0"
fi

# Prereleases are out of scope for this convention.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$version' is not X.Y.Z"

if grep -q "^## \[$version\]" "$CHANGELOG"; then
    die "$CHANGELOG already has a [$version] section"
fi

tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists locally"
fi
# A local-only check passes right up until the push fails, by which time the
# release commit has already landed.
[ -z "$(git ls-remote --tags "$REMOTE" "refs/tags/$tag")" ] || die "tag $tag already exists on $REMOTE"

# --- Version files -----------------------------------------------------------

marketing_lines="$(grep -c '^ *MARKETING_VERSION:' "$PROJECT_YML" || true)"
build_lines="$(grep -c '^ *CURRENT_PROJECT_VERSION:' "$PROJECT_YML" || true)"
[ "$marketing_lines" -gt 0 ] && [ "$marketing_lines" = "$build_lines" ] \
    || die "$PROJECT_YML has $marketing_lines MARKETING_VERSION and $build_lines CURRENT_PROJECT_VERSION entries; they must pair up"

current_marketing="$(awk -F'"' '/^ *MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
current_build="$(awk -F'"' '/^ *CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
[[ "$current_build" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION '$current_build' is not an integer"
next_build=$((current_build + 1))

today="$(date +%Y-%m-%d)"

# --- Plan --------------------------------------------------------------------

row() { printf '  %-22s %s\n' "$1" "$2"; }

printf '\nPublish %s  (%s)\n\n' "$tag" "$bump_reason"
row "$CHANGELOG" "[Unreleased] -> [$version] - $today, new empty [Unreleased]"
row "$PROJECT_YML" "MARKETING_VERSION $current_marketing -> $version ($marketing_lines targets, in lockstep)"
row "$PROJECT_YML" "CURRENT_PROJECT_VERSION $current_build -> $next_build (App Store Connect rejects reused build numbers)"
row "$XCODEPROJ" 'regenerate via `xcodegen generate`'
echo
row "build" "make archive  (Release, signed locally)"
row "upload" "make upload   (App Store Connect / TestFlight)"
row "commit" "chore: release $tag"
row "push" "$REMOTE $DEFAULT_BRANCH"
row "tag" "$tag (annotated) -> $REMOTE"
row "release" "gh release create (notes only; the build ships via TestFlight)"
printf '\nRelease notes (from %s [Unreleased]):\n' "$CHANGELOG"
printf '%s\n' "$notes" | sed 's/^/  /'
echo

if [ -n "$DRY_RUN" ]; then
    echo "DRY_RUN=1 — nothing was changed."
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

# --- Cut ---------------------------------------------------------------------

stage="mutating"

notes_file="$(mktemp -t heeler-release-notes)"
printf '%s\n' "$notes" >"$notes_file"

awk -v ver="$version" -v today="$today" '
    !cut && /^## \[Unreleased\]/ {
        print "## [Unreleased]"
        print ""
        print "## [" ver "] - " today
        cut = 1
        next
    }
    { print }
' "$CHANGELOG" >"$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"

sed -i '' \
    -e "s/^\( *MARKETING_VERSION: \)\".*\"/\1\"$version\"/" \
    -e "s/^\( *CURRENT_PROJECT_VERSION: \)\".*\"/\1\"$next_build\"/" \
    "$PROJECT_YML"
[ "$(grep -c "^ *MARKETING_VERSION: \"$version\"$" "$PROJECT_YML")" = "$marketing_lines" ] \
    || die "MARKETING_VERSION was not rewritten in all $marketing_lines targets"
[ "$(grep -c "^ *CURRENT_PROJECT_VERSION: \"$next_build\"$" "$PROJECT_YML")" = "$build_lines" ] \
    || die "CURRENT_PROJECT_VERSION was not rewritten in all $build_lines targets"

echo "==> Regenerating $XCODEPROJ"
xcodegen generate

echo "==> Building and uploading to TestFlight"
make archive
make upload

# --- Ship --------------------------------------------------------------------

echo "==> Committing and tagging"
git add "$CHANGELOG" "$PROJECT_YML" "$XCODEPROJ"
git commit -m "chore: release $tag"

# Straight to the default branch on purpose: the commit is mechanical, was
# reviewed in the plan above, and the tag must point at the exact SHA on that
# branch — a PR merge would change it.
git push "$REMOTE" "$DEFAULT_BRANCH"

# Push the commit first: the tag has to point at a commit reviewers can fetch.
git tag -a "$tag" -m "$tag"
git push "$REMOTE" "$tag"
stage="tagged"

echo "==> Creating the GitHub release"
gh release create "$tag" --title "$tag" --notes-file "$notes_file"

# A pushed tag is not a published release.
gh release view "$tag" --json isDraft,tagName --jq 'select(.isDraft == false) | .tagName' \
    | grep -qx "$tag" || die "gh release view $tag does not show a published release"

stage="done"
printf '\nPublished %s. TestFlight processing takes a few more minutes.\n' "$tag"
gh release view "$tag" --json url --jq .url
