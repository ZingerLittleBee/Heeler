# iPhone Duo App Store screenshots

`exports/01-console-and-chat.png` is the first screenshot in App Store
Connect's iPhone Duo slot and `exports/03-chat.png` the fifth (2853 x 2007,
opaque RGB). Run `compose_mockups.py` to rebuild both.

- `source/01-console-and-chat-capture.png` and `source/03-chat-capture.png` are
  captures of the unfolded inner display, showing real Claude Code and Codex
  sessions on throwaway demo repositories through the `scripts/store-shots.py`
  rig.
- `source/frame-template.png` and `source/03-chat-template.png` supply each
  image's background, title and bezel. They are the previous screenshots,
  downloaded from App Store Connect, because the frame has no other source. The
  screen area is fully replaced, and `reletter_eyebrow.py` rewrites the first
  template's eyebrow line.

`exports/01a-herdr-tmux-rex.png` is the second image and
`exports/01b-just-say-it.png` the third. `../servers/compose_servers.py` and
`../voice/compose_voice.py` render them from their own `sources/`.

The other six images in this slot exist only in App Store Connect. Version
0.1.17 dropped `08b-host-connected.png` to make room for Voice Input, and
0.1.18 dropped `08-hosts.png` for Herdr desktop, which the Servers image
replaced in 0.1.21. That version also changed every eyebrow from "HEELER FOR
HERDR" to "HEELER FOR IPHONE"; `reletter_eyebrow.py` rewrote the line on the
seven images that were only in App Store Connect then, and the copies went
back under the same names.

Capture notes: `simctl io screenshot --display=primary-1` reads the inner display.
It returns a black image until a Device Hub window is attached to the simulator
and set to the unfolded posture.
