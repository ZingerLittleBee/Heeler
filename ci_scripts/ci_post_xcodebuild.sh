#!/bin/sh
set -eu

# Only the dedicated Ad Hoc workflow opts in. Other Cloud workflows, including
# TestFlight, never receive the upload credential or publish artifacts here.
[ -n "${ADHOC_PUBLISH_URL:-}" ] || exit 0
[ "${CI_XCODEBUILD_ACTION:-}" = archive ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-1}" = 0 ] || exit 0
: "${CI_AD_HOC_SIGNED_APP_PATH:?Missing Ad Hoc export path}"
: "${CI_PRIMARY_REPOSITORY_PATH:?Missing checkout path}"
cd "$CI_PRIMARY_REPOSITORY_PATH"
make adhoc-publish
