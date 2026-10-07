# Simulator GUI verification

Use this guide when opening a simulator for review, capturing Dynamic Island
content, or deciding whether an accessibility check proves a UI interaction.
Build and install through the [Makefile](../../Makefile); this helper only
discovers GUI tooling, opens its application, or captures an existing device.

## Select the device

Run `make simulator-ui` first. Its default is a read-only inventory: the selected
developer directory, the effective `simctl` path, Simulator/DeviceHub application
paths in that Xcode bundle, `idb` executables on PATH, and every available
simulator's UUID, name, runtime identifier, and state. It reports a
`DEVELOPER_DIR` override when present. An installed `idb` executable does not
prove that its companion connects or that touch injection works.

Copy the agreed device UUID from that inventory. Use the full UUID in every
command; a name can identify several runtimes, and `booted` can select another
agent's device. Build, install, and launch on that exact UUID:

```sh
make sim-id SIMULATOR_UDID="$SIMULATOR_UDID" \
  SIM_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
```

To inspect an unavailable device as well:

```sh
python3 scripts/simulator-ui.py --udid "$SIMULATOR_UDID"
```

The helper discovers the applications in the effective Xcode bundle instead of
assuming an installation name or a legacy `Developer/Applications` layout.
To open the discovered GUI application:

```sh
python3 scripts/simulator-ui.py --udid "$SIMULATOR_UDID" --open
```

Opening the application does **not** select the target. In DeviceHub, use
**File > New Window**, then select the simulator matching the reported name
and runtime. This sequence was observed on Xcode 27, build 27A266a; verify the
menu labels on other versions. In standalone Simulator, use **File > Open
Simulator**, then select the runtime and device. Confirm the UUID in the device
details before interacting, particularly when names repeat. The helper uses
`open -a` and leaves selection to the GUI; it does not assume a DeviceHub URL
scheme or apply private framework/idb workarounds.

Use the task's agreed device and backend. Stop injecting gestures while the
user operates it. Opening an Agent detail attaches its terminal, which can
displace the current attach owner. Prefer the existing demo for screenshot
work, or an isolated herdr + sshd backend for real interactions; a test that
uses the user's live server needs authorization for its writes.
`python3 scripts/isolated-herdr-backend.py start` provides that backend and
prints the Host settings and `knownHostFingerprints` entry to seed; `stop`
removes it. See its `--help`.

## Capture and inspect

Capture requires the selected simulator to be available and already Booted:

```sh
python3 scripts/simulator-ui.py --udid "$SIMULATOR_UDID" \
  --capture build/ui-review/island.png
```

The helper uses `xcrun simctl io <UUID> screenshot --type=png --mask=black`.
The black mask captured the Live Activity layer in the iOS 27 investigation
where the default screenshot omitted it. Treat an empty screenshot as a
capture question first: compare with the actual GUI and activity diagnostics.
Save a new filename for each state; replacing an existing image requires
`--overwrite`. A failed capture preserves the previous file.

Inspect the changed region at the original pixel resolution. Record the
device/runtime, UI state, display appearance, and content size alongside the
image. Accessibility labels establish what a view exposes to assistive
technology; they do not establish an unobstructed touch target. Execute the
actual tap, scroll, long press, or layout switch and verify its resulting UI
when that interaction is part of the acceptance criterion. Read-only reviews
should mark such checks unexecuted.

## Live Activity setup and coverage

The source path is [HostLiveActivityCoordinator](../../Sources/Heeler/LiveActivities/HostLiveActivityCoordinator.swift)
→ [AgentActivityContentBuilder](../../Sources/Heeler/LiveActivities/AgentActivityContentBuilder.swift)
→ [ActivityKitLiveActivityController](../../Sources/Heeler/LiveActivities/LiveActivityControlling.swift)
→ [AgentLiveActivityWidget](../../Sources/HeelerWidgets/AgentLiveActivityWidget.swift).
[AgentActivityDecryptor](../../Sources/HeelerWidgets/AgentActivityDecryptor.swift)
selects the rows that fit. Wire shapes and eligibility belong to the existing
[Live Activity contract](live-activity-contract.md).

For a real activity on an agreed test Host, enable Notifications in
**Settings > Notifications**, allow the system permission, then enable that
Host's **Notifications** and **Live Activity** switches. Keep Heeler foregrounded
while its Agent inventory settles. A start also needs a push device token and
that Host's Notification Key; the same screen's diagnostic note reports the
blocker or `active — started`. Registration writes to the test Host are part
of this setup. Background the app for compact presentation, and long press
the island for expanded presentation.

Use controlled Agent states on an isolated backend for the matrix below.
Capture both compact and expanded for each status case, then the Lock Screen
banner and minimal presentation where available. Minimal needs another
simultaneous Live Activity. Record unsupported or unavailable cases rather
than crediting a different presentation.

| Case | What to inspect |
| --- | --- |
| Working only, Done only, Blocked only | Each glyph, count, and corner is visible; a dim Working ring can conceal clipping. |
| Mixed Blocked + Done + Working | Leading/trailing tokens clear the system's rounded clipping shape. |
| Two-digit counts, including mixed statuses | Counts remain complete; record any status-bar changes. |
| More Agents than visible rows | Complete final row and `+N more`, with the configured Agent List Fields. |
| Default and accessibility content sizes | Header and overflow fit the system height limit; inspect the Lock Screen separately. |
| Counts-only fallback | No decrypted rows; counts still convey status. |

Read current size with `xcrun simctl ui "$SIMULATOR_UDID" content_size`; if the
task authorizes changing it, set a supported category such as
`accessibility-large`, then restore the recorded original value. Query
`xcrun simctl help ui` for the installed tool's categories.

The existing [demo composition](../../Sources/Heeler/Demo/DemoScreenshotMode.swift)
provides invented data and process-local settings, but its Live Activity
coordinator has a nil device token and fresh opt-in preferences. Therefore
`--demo-screenshots` alone is not a real ActivityKit state harness.
[AgentActivityPresentationTests](../../Tests/HeelerTests/AgentActivityPresentationTests.swift)
exercise widget subviews and height calculations; they do not prove the
system island's clipping or touch behavior. Use these existing seams for
future deterministic scenarios instead of repeating transient production
source injections. This guide and helper add no such scenario feature.

Report which evidence was actually collected: source review, subview render,
real simulator activity, touch interaction, or physical-device observation.
Include the missing matrix cases and leave a requested inspection handoff
untouched.
