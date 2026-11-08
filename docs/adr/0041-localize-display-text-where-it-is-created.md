# 0041: Localize display text where it is created

Status: accepted

## Context

Heeler ships English and Japanese. Much of its chrome is not SwiftUI literals: banners, Blocked card reasons, Chat notices, error presentations, menu actions, VoiceOver text and widget copy are `String` values built in stores, parsers and reducers, often far from the view that shows them. Many other strings look like display text but are compared with what a program prints: Claude Code, Codex, Grok Build, Oh My Pi and OpenCode screens and transcripts, herdr and EasyTier status lines, HTTP headers, theme and font identifiers. These programs print English whatever the device language is.

## Decision

Translations live in two String Catalogs, `Sources/Heeler/Resources/Localizable.xcstrings` and `InfoPlist.xcstrings`, with English as the source language. `SWIFT_EMIT_LOC_STRINGS` lets builds and Xcode list the keys code emits. The widget and notification-service extensions compile the same `Localizable.xcstrings`, because an extension only localizes against resources in its own bundle.

- SwiftUI literals (`Text("…")`, `Button("…")`) localize themselves. Any other text a person sees is created with `String(localized:)` where the value is made, as one complete sentence per key with placeholders. Code never assembles a sentence from separately localized pieces or inserts untranslated English words into a localized one.
- A string that is matched, looked up, persisted, typed into a program or sent over a protocol stays a plain literal. When one value is both shown and compared, logic keeps a stable token or enum and only the shown form is localized. A localized match token breaks only under Japanese, and the English test suite cannot see it.
- Developer text (crash messages, logs, previews, empty strings) is not localized.
- `String(localized:)` resolves when the value is created, so a language change applies to values created afterwards; iOS relaunches the app when its per-app language changes. Display text written to disk carries the language it was written in: a Chat cache document records the localization its entries are worded in, and one in another language still shows (a Saved Chat's messages live only there) but never joins rows read now, so the next save words it anew; and the Usage widget snapshot stores why a Host is left out as a token that the widget names in its own language. The snapshot's limit notes and window names are written as text and follow a language change when the app next writes the snapshot.
- Agent content, program names, commands, paths, and Agent rows a Host renders into a Live Activity keep their original form.
- `InfoPlist.xcstrings` keeps each usage description `extracted_with_value` with its English value from `project.yml`. A manual entry without English compiles to an English table that maps the key to its own name, which iOS would show in the permission prompt.
- Tests run in English (`language: en` in the schemes). `xcodebuild -testLanguage ja` runs a suite under Japanese to check that comparisons do not depend on the language.

## Consequences

A new user-visible string falls back to English until its Japanese entry exists, so a change that adds UI text adds the `ja` value in the same pull request. Keys that code no longer emits become stale when Xcode syncs the catalog and are removed. `LocalizationBundleTests` checks the compiled bundle: permission prompts resolve to their purpose strings, and every Japanese value keeps its key's format specifiers.
