---
status: accepted
---

# Select herdr-core explicitly on a Host

Issue [#535](https://github.com/ZingerLittleBee/Heeler/issues/535) reports desktop Agents missing while the legacy herdr connection succeeds. herdr-app uses a separate core with a different protocol; changing the legacy socket path cannot reach its inventory correctly.

`Host.backend` selects herdr or herdr-core and defaults existing catalogs to herdr. Core uses generation-one JSON-RPC through `hc connect` and live PTYs through `hc attach`, on the existing authenticated SSH connection. Each invocation selects `HC_SESSION`; no legacy operation falls back to core, and unsupported core operations never reach legacy herdr. Pairing Code v2 continues to describe only a legacy Herdr Endpoint. Core can be added with the existing manual SSH authentication methods.

Core terminal addresses remain opaque identifiers. Each local terminal supplies one Pane and Tab, grouped into a Workspace by launch directory. This grouping does not edit or interpret the desktop's layout documents. Federated terminals are omitted because their directories and files do not belong to this SSH Host; users add their owning machine directly. Subscription acknowledgement precedes the Console snapshot, sequence cursors reject old events, and missed events trigger a fresh inventory.

Plugin-based notifications, Live Activities and Usage are unavailable. Chat is unavailable without exact conversation identity. Rename and Worktree actions are hidden or refused because core does not implement their legacy contract. SSH file operations remain shared. Core uses the same combined exec-session limit as native Windows because its event channel consumes an OpenSSH session slot too.

See the [setup guide](../guides/herdr-core.md) for supported behavior and verification scope. The codec and real-SSH regression suites exercise the generation-one contract independently of desktop layout.
