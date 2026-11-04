#!/bin/sh
# Tests scripts/source-revision.sh against throwaway repositories.
set -eu

script="$(cd "$(dirname "$0")" && pwd)/source-revision.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git init --quiet --bare "$work/remote.git"
git init --quiet "$work/repo"
cd "$work/repo"
git config user.name test
git config user.email test@invalid
git config commit.gpgsign false
mkdir Heeler.xcodeproj Sources
printf 'name: Heeler\nCURRENT_PROJECT_VERSION: "25"\n' > project.yml
printf 'CURRENT_PROJECT_VERSION = 25;\nPRODUCT_NAME = Heeler;\n' > Heeler.xcodeproj/project.pbxproj
echo 'let a = 1' > Sources/App.swift
git add .
git commit --quiet --message initial
git remote add origin "$work/remote.git"

failures=0
expect() {
    description=$1
    expected=$2
    actual=$(sh "$script" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        echo "ok - $description"
    else
        echo "not ok - $description: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

head=$(git rev-parse HEAD)
expect "an unpushed commit records nothing" ""

git push --quiet origin HEAD:main
git fetch --quiet origin
expect "a clean, pushed commit is recorded" "$head"

echo 'scratch' > notes.txt
expect "untracked files do not matter" "$head"
rm notes.txt

sed -i.bak 's/"25"/"26"/' project.yml && rm project.yml.bak
sed -i.bak 's/= 25;/= 26;/' Heeler.xcodeproj/project.pbxproj && rm Heeler.xcodeproj/project.pbxproj.bak
expect "make bump's build number change is allowed" "$head"

echo 'PRODUCT_NAME = Other;' >> Heeler.xcodeproj/project.pbxproj
expect "another project change records nothing" ""
git checkout --quiet -- Heeler.xcodeproj/project.pbxproj project.yml

echo 'let b = 2' >> Sources/App.swift
expect "a source change records nothing" ""
git checkout --quiet -- Sources/App.swift

echo 'let c = 3' >> Sources/App.swift
git add Sources/App.swift
expect "a staged change records nothing" ""
git reset --quiet --hard
expect "a clean tree after reverting is recorded again" "$head"

if [ "$failures" -ne 0 ]; then
    echo "$failures source-revision test(s) failed" >&2
    exit 1
fi
