---
status: accepted
---

# Release builds tag a main commit and run no tests

[ADR 0038](0038-testflight-build-tags.md) cut each build with a commit that
bumped every target's version and folded the changelog, pushed straight to
`main` with the tag. The tag run then called the full `ci-full.yml` suites
before archiving: 30 to 37 minutes on four macOS runners, compiled without the
cross-run compiler cache. The tag reserved its number before that gate, so
every test failure spent one. The 0.1.18 release lost builds 41, 42 and 43
that way before any upload: twice to stale tests, once to an evidence-validator
rule.

A build tag now names an existing `main` commit. `make testflight` checks that
the local `main` is clean and equals `origin/main`, then pushes only the
annotated tag. It commits nothing and regenerates nothing. The tag's name sets
the version and build: the archive passes `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` on the command line, so every signed target takes
them, and the IPA check verifies each bundle. The committed project keeps the
values of the last build cut before this decision. Local builds show those,
and they stay a floor for the build counter and the version.

`release.yml` runs no tests and does not read CI status. `ci-full.yml` runs
daily and on demand only, not on every push to `main`, because `main` moves
often. A build can therefore carry a regression that full verification would
have caught. The maintainer tests each build in TestFlight before external
testers get it, and can run `ci-full.yml` by hand before a cut.

`CHANGELOG.md` is no longer rewritten per build. A build's notes are its
source's `[Unreleased]` folded into its version's `## [X.Y.Z]` section,
computed when the record is saved. Before starting a new version, the entries
the newest build included move under that build's section; the cut refuses
otherwise, so a version never repeats the previous one's notes.

Without a bump commit, two cuts can share a source. A cut refuses `main` when
the newest build already used that commit: a pre-upload failure is retried on
its own tag, and otherwise the same commit needs a change or a new version.
A void tag or a rejected binary may be rebuilt from it.

The checkpoint, upload ambiguity, dSYM and recovery rules of ADR 0038 stand.
