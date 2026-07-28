# Changelog

All notable changes to herdr-mobile are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries reference the issue that motivated them.

## [Unreleased]

### Added

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
  plus links to herdr.dev and the privacy policy.
- Rename Agents and workspaces from the Agent detail screen's menu. Agent
  names follow the server's rule (lowercase letters, digits, `-`/`_`, up to
  32 characters) with inline validation, and leaving the name empty falls
  back to the detected kind. (#98)
- Start an Agent in a fresh git worktree: a "Start in a new worktree" toggle
  on the New Agent form gives the task a clean checkout of the selected
  workspace's repository, with optional branch (validated inline) and base;
  empty fields use herdr's generated `worktree/` branch off HEAD. (#97)

### Changed

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

- Tapping the terminal body no longer toggles the software keyboard. Ghostty's
  touch handling raised and dismissed the keyboard on any touch once it had
  been raised once, including after returning from a short backgrounding; both
  paths are now gated behind the input-row tap policy. (#95)
- The keyboard tap target in full-screen agent TUIs is now a wider caret band
  plus the bottom quarter of the screen, instead of the whole surface — output
  areas stay inert while every chat TUI's pinned input box remains hittable,
  whichever tool draws it. (#95, refs #90)
