# Store screenshots

Screenshots that show Agent content come from real Claude Code and Codex
sessions on throwaway repositories, not `--demo-screenshots`. Using quota for
them is expected.

Compose scripts live with their exports:

| App Store Connect slot | Directory | Script |
| --- | --- | --- |
| iPhone large display | `output/app-store/iphone-6.9/` | `compose_mockups.py` |
| iPad 13-inch | `output/app-store/ipad-13/` | `compose_mockups.py` |
| iPhone Duo, first image | `output/app-store/iphone-duo/` | `compose_mockups.py` |
| Herdr desktop, second image of all three | `output/app-store/desktop/` | `compose_desktop.py` |
| Voice Input, third image of all three | `output/app-store/voice/` | `compose_voice.py` |
| Header and Search Results | `output/app-store/creative-assets/` | `compose_creative.py` |

## 1. Start the Agents

```sh
python3 scripts/store-shots.py up
```

This takes a few minutes. It creates `~/workspace` (the app shortens paths only
under the Host user's home), starts two herdr sessions, and runs eleven Agents:
Storefront (left Blocked), Docs, Search, Inventory (a Chat reply with a code
block and bullets), Mobile App, Analytics, Notifications and Admin Dashboard,
plus Payments API (the richest Changes page, with three staged files), Auth
Service and Release CLI on the second session. Eleven rows fill an iPhone
Console. It refuses a `~/workspace` it did not create;
pass `--workspace` to use another directory.

## 2. Connect a simulator

Boot a simulator nobody else uses, install and launch Heeler, then copy the
`ssh-ed25519` line from its Add Host sheet:

```sh
python3 scripts/store-shots.py seed "$UDID" "ssh-ed25519 AAAA... heeler" --clock 9:41
```

It backs up the preferences, adds the Hosts "Studio Mac" and "Build Server",
selects dark appearance and overrides the status bar. Leave out `--clock` on
iPad: a fixed time contradicts the Dock's calendar and "Read at" labels. Undo it
with `store-shots.py restore "$UDID"`.

Drive the app as [the UI runbook](simulator-ui.md) describes. Before a capture:

- `store-shots.py working` turns the Search ring.
- `store-shots.py diff` makes Payments edit files. Capture while it works, since
  its reply scrolls the colored diff away.
- Collapse the Agent header from the More menu when text behind it distracts.
- Check the keyboard's paste bar for Mac clipboard contents, and remove
  `zh-Hans-US` from a simulator's `AppleLanguages` if its keyboard shows Pinyin.

### iPhone Duo

Every display captures black and touches land nowhere until a Device Hub window
is attached. Open one with **File > New Window** and pick the row. Two rows can
share a name, so compare the window with `simctl io "$UDID" screenshot` before
acting. Press the unfolded posture button in the window's bottom toolbar, then:

```sh
xcrun simctl io "$UDID" screenshot --display=primary-1 capture.png
```

That gives 2853 x 2007 in landscape. XCUITest taps miss in this posture on
Xcode 27, so click through the Device Hub window.

### Herdr desktop

The rig has no herdr-core, so this image needs a Linux machine running the
Herdr desktop app, such as a throwaway VM. Copy the fixture repositories there,
log Claude Code in, and add the machine to the seeded simulator as a herdr-core
Host. Start each Agent from Heeler's New Agent with a New Workspace, so the
desktop names its space. The image cuts the Hosts card and the Agents list
filtered to that Host.

The Hosts card shows `user@address`, so every Host gets a machine name
(`studio-mac`, `build-server`, `linux-desktop`) on port 22 and the same user
name. Route all three through a jump host on the Mac that maps each name to a
local port: the rig's sshd, or a forward to the VM's sshd. A small asyncssh
server that only accepts `direct-tcpip` is enough. A jump host on the VM sends
the Herdr TUI Hosts across its network twice, and the card then shows
latencies of several seconds. Agent rows shorten a path to `~` only under
`/Users/<user>` or `/home/<user>`, so the VM account needs that user name and
home.

### Voice Input

The simulator's microphone records near silence, so a live recording draws a
flat waveform. For the waveform, build a local copy whose recorder replays a
clip synthesized with `say`, and never commit it. The transcript still comes
from a real transcription service: store your key in Settings › Voice Input
and accept the consent alert. `output/app-store/voice/README.md` records how
the current images were made.

## 3. Compose

Put captures in the slot's source directory and run its script. Inspect the
result at full resolution; the corners and the text behind floating controls are
what go wrong.

## 4. Upload

Write actions print a plan until you add `--apply`, and none of them submit the
version for review. Run them only when the user asked for the store to change.

```sh
python3 scripts/store-shots.py asc status --version 0.1.17
python3 scripts/store-shots.py asc screenshots duo output/app-store/iphone-duo/exports/01-console-and-chat.png --version 0.1.17
python3 scripts/store-shots.py asc creative header output/app-store/creative-assets/exports/product-page-header-3840x1646.png --version 0.1.17
python3 scripts/store-shots.py asc whats-new notes.txt --version 0.1.17
python3 scripts/store-shots.py asc promo promo.txt --version 0.1.17
python3 scripts/store-shots.py asc keywords keywords.txt --version 0.1.17
python3 scripts/store-shots.py asc description description.txt --version 0.1.17
```

`screenshots` matches by file name and keeps each image's position, deleting the
old image before it uploads. A file name the set lacks goes last, or at
`--at N` (counted from 1). `--remove NAME` deletes another image first, to make
room in a full set of ten:

```sh
python3 scripts/store-shots.py asc screenshots duo output/app-store/iphone-duo/exports/01b-just-say-it.png \
  --at 2 --remove 08b-host-connected.png --version 0.1.17
```

Targets are `ipad`, `iphone` and `duo`; `creative` takes `header` or `search`.
It needs ego-browser signed in to App Store Connect.

## 5. Clean up

Ask before this if the user is still reviewing images, since a retake otherwise
reruns every Agent.

```sh
python3 scripts/store-shots.py down
```

It stops the backend and removes the repositories, their Claude Code projects
and session files, their trust entries in `~/.claude.json` and
`~/.codex/config.toml`, and their Codex rollouts. `~/.claude/history.jsonl` keeps
the prompts. Shut down any simulator you booted.
