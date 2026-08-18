# Changelog

All notable changes to Heeler are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries reference the issue that motivated them.

## [Unreleased]

### Fixed

- Opening an Agent no longer dies with `exec: herdr: not found` (exit 127) on a
  Host that installed herdr via Homebrew or linuxbrew. The API socket never
  needed `herdr` on `PATH`, so the Console could already list Agents; Attach
  and the other CLI execs now append the usual install prefixes after the
  session `PATH` (`~/.local/bin`, `/opt/homebrew/bin`,
  `/home/linuxbrew/.linuxbrew/bin`). (#206)

### Added

- Agent detail now places a plus menu to the left of Send. It can add an image
  from Photos or a file up to 64 MiB from Files, stages the selection privately
  on the Host over SFTP, and inserts the resulting path into the local draft
  without submitting it. Discovered Links appear beside the plus menu, while
  the former title-bar Agent actions live in a separate More menu immediately
  to its right. Agent detail omits the visible title bar so terminal output uses
  the full area below the system status bar, while preserving edge-swipe
  navigation and matching status-bar contrast to the terminal theme. (#182)

- Agent detail now combines the complete live libghostty terminal with a local
  Composer. The terminal preserves TUI rendering, scrollback, and PTY resize,
  including touch scrolling in alternate-screen TUIs, but no longer accepts
  direct keyboard, paste, or pointer-click input.
  Drafting makes no network requests;
  Send delivers the complete message once and shows delivery, Agent work, and
  Done states from acknowledgments and status pushes. Failed messages can be
  retried or returned to the draft without losing text, and drafts survive
  terminal recovery, backgrounding, and Host reconnects. The Agent switcher
  sits at the bottom of the Composer, keeping session changes and the keyboard
  toggle within reach without reopening the Console. While the keyboard is
  visible, a neighbouring control switches between the iOS keyboard and a
  tabbed tools keyboard. Its Agent controls send Esc, Tab, Shift-Tab, arrows,
  Enter, and Backspace directly to the Agent without changing the draft. The
  The tools dock stays positioned behind the system keyboard and replaces it
  without exposing the disappearing native candidate row as an empty frame.
  Both modes share the same complete measured height, including the native iOS
  candidate and paste area and the Home Indicator area, so switching does not
  move the Composer or change the terminal's root geometry, grid size, or
  rendered frame.
  (#182)

- Settings > About now has Acknowledgements: every redistributed third-party
  component ships with its exact upstream licence notice, including libssh2
  and its secondary sources, OpenSSL, Ghostty and its stack, the monospaced
  fonts, and the rest of the audited inventory. The catalogue fails loudly
  when a notice is missing or malformed. (#161; PR #170)

### Changed

- App Store builds now target iPhone only. The notification service uses the
  same device family, so App Store Connect no longer treats iPad screenshots as
  part of the release requirements.

- Heeler once again supports iOS 18 and later. The removed Dictation feature no
  longer holds the app at iOS 26, and the bundled OpenSSL/libssh2 artifacts now
  share the restored iOS 18 deployment target. (#35)

- Notification setup now distinguishes device registration from per-Host
  configuration, accurately describes relay-visible metadata and Notification
  Key custody, warns when a custom relay uses cleartext HTTP, and uses
  Heeler-branded generic fallback alerts. (PR #195)

- Opening an Agent now gives Heeler priority over an existing terminal client.
  Attach and Reattach use herdr's takeover mode, so a stale mobile connection
  or a desktop client can no longer prevent the Agent detail terminal from
  opening. The displaced client is disconnected.

- A Host whose SSH server has stream-local forwarding turned off now says so
  even when herdr isn't on the SSH session's `PATH`. Heeler tries to start
  herdr once before giving up; when that attempt itself failed, the checks
  used to report "the herdr server is not running" and drop the forwarding
  half of the diagnosis. Since a typical macOS Host keeps herdr at
  `~/.local/bin` or `/opt/homebrew/bin` — neither on the default `PATH` of an
  SSH command — that hit exactly the Hosts most likely to need the forwarding
  advice. (#125)

- Hosts no longer need `socat`. Heeler now reaches herdr's socket over an SSH
  stream-local forward instead of launching a remote helper per request, so
  SSH access and a running herdr server are the whole prerequisite. The socat
  path field is gone from Add/Edit Host, the onboarding checklist has dropped
  its "socat installed" row, and existing Hosts carry over untouched — nothing
  to reconfigure. If a Host's SSH server has stream-local forwarding turned
  off (it is on by default), the checks now say so. (#122)

- The app is now named **Heeler**: the home-screen name, the microphone and
  camera permission prompts, and the notification extension's display name
  all say Heeler instead of Herdr. herdr remains the name of the server it
  connects to; the App Store listing will be "Heeler for herdr". The GitHub
  repository moved to ZingerLittleBee/Heeler and the in-app repository and
  privacy-policy links follow (the old URLs redirect).
- The pairing plugin's id and display name are now both `heeler` (the id was
  `herdr-mobile.pairing`, the display name `Heeler Pairing`). Hosts still
  running the plugin under an old id keep working: Notification Registration
  matches the installed id — current first, then legacy — and writes into
  that plugin's own config directory, so updating the plugin
  (`herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes`) can
  happen whenever convenient. After updating it, redo Notification
  Registration from the app once; pairing and SSH access are unaffected
  throughout.

- The pair popup now opens full-screen so the Pairing Code QR has the whole
  terminal to render in. The QR itself is unchanged, so every released app
  version keeps scanning it.

- The pair popup's address checklist now pre-selects a single default address
  instead of every likely one: the address on the platform's primary interface
  (`en0` on macOS, `eth0` on Linux), falling back to the best-ranked private
  LAN, Tailscale, or ULA candidate when that interface is absent.

- The pair popup's QR screen now renders the code starting at the top row and
  trims trailing text to the pane height, so the QR can no longer be clipped
  into scrollback on short terminals.

### Fixed

- Malformed herdr API error responses that carry an empty id now fail the
  originating request immediately with the server's error instead of hanging
  until the request deadline. herdr answers unparseable requests with
  `id: ""`; because each API connection serves one request, that empty id is
  attributable to the sole in-flight request on the connection. (#177)

- On iPad, one window's keyboard no longer ends another window's keyboard
  handoff. Keyboard notifications are process-wide and each window can hold
  a live terminal, so a frame event from one window's keyboard transition
  could unfreeze the other terminal's grid before the keyboard had settled
  for it. A terminal now heeds a transition only for its own keyboard: it
  must be first responder, and a frame event must leave the keyboard
  covering its own window. Process-wide show/hide broadcasts no longer end a
  handoff. (#157; PR #175)

- Attach again withholds generic remote startup and SSH rc chatter until the
  attach command begins. The attach exec prints a short handshake marker
  immediately before `herdr agent attach`, and the client drops everything
  before it. A channel that dies before the handshake still emits the withheld
  text once as the diagnosis. (#166)

- An open Agent terminal no longer stays blank after the app may have suspended.
  Returning at or beyond the Background Grace Period, or after an observed
  suspension, now shows Connecting while the old PTY stops, then opens a new PTY
  Attach with a new terminal surface while preserving links, image actions, and
  pending Paste review. While the Host's replacement snapshot is still loading,
  the session screen also stays on Connecting instead of briefly claiming the
  Agent is gone. Brief trips out of the app keep the existing Attach and do not
  show Connecting. (#141)

- A Host that is reconnecting no longer tells you its Agent has gone. The
  session screen said "This Agent's pane is no longer reported" whenever the
  Agent list emptied, which a dropped connection does exactly as a closed
  pane does — so the app reported a permanent loss at the moment it was
  successfully recovering. It now says the connection dropped and is being
  re-established, and that there is nothing for you to do, which is the
  truth: nothing here needs you. A Host that failed for a reason only you
  can fix still shows what to do about it, and a pane that really did close
  still says so. (#154)

- The app no longer quits outright if two parts of the terminal screen read
  one Attach session at the same time — a stale view left behind by a screen
  transition was enough. The live terminal now keeps running untouched, and
  the duplicate reader is turned away with "Another terminal is already open
  on this Host." and a Reattach button, so the worst case is one surface that
  has to be reopened rather than the whole app disappearing. (#137)

- A turned-away duplicate terminal reader can no longer take the live
  terminal down with it. When the refused reader was a terminal screen, its
  cleanup ended the very session the refusal had just protected, so the
  working terminal went down anyway; and a duplicate reader whose task was
  already cancelled ended the working terminal's output silently, with no
  dialog at all. In both cases the live terminal now keeps running, and the
  refused surface alone shows "Another terminal is already open on this
  Host." with Reattach. (#151, #164; PR #174)

- A Host that fails while you have one of its Agents open now says why on the
  session screen. It used to read "This Agent's pane is no longer reported" —
  blaming the Agent for the Host's problem, and pointing you at the wrong
  thing to fix — because a failed Host empties the Agent list in exactly the
  way a closed pane does. The screen now carries the same connection guidance
  the Host list shows, so a stopped herdr reads as "herdr is not running on
  this Host…" where you are actually looking. A pane that really did close on
  a healthy Host still says so. (#146)

- Cancelling an image upload on a slow connection no longer kills the Host.
  The cleanup that follows a cancelled or failed upload ran on fixed
  two-second budgets, and running out of one was treated as evidence that the
  SSH connection was broken — so on a weak mobile link, cancelling an upload
  silently tore down Events, Attach, and everything else sharing that
  connection, and reported it as "The SSH connection is no longer reusable."
  on whatever you did next. Running out of time is no longer read as a broken
  connection, and the cleanup no longer opens a second connection it may not
  have time to finish. A connection that genuinely dies is still reported as
  dead. (#136)

- A Host that stopped with "herdr is not running on this Host" now recovers on
  its own once you fix it, however long you were away: restart herdr, come
  back to the app, and the Host reconnects without you doing anything else.
  Until now this depended on the length of the trip. Leaving the app for more
  than about twenty seconds tore the connection down, and coming back rebuilt
  it, so that route already worked; a quicker trip — or one where iOS froze
  the app before that teardown could run — did not, and the Host stayed failed
  with no way back but the Retry button. Every return now asks it once. A Host
  that is still broken simply says so again, with the same guidance and
  without flickering through a moment that looks like it reconnected. (#147)

- Coming back to a session after leaving the app no longer shows a connection
  that is already gone. Returning to the foreground now re-proves each Host,
  so one whose link died while you were away starts reconnecting — and says
  so — the moment you look at it, instead of appearing connected for up to
  another half a minute until the keepalive notices. (#142)

- A Host that drops off the network mid-request now reconnects on its own
  instead of stopping with the wrong advice. A severed link failed the same
  way a refused forward does, so Heeler blamed the Host's setup — "herdr is
  not running on this Host. If it is running, check SSH stream-local
  forwarding." — and treated it as something only the user could fix, which
  stops automatic reconnection. A dropped link now reports itself as an
  unavailable connection and retries, while a genuinely disabled forward or a
  stopped herdr still gets the setup advice. (#138)

- Hosts running herdr 0.8.0 connect again. The protocol check demanded the
  exact version this build was generated against, so herdr 0.8.0 (protocol
  19) failed preflight outright even though every method Heeler calls is
  unchanged. Heeler now requires a minimum protocol and accepts anything at
  or above it; a Host newer than this build still connects and simply notes,
  under the checklist, that features added after it may be unavailable. (#140)

- Host event updates now use herdr's socket directly over SSH, remain live
  while ordinary requests run, and recover cleanly when only the Events
  channel drops. Connection failures now lead with "herdr is not running"
  instead of exposing remote socket implementation language. (#117)

- Switching Agents — from the switcher strip, a notification, or right after
  starting a new one — no longer strands the terminal on "Connecting…"
  forever. The synchronous-departure fix let SwiftUI discard the departing
  screen's state before its teardown task ran, and the weakly-captured
  teardown then silently skipped itself: the old session was never closed,
  held the Host's single terminal channel, and every later attach queued
  behind it indefinitely. The teardown now keeps its store alive until the
  session is closed. Two hardenings ride along: a screen the Console no
  longer has on stage refuses to resurrect its terminal on a spurious
  reappearance, and teardown aborts a session still queued for the channel
  instead of waiting its turn.

- The Agent switcher strip and the keyboard toolbar no longer vanish when a
  raised keyboard comes back on its own — returning from the background or
  the lock screen with the keyboard up. Two causes, same round trip: the
  keyboard-height measure required a foreground-active scene while UIKit
  restores the keyboard just before activation, leaving the strip buried
  behind the keyboard; and the toolbar's hide animation was only ever undone
  on an explicit keyboard request, so a restored keyboard wore a transparent
  toolbar.

- The black-terminal-that-never-connects has lost its last hiding place. The
  earlier reattach fix assumed the spurious disappear/appear pair SwiftUI
  hands out arrives with a gap in between; when a notification deep link or
  the new-agent flow's push landed both in one transaction, the deferred
  teardown ran *after* the reattach had already decided there was nothing to
  undo, and the visible screen kept a permanently stopped terminal. The
  departure is now recorded synchronously in `onDisappear`, so the reattach
  on `onAppear` always sees it.

- Agent status colours are readable in light mode. The Working badge painted
  its text in Catppuccin Latte's yellow over a wash of the same yellow, which
  measured 2.3:1 — far under the 4.5:1 that small text needs — and Done's
  green fared little better; the keyboard switcher's status dot missed the
  3:1 an indicator needs on white. Badge text and the dot now use a darker
  ink of the same hue in light mode (dark mode already passed and keeps its
  pastels), so the phone still speaks herdr's colours, just legibly.

- A Host no longer gets stuck offline because one Agent's pane exited. The
  events subscription names each Agent's pane, and herdr rejects the whole
  subscription when a single one of those panes is gone, so a pane that ended
  while the Host was disconnected left every reconnect failing with
  "pane … not found" until the Host was edited or the app restarted. Pane
  subscriptions are now discarded on disconnect and reinstalled from the next
  sync, and a pane that exits mid-subscribe retries straight away instead of
  surfacing as a connection failure. Server rejections also read as herdr's
  own message now, not as a printed Swift value.

- Opening an Agent no longer flashes the Host's login shell across the screen
  first. The attach channel is a login shell, so its banner, its prompt, and
  its echo of the attach command all arrived before the Agent did, painted for
  as long as the attach took to come up, and were then wiped by the Agent's
  first frame. None of it reaches the terminal now, and "Connecting…" stays up
  until the Agent actually paints. If an attach dies before it starts, whatever
  the Host said is still shown — that message is the only diagnosis there is.

- Switching Agents with the keyboard up no longer starts the new terminal at
  full height and shrinks it a moment later, which also sent the "Connecting…"
  dialog jumping from the middle of the screen to the middle of the terminal.
  The keyboard's height now outlives the switch, like the raised keyboard
  itself already did.

- The terminal's status dialog wears the terminal theme instead of a system
  material card, so "Connecting…" and "Session Ended" stop looking like a
  piece of some other app over a Solarized or Nord grid.

- Opening an Agent from a notification no longer sometimes lands on a black
  terminal that never connects. The Attach screen tore its session down on
  every `onDisappear`, including the ones SwiftUI hands out for removals the
  user never made, and the screen that came back afterwards was the same,
  permanently stopped one: no output, no error, no way to reattach short of
  switching Agents. It now reattaches when it comes back, and a screen waiting
  for its terminal says so instead of showing nothing at all.

- The Agent list now removes rows from disconnected Hosts immediately, rejects
  stale snapshots that finish after a disconnect, and rechecks membership when
  an Agent process exits back to an ordinary shell.

- The terminal no longer arrives a beat late after the keyboard is dismissed.
  It now sizes itself to the keyboard directly instead of through SwiftUI's
  avoidance, which retracted in two stages and left the terminal resizing a
  second time — reflowing, resizing the remote PTY, and redrawing the whole
  TUI again — a third of a second after the keyboard had already gone. Raising
  the keyboard settles in one step too, and the app toolbar leaves in sync
  with the keyboard instead of lingering at the bottom of the screen.

### Changed

- Starting a new Agent now opens its terminal as soon as the launch lands,
  instead of dropping back to the Agent list to hunt for the new row.
  Launches made from another Agent's screen switch straight over too.
  (refs #12)

- The Agent detail screen's More menu no longer duplicates Settings; that
  entry stays in the Console toolbar.

- Working agents in the Console list now show a live "solving" orb — a
  dotted sphere whose bands twist and click back into place (ported from
  Jakub Antalik's MIT-licensed thinking-orbs) — instead of the static blue
  Working capsule. Reduced-motion users get a still frame. (PR #106)

- The Agent list now sorts Done above Working and Working above Idle, in the
  Console and in the terminal's Agent row alike, so finished work surfaces
  next to the Blocked agents that still lead the list. Status colours moved
  onto herdr's own palette — green for Done, yellow for Working, red for
  Blocked, grey for Idle — so the phone and the TUI agree on what a colour
  means.

### Added

- The Keys keyboard's three panes — control keys, Snippets, Appearance — now
  swipe. Dragging sideways anywhere on the pane moves it under the finger, the
  tab bar lights the pane being pulled in, and letting go snaps to it; the tabs
  still work as taps. Control keys now send when the finger lifts rather than
  when it lands, so a swipe that starts on Esc switches pane instead of sending
  Esc. Holding a key still repeats.

- Settings now carries an Appearance picker for the app itself: System, Light,
  or Dark. System follows iOS as before and remains the default; the other two
  pin the whole app — Console, sheets, and terminals — to one appearance, and
  the choice sticks across launches.

- Switch Agents without leaving the terminal: a row along the bottom of the
  terminal lists every Agent with its live status — Working agents pulse — and
  scrolls horizontally. It stays put whether the keyboard is up or down, so
  switching Agents no longer means raising the keyboard first, and tapping one
  attaches with the keyboard exactly as it was. A keyboard button pinned at
  the row's trailing edge raises and dismisses the keyboard.

- A dedicated newline button above the iOS keyboard inserts a line break into
  an Agent prompt without pressing Enter or submitting it.

- Hosts now show their live connection state and latest measured ping latency
  in the Hosts list.

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

- Attach no longer leaves a stale-width, non-interactive terminal on screen
  when an SSH input or resize write fails; the broken session now ends and
  preserves the underlying transport error.

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
