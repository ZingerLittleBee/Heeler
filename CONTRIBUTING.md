# Contributing to Heeler

Issues and PRs are welcome. Bug reports from real setups are especially
valuable — much of this app is shaped by what breaks in daily use, and a
report that names the herdr version, the SSH topology, and what the screen
showed is already half the fix.

## Orientation

Read these before changing anything non-trivial:

- [`CONTEXT.md`](CONTEXT.md) — the domain vocabulary. PRs and issues read
  better when they use these terms the way the codebase does.
- [`docs/adr/`](docs/adr/) — the decisions that look strange from the
  outside (the transport design especially) and the dead ends that led to
  them. Challenge them with evidence, not re-litigation.
- [`CLAUDE.md`](CLAUDE.md) — the working guide for humans and coding agents
  alike: conventions, load-bearing herdr facts, and the commands that
  matter. Coding agents are first-class contributors here; the repo is
  deliberately structured for them.

The repo carries four deliverables: the iOS app (`Sources/`,
`Packages/HeelerSSH`), the herdr plugin that renders Pairing Codes and posts
notifications (`plugin/`, dependency-free Node), the stateless Push Relay
(`relay/`, dependency-free Node), and the marketing site (`landing/`,
Astro).

## Building and testing

Everything goes through `make` — run `make help` for the list. The Xcode
project is generated from `project.yml` (XcodeGen; `brew install xcodegen`),
and every `make` build target regenerates it. CI builds the *committed*
`Heeler.xcodeproj`, so commit the regenerated project alongside any
`project.yml` change.

- `make test` — the full app suite plus the `Packages/HeelerSSH` package
  suites (those run through `scripts/run-heelerssh-package-tests.sh`, not
  `-only-testing`).
- One suite:
  `xcodebuild test -project Heeler.xcodeproj -scheme Heeler -destination
  'platform=iOS Simulator,name=iPhone 17'
  -only-testing:HeelerTests/<SuiteTypeName>`
- `npm test` inside `plugin/` or `relay/` for the Node deliverables
  (Node >= 20, no install step).

A few suites exercise a real SSH server; they skip cleanly on machines
without a local sshd and seeded key, and CI provisions disposable sshd
instances to run them for you.

Two artifact families are generated or shared — never hand-edit them:

- `Sources/Heeler/Transport/Generated/` comes from
  `scripts/generate-wire-types.py --schema scripts/herdr-schema.json`; CI
  fails on drift.
- `plugin/test-vectors/` is consumed by both the Swift and Node suites, and
  changes in lockstep with `docs/agents/live-activity-contract.md`.

## Conventions

- Swift 6 strict concurrency; no force unwraps or `try!` outside tests.
- Conventional Commits (`feat:`, `fix:`, `docs:`, …) with an imperative,
  lowercase subject.
- User-visible changes get a `CHANGELOG.md` entry under `[Unreleased]`,
  referencing the PR. Internal refactors and test work stay out of it.
- Never hand-edit `MARKETING_VERSION` or create version tags — releases are
  cut by the maintainer with `make publish`, and `CHANGELOG.md` is the
  source of both the version and the notes.
- Keys and secrets never leave the Keychain and never appear in code, logs,
  or fixtures.

## Reporting security issues

The privacy model (what the relay can and cannot see) is documented in
[PRIVACY.md](PRIVACY.md). For anything that looks like a vulnerability,
prefer a private report over a public issue.

## License

Heeler is licensed under AGPL-3.0 ([LICENSE](LICENSE)); contributions land
under the same license.
