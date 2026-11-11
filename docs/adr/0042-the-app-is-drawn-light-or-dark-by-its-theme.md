# 0042: The app is drawn light or dark by its theme

Status: accepted

## Context

Heeler keeps one terminal theme per appearance (`TerminalThemeSettings`), and Settings › Appearance › Mode (System, Light or Dark) picks which appearance is in force. Only terminals used to wear the theme, so a theme that differs from the system's look split the screen: a dark theme for Light Mode left Chat, the sidebar, the Composer and sheets white beside a dark terminal, and on tinted themes the system greys read as a separate colour laid over the theme. Discussed in [#670](https://github.com/ZingerLittleBee/Heeler/issues/670).

## Decision

- The theme of the mode in force is the app's theme. Chat, its diffs and the split view's columns draw on it through `ThemeColors`; the Composer, its Agent strip and chips, and the sidebar's cards and selection are black or white veils over it instead of system materials.
- The window is drawn light or dark as that theme's background is (`TerminalThemeOption.chromeColorScheme`). `appAppearance(_:themes:)` sets the window's `overrideUserInterfaceStyle`, not SwiftUI's `preferredColorScheme`: that overrides the whole scene, and the scene's trait collection is where `SceneAppearance` reads the system's appearance. Theme lookups read `\.themeAppearance`, never `\.colorScheme`, which follows the theme.
- Chat's text keeps the system's label colours rather than the theme's foreground, so controls keep their tint and text its contrast.
- A diff's wash is the change's colour on a grey as light as the background, so a tinted theme cannot cancel red or green, and its foregrounds move toward black or white only as far as 4.5:1 needs. `ThemeColorsTests` checks every catalog theme in both appearances.
- Settings › Appearance puts Mode and the two theme slots in their own Theme section, above Terminal and Chat, because the theme is no longer the terminal's alone. There is no separate switch: the Default theme is light in Light Mode and dark in Dark Mode, so with it the app is lit as the system is.

## Consequences

- A theme for an appearance can make the app dark under a light system, or light under a dark one. A slot nobody chose shows Default in Light Mode and Vesper in Dark Mode, each as light or dark as its appearance, so an untouched app is lit as the system is; an install that never chose a theme, which used to show Vesper in both, now shows Alabaster in Light Mode.
- New chrome draws from `\.themeColors`, or from semantic system colours resolved under the window's override. A fixed system material or grey brings a tint of its own over the theme.
- The Changes screen opened outside Chat keeps its own diff colours; a file diff opened from Chat uses the theme's.
