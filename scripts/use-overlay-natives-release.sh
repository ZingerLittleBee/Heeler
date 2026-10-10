#!/usr/bin/env bash
# Points HeelerOverlay at a published heeler-overlay-natives release and
# syncs its notices:
#
#   scripts/use-overlay-natives-release.sh 1.0.0
#
# 1. Packages/HeelerOverlay/Package.swift: the dependency becomes
#    .package(url: "https://github.com/Ylarod/heeler-overlay-natives.git", exact: "<version>")
#    (from the sibling-checkout path dependency or an earlier exact version).
# 2. Downloads the release's Notices.zip, checks it against the release's
#    SHA256SUMS, and copies its notices into Sources/Heeler/Resources/Notices.
# 3. Resolves the packages, which records heeler-overlay-natives in
#    Heeler.xcodeproj/.../Package.resolved.
#
# It neither commits nor pushes. Review the diff (notices, inventory.json
# versions when a component moved, CHANGELOG), run the tests named in
# Packages/HeelerOverlay/README.md, then commit.

set -euo pipefail

version=${1:-}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <version>   (for example 1.0.0; the release tag is v<version>)" >&2
    exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repository=https://github.com/Ylarod/heeler-overlay-natives
manifest="$repo_root/Packages/HeelerOverlay/Package.swift"
notices="$repo_root/Sources/Heeler/Resources/Notices"
release="$repository/releases/download/v$version"

work=$(mktemp -d -t heeler-overlay-natives.XXXXXX)
trap 'rm -rf "$work"' EXIT

fetch() {
    curl --fail --location --silent --show-error \
        --connect-timeout 20 --speed-time 30 --speed-limit 1024 \
        --retry 3 --retry-all-errors --output "$work/$1" "$release/$1"
}

echo "==> heeler-overlay-natives v$version"
fetch SHA256SUMS
fetch Notices.zip
expected=$(awk '$2 == "Notices.zip" { print $1 }' "$work/SHA256SUMS")
actual=$(shasum -a 256 "$work/Notices.zip" | awk '{ print $1 }')
if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "Notices.zip does not match the release's SHA256SUMS ($actual, expected ${expected:-none})" >&2
    exit 1
fi

echo "==> Package.swift"
python3 - "$manifest" "$version" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
source = open(path, encoding="utf-8").read()
dependency = re.compile(
    r'let nativesDependency: Package\.Dependency =\n\s*\.package\((?:path: "[^"]*"'
    r'|url: "https://github\.com/Ylarod/heeler-overlay-natives\.git", exact: "[^"]*")\)\n')
comment = re.compile(r'// TODO\(heeler-overlay-natives 1\.0\.0\):.*?// Always depend on an exact release; never on a branch or a range\.\n',
                     re.S)
if not dependency.search(source):
    sys.exit("Package.swift: no nativesDependency declaration to replace")
source = comment.sub(
    "// Upgrade with `scripts/use-overlay-natives-release.sh <version>` (repository\n"
    "// root). Always depend on an exact release; never on a branch or a range.\n",
    source)
source = dependency.sub(
    'let nativesDependency: Package.Dependency =\n'
    f'    .package(url: "https://github.com/Ylarod/heeler-overlay-natives.git", exact: "{version}")\n',
    source)
open(path, "w", encoding="utf-8").write(source)
PY

echo "==> notices"
unzip -q "$work/Notices.zip" -d "$work/release"
count=0
for notice in "$work"/release/Notices/*.txt; do
    cp "$notice" "$notices/"
    count=$((count + 1))
done
if [[ "$count" -ne 17 ]]; then
    echo "expected 17 notices in Notices.zip, found $count; update inventory.json and LicenseNoticeTests" >&2
    exit 1
fi

echo "==> resolve"
make -C "$repo_root" resolve

git -C "$repo_root" status --short
cat <<EOF

Now:
  - review the notice diff; bump inventory.json versions of components that moved;
  - cd Packages/HeelerOverlay && xcodebuild test -scheme HeelerOverlay -destination <Simulator>;
  - make test-app TEST_SELECTOR=HeelerTests/LicenseNoticeInventoryTests (and the full suite);
  - commit Package.swift, Package.resolved, and the notices.
EOF
