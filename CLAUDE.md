# Heeler

Native iOS companion app for [herdr](https://herdr.dev), an agent console over SSH.

## Start here

- **Implementation or diagnosis:** use [the source map](docs/agents/navigation.md)
  to find the feature entry, state owner, transport seam, and focused tests.
- **Domain terms or architecture:** read [CONTEXT.md](CONTEXT.md), then the
  area-specific ADR linked by the source map.
- **Tests or builds:** use `make help` and [the testing guide](docs/agents/testing.md).
  For Simulator UI work, read [the UI runbook](docs/agents/simulator-ui.md).
- **Review or regrade:** capture the current acceptance amendments, candidate,
  and evidence in [the handoff template](docs/agents/review-handoff.md).
- **RPC, subscriptions, launch/input, or scrolling compatibility:** consult
  [versioned herdr observations](docs/agents/herdr-compatibility.md). Check each
  observation's version before applying it to a newer server.

## Architecture

- SwiftUI, iOS 18+, iPhone and iPad. SSH uses the repository-local
  `Packages/HeelerSSH` (pinned libssh2 and OpenSSL); terminal rendering uses the
  pinned libghostty-spm `GhosttyTerminal` product (ADRs 0001 and 0004).
- Unix API and Events use NDJSON over direct-streamlocal channels to herdr's
  socket. Unix Agent and shell terminals use PTY exec (ADR 0011).
- Native Windows API and Events use `herdr remote-api-bridge`; live terminals
  use `herdr terminal session control` over SSH exec (ADR 0018). This is a
  platform branch, never a fallback after Unix forwarding refusal.
- UI depends on `Transport`, not SSH library types. Pane ids are opaque strings.
  Protocol negotiation enforces a floor, ignores unknown fields, and treats the
  generated protocol version as advisory. API requests are one-shot; subscribe
  acknowledgement precedes snapshots, and reconnect requires fresh inventory.
- Terminal inventory and retained attachments follow ADR 0017; RSA Key
  authentication follows ADR 0019. Use the source map's full ADR links.

## Conventions

- Build, test, device install, and TestFlight work uses `make`. CI builds the
  committed `Heeler.xcodeproj`; regenerate and commit it when source membership or
  `project.yml` change. Verification must name its candidate and executed tests.
- Generated wire types use
  `python3 scripts/generate-wire-types.py --schema scripts/herdr-schema.json`.
  The flag-less command queries local herdr. Shared vectors in
  `plugin/test-vectors/` change with their Swift/Node consumers and
  [Live Activity contract](docs/agents/live-activity-contract.md).
- Swift 6 strict concurrency. No force unwraps or `try!` outside tests.
- Private SSH keys stay in the Keychain. Per-Host Notification Keys are copied
  over SSH for encrypted notifications; host-key policy is TOFU with fingerprint
  confirmation. Preserve these boundaries when changing authentication.
- Dependency updates must keep exact pins and review source hashes plus
  committed XCFramework checksums (`Packages/HeelerSSH` and libghostty-spm).
- User-visible changes get a `CHANGELOG.md` Unreleased entry referencing the PR;
  internal refactors and test work stay out. Domain term changes update
  `CONTEXT.md`; hard-to-reverse, surprising trade-offs get an ADR.
- Release work follows [releasing.md](docs/guides/releasing.md): `make publish`
  cuts CHANGELOG and versions and pushes the tag; `release.yml` signs and
  uploads it. `make bump && make testflight` stays a local
  interim upload. The release runner owns version edits and tags.
- Commits and PRs carry no attribution trailers or email addresses; local hooks
  and CI enforce the [contribution policy](CONTRIBUTING.md#commit-attribution).
  Commits reference issues with `refs #<n>`; a PR that resolves an issue ends
  its body with `Closes #<n>`, a partial one with `refs #<n>`.

## Tracker

GitHub operations use `gh`. Read [issue-tracker.md](docs/agents/issue-tracker.md)
for issue/PR work and [triage-labels.md](docs/agents/triage-labels.md) for labels.
The repository has one domain context; [domain.md](docs/agents/domain.md)
describes how engineering skills consume it.
