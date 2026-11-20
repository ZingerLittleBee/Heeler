# iPhone Duo App Store screenshots

`exports/01-console-and-chat.png` is the first screenshot in App Store
Connect's iPhone Duo slot (2853 x 2007, opaque RGB). Run `compose_mockups.py` to
rebuild it.

- `source/01-console-and-chat-capture.png` is a capture of the unfolded inner
  display, showing real Claude Code and Codex sessions on throwaway demo
  repositories through the isolated herdr backend.
- `source/frame-template.png` supplies the background, title and bezel. It is
  the previous first screenshot, downloaded from App Store Connect, because the
  frame has no other source. The screen area is fully replaced, and
  `reletter_eyebrow.py` rewrites its eyebrow line.

`exports/01a-herdr-tmux-rex.png` is the second image and
`exports/01b-just-say-it.png` the third. `../servers/compose_servers.py` and
`../voice/compose_voice.py` render them from their own `sources/`.

The other seven images in this slot exist only in App Store Connect. Version
0.1.17 dropped `08b-host-connected.png` to make room for Voice Input, and
0.1.18 dropped `08-hosts.png` for Herdr desktop, which the Servers image
replaced in 0.1.21. That version also changed every eyebrow from "HEELER FOR
HERDR" to "HEELER FOR IPHONE"; `reletter_eyebrow.py` rewrote the line on the
seven downloaded images, and the copies went back under the same names.

Capture notes: `simctl io screenshot --display=primary-1` reads the inner display.
It returns a black image until a Device Hub window is attached to the simulator
and set to the unfolded posture.
