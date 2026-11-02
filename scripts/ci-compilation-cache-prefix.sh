#!/bin/bash
# Print the actions/cache key prefix for one compiler-cache namespace.
#
# The fast build (ci.yml) and full verification (ci-full.yml) keep separate
# namespaces, but both must invalidate on the same inputs: toolchain,
# Simulator SDK, host architecture, the committed project and package
# manifests, and the build-setting profile below. Identity lines go to
# stdout and IDENTITY_FILE; the prefix goes to $GITHUB_OUTPUT as
# cache-prefix (stdout when run outside Actions).
#
# Usage: scripts/ci-compilation-cache-prefix.sh NAMESPACE [IDENTITY_FILE]
set -euo pipefail
namespace=${1:?usage: ci-compilation-cache-prefix.sh NAMESPACE [IDENTITY_FILE]}
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
identity_file=${2:-}
if [[ -z "$identity_file" ]]; then
    identity_file="$(mktemp "${TMPDIR:-/tmp}/heeler-cache-identity.XXXXXX")"
    trap 'rm -f "$identity_file"' EXIT
fi

# A brace group keeps errexit: a failed probe stops the script instead of
# hashing partial output into a key that never matches.
{
    xcodebuild -version
    xcrun --sdk iphonesimulator --show-sdk-version
    uname -m
    git -C "$repo_root" ls-files -s -- project.yml \
        Heeler.xcodeproj/project.pbxproj \
        Heeler.xcodeproj/xcshareddata/xcschemes/Heeler.xcscheme \
        Heeler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        ':(glob)Packages/**/Package.swift'
    # The build-setting profile both lanes pass. Bump it after changing those
    # settings to start fresh caches; compiled objects stay correct either
    # way because the CAS is content-addressed.
    echo 'Debug-no-symbols-no-index-v1'
} > "$identity_file"
cat "$identity_file"
digest=$(shasum -a 256 "$identity_file" | cut -d ' ' -f 1)
prefix="$namespace-${RUNNER_OS:-local}-${RUNNER_ARCH:-$(uname -m)}-$digest-"
echo "cache-prefix=$prefix" >> "${GITHUB_OUTPUT:-/dev/stdout}"
