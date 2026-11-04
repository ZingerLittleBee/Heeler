---
status: accepted
---

# Distribute the herdr plugin from a generated `plugin` branch

`herdr plugin install owner/repo/subdir --ref <ref>` fetches the whole tree of
`<ref>` (one shallow commit, no sparse checkout), keeps its `.git`, and runs
the manifest's `[[build]]` commands in the subdirectory. Installing from
`ZingerLittleBee/Heeler/plugin --ref main` therefore cost about 153 MB on
herdr 0.9.5, of which the plugin and its `node_modules` were about 3.5 MB.
herdr has no include or exclude setting, in the CLI or the manifest, and
`export-ignore` does not apply to a fetch.

## Decision

The plugin is installed from a branch that holds nothing else:
`herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes`.

- `make plugin` (`scripts/publish-plugin.sh`) builds the branch's tree from
  `plugin/` on `origin/main` with git plumbing: the runtime files
  (`herdr-plugin.toml`, `package.json`, `package-lock.json`, `src/`,
  `README.md`) and the repository `LICENSE`, at the root. `test/` and
  `test-vectors/` stay behind. An install is about 3 MB, most of it
  `node_modules` from the unchanged `npm ci` build step.
- Each publish appends one commit naming its source commit on `main` and
  is pushed without force. herdr fetches only the newest commit, so the
  history costs installs nothing and keeps every version installable with
  `--ref <commit>`.
- Publishing is local and separate from the app release. The script refuses
  a source that is not on `main`, a manifest and `package.json` that
  disagree, and changed content under a version that is not newer than the
  published one, and it runs `npm ci` and the plugin tests against the
  exact tree before pushing.
- Development and tests stay in `plugin/` on `main`. Nobody commits to the
  `plugin` branch by hand.

## Consequences

- Released apps name the `plugin` branch in the Setup Guide and the update
  notice, so the branch can never be deleted or rewritten.
- Releases before this change name `ZingerLittleBee/Heeler/plugin --ref main`,
  and `herdr plugin update` keeps the ref recorded at install, so `plugin/`
  on `main` must stay directly installable.
- Running the new command replaces an install from the old source in place.
  herdr 0.7.5 and later replace any GitHub-installed plugin with the same id
  and refuse only a linked one (`ensure_replacement_allowed` in
  `src/cli/plugin.rs`; observed on 0.9.5, keeping the enabled state). A Host
  moves over the next time the app recommends an update.
- Order matters: a plugin version the app depends on must be published
  before the app release that bundles it, or the update notice reinstalls
  the older version. `make publish` refuses to cut a release until the
  `plugin` branch carries the version `plugin/` declares.

## Alternatives

- **A separate plugin repository**: the same footprint, but the Swift and
  Node tests that share `plugin/test-vectors/` would span two repositories.
- **Vendoring `node_modules` or bundling `src/`**: removes the build step but
  adds a generated artifact to review; `npm ci` is what herdr's plugin
  model expects.
- **Publishing from CI**: possible later, but a local command keeps the
  decision to publish with whoever bumped the version, as with the app's
  release tag.
- **Force-pushing a single commit**: no smaller for installs, and it would
  break `--ref <commit>` pins.
