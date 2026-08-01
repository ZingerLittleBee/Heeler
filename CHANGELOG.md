# Changelog

All notable changes to herdr-mobile are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries reference the issue that motivated them.

## [Unreleased]

### Changed

- The Agent detail screen's More menu no longer duplicates Settings; that
  entry stays in the Console toolbar.

- Working agents in the Console list now show a live "solving" orb — a
  dotted sphere whose bands twist and click back into place (ported from
  Jakub Antalik's MIT-licensed thinking-orbs) — instead of the static blue
  Working capsule. Reduced-motion users get a still frame. (PR #106)

### Added

- A dedicated newline button above the iOS keyboard inserts a line break into
  an Agent prompt without pressing Enter or submitting it.

- Start another Agent from the one you have open: "New Agent" in the Agent
  detail screen's More menu inherits that Agent's Host, workspace, and working
  directory, so the new Agent starts in a fresh tab in the same place instead
  of at the workspace root. Only the Agent, its name, and its arguments are
  left to fill in.

- Attach Links silently collect web and OSC 8 targets into a memory-only list
  for opening or copying. Links survive terminal recovery and are discarded
  when Attach ends. (#101, #102, #103, #104; PR #105)

- An iPad-fit Console: on regular widths the Agent list becomes a sidebar
  beside the open terminal (a split view) instead of stretching edge to edge,
  and the in-app notification banner caps at a system-banner width. iPhone
  navigation is unchanged.

- Filter the Agent list by Host: with more than one Host configured, a filter
  menu in the Console toolbar narrows the list (and its connection notices) to
  one machine.

- Per-appearance terminal themes: Light Mode and Dark Mode each have their own
  theme slot, so a dark terminal under a light system is one picker away. The
  previously selected theme carries over to both slots on upgrade.
- 20 more curated themes (30 total): Rosé Pine, Ayu, One Half, Kanagawa,
  Everforest, GitHub, Night Owl, Iceberg, Flexoki, Selenized, Modus, Tomorrow,
  Melange, Zenbones, One Dark, Snazzy, Oceanic Next, Poimandres, Horizon,
  Zenburn.
- The terminal theme now owns the whole Attach screen: its background extends
  under the navigation bar and into the home-indicator area, and bar/status-bar
  text follows the theme's luminance instead of the system appearance. (#95)
- An About section on the Settings root with the app version and build number
  plus links to the GitHub repository and the privacy policy.
- Rename Agents and workspaces from the Agent detail screen's menu. Agent
  names follow the server's rule (lowercase letters, digits, `-`/`_`, up to
  32 characters) with inline validation, and leaving the name empty falls
  back to the detected kind. (#98)
- Start an Agent in a fresh git worktree: a "Start in a new worktree" toggle
  on the New Agent form gives the task a clean checkout of the selected
  workspace's repository, with optional branch (validated inline) and base;
  empty fields use herdr's generated `worktree/` branch off HEAD. (#97)

### Changed

- The Agent Name field on the New Agent form is now optional: empty names the
  agent after its kind (`claude`, `claude-2`, …), matching how the herdr TUI
  labels unnamed agents, and the suggested name shows as the placeholder.
  Typed names are validated inline against herdr's naming rule instead of
  bouncing off the server.
- The theme pickers under Terminal Appearance now show a colour swatch for
  every theme (like the keyboard's Appearance pane) and a live preview of the
  current pick at the top of each page. The preview moved there from the
  Terminal Appearance root, and each picker renders its own appearance's half
  of paired themes regardless of the current system appearance.
- The Settings sheet is now a shallow menu with two pages, Notifications and
  Terminal Appearance, instead of one long mixed form. Per-Host notification
  rows no longer push the appearance controls out of reach, and the
  self-builder Custom Push Relay field moved to the bottom of the
  Notifications page.

### Fixed

- Terminal scrolling and typing stay responsive on lossy connections: touch
  momentum is coalesced and bounded, and fresh keyboard input no longer waits
  behind stale wheel events.

- Slow or stalled networks no longer leave SSH requests or Host lifecycle
  transitions stuck indefinitely. Request deadlines now return promptly,
  invalidate the unusable connection, and discard late connection attempts
  after the app suspends or reconnects.

- Holding the iOS keyboard's Backspace key now continues deleting instead of
  stopping after one character.

- Failed Host notices stay compact in the Agent list and open the affected
  Host directly, where an explicit reconnect action stays visible, animates
  while restarting, and leaves the latest connection error below it. (PR #107)

- Arguments typed on the New Agent form survive the iOS keyboard's smart
  punctuation: `--yolo` no longer reaches the Host as an em-dash garbage
  argument, and curly quotes normalize back to the straight quotes the
  argument parser understands.

- Taps forwarded to a mouse-tracking TUI now land on the cell Ghostty actually
  draws under the finger. The tap-to-cell mapper assumed a centred grid, but
  Ghostty anchors it at a fixed padding; the mismatch shifted reports by up to
  half a cell (worst on 3x screens) near cell boundaries.
- Tapping the terminal body no longer toggles the software keyboard. Ghostty's
  touch handling raised and dismissed the keyboard on any touch once it had
  been raised once, including after returning from a short backgrounding; both
  paths are now gated behind the input-row tap policy. (#95)
- The keyboard tap target in full-screen agent TUIs is now a wider caret band
  plus the bottom quarter of the screen, instead of the whole surface — output
  areas stay inert while every chat TUI's pinned input box remains hittable,
  whichever tool draws it. (#95, refs #90)
