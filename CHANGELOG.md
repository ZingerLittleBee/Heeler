# Changelog

All notable changes to herdr-mobile are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries reference the pull request that landed them.

## [Unreleased]

### Added

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

### Fixed

- Tapping the terminal body no longer toggles the software keyboard. Ghostty's
  touch handling raised and dismissed the keyboard on any touch once it had
  been raised once, including after returning from a short backgrounding; both
  paths are now gated behind the input-row tap policy. (#95)
- The keyboard tap target in full-screen agent TUIs is now a wider caret band
  plus the bottom quarter of the screen, instead of the whole surface — output
  areas stay inert while every chat TUI's pinned input box remains hittable,
  whichever tool draws it. (#95, refs #90)
