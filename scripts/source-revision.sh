#!/bin/sh
# Prints the commit `make archive` records as HeelerSourceRevision, which
# About › Acknowledgements shows and links to as the build's source.
#
# Prints nothing, with a note on stderr, when that commit would not be the
# build's source or could not be found:
# - the tree has uncommitted changes other than `make bump`'s build number;
# - no remote-tracking branch contains HEAD (push it first; the app links to
#   the commit on GitHub).
set -eu

head=$(git rev-parse HEAD)

skip() {
    echo "HeelerSourceRevision left empty: $1" >&2
    exit 0
}

# Untracked files are ignored: the committed project lists every source file.
for changed in $(git diff HEAD --name-only); do
    case "$changed" in
    project.yml | Heeler.xcodeproj/project.pbxproj) ;;
    *) skip "uncommitted change in $changed" ;;
    esac
done
if git diff HEAD --unified=0 -- project.yml Heeler.xcodeproj/project.pbxproj |
    grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -qv CURRENT_PROJECT_VERSION; then
    skip "uncommitted change in project.yml or project.pbxproj beyond the build number"
fi

if [ -z "$(git branch --remotes --contains "$head")" ]; then
    skip "no remote branch contains $head"
fi

echo "$head"
