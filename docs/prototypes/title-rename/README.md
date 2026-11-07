# Agent conversation title rename

The production implementation supersedes the original UI prototype. `AgentTitleRenameSheet` is shared by the existing native More menu (Chat and Terminal) and the Agent list context menu. `AgentTitleRenameStore` sends native commands through the connected Host and confirms the title before dismissing.

## Behavior

- Save applies the manually entered title to Claude Code, Codex, Pi, OMP, Grok, or OpenCode.
- Generate Automatically invokes native title generation and applies the result immediately for Claude Code, Codex, and OMP. Other Agents show a disabled action with an explanation.
- Cancel before an operation writes nothing. Editing and dismissal are disabled while an operation is in progress.
- The operation requires an idle Agent, an empty native input, and a stable conversation identity. A changed conversation or an uncertain result stops further writes.
- Agent aliases remain separate. This implementation supports Herdr TUI Hosts; herdr-core Hosts do not expose this action yet.

See [ADR 0040](../../adr/0040-conversation-titles-use-native-agent-commands.md) for transport boundaries, confirmation rules, and compatibility limits. Use the normal `make` Simulator build and install targets; the prototype launch flags and fake Save/Generate actions have been removed.

## Verification

`AgentTitleRenameTests` covers native command selection, result confirmation, draft/session guards, duplicate operations, failure preservation, and native dialog shapes. Run it through `make test-app` on an explicitly selected Simulator UUID.

`AgentTitleRenameLiveTests`, in `Tests/HeelerLiveTests`, is opt-in through the separate `HeelerLiveTests` target and scheme. It connects the production SSH transport to explicitly named disposable Agents, saves a unique title, and exercises configured native generators. The ordinary `HeelerTests` target and full CI never run it or count it as covered. Selecting the live scheme without its configuration fails rather than reporting a successful skip.

Set `HEELER_TITLE_RENAME_CONFIG` in the selected Simulator launch environment to base64-encoded JSON containing:

- `port`, `username`, `deviceKeySeed`, `fingerprint`, and `socketPath` for a loopback SSH fixture. The seed must belong to a disposable fixture key.
- `allowTitleMutations: true`, explicitly authorizing mutations on the listed test Agents.
- `agents`, each containing `paneID`, `terminalID`, the exact `AgentSessionInfo` as `session`, `generates`, and `generationMayFail`. The last flag permits a confirmed native generation error, never a timeout or an unconfirmed result.

After configuring the owned fixture, run:

```sh
make test-app SCHEME=HeelerLiveTests \
  SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
  TEST_SELECTOR='HeelerLiveTests/AgentTitleRenameLiveTests'
```

The operator must verify these are owned test Agents before configuring the suite. Never commit or print the configuration or key material. Unset the environment variable, close only the owned test Agents, and stop the disposable SSH fixture after testing.

## Historical visual evidence

These screenshots record the approved native style from the earlier UI prototype, using demo data on an iPhone 17 Pro Simulator running iOS 27.0. They are not evidence of production title persistence or physical-device acceptance.

- [Native More menu](screenshots/more-menu.png)
- [Agent list context menu](screenshots/list-menu.png)
- [Shared Rename sheet](screenshots/rename-sheet.png)
