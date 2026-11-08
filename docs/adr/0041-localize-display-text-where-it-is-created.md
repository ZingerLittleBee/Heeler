# 0041: Localize display text where it is created

Status: accepted

## Context

Heeler ships English, Japanese and Simplified Chinese (amended 2026-11-08, when Simplified Chinese was added). Much of its chrome is not SwiftUI literals: banners, Blocked card reasons, Chat notices, error presentations, menu actions, VoiceOver text and widget copy are `String` values built in stores, parsers and reducers, often far from the view that shows them. Many other strings look like display text but are compared with what a program prints: Claude Code, Codex, Grok Build, Oh My Pi and OpenCode screens and transcripts, herdr and EasyTier status lines, HTTP headers, theme and font identifiers. These programs print English whatever the device language is.

## Decision

Translations live in two String Catalogs, `Sources/Heeler/Resources/Localizable.xcstrings` and `InfoPlist.xcstrings`, with English as the source language. `SWIFT_EMIT_LOC_STRINGS` lets builds and Xcode list the keys code emits. The widget and notification-service extensions compile the same `Localizable.xcstrings`, because an extension only localizes against resources in its own bundle.

- SwiftUI literals (`Text("…")`, `Button("…")`) localize themselves. Any other text a person sees is created with `String(localized:)` where the value is made, as one complete sentence per key with placeholders. Code never assembles a sentence from separately localized pieces or inserts untranslated English words into a localized one.
- A string that is matched, looked up, persisted, typed into a program or sent over a protocol stays a plain literal. When one value is both shown and compared, logic keeps a stable token or enum and only the shown form is localized. A localized match token breaks only under a translation, and the English test suite cannot see it.
- Code names no language (amended 2026-11-08), so a language is added by catalog values alone. A count is an argument of its key, with English's singular in the catalog's plural variation; a sentence is closed or tested for its closing mark, and short phrases are joined, through [LocalizedPhrasing](../../Sources/Heeler/Support/LocalizedPhrasing.swift), which reads the mark from Unicode rather than listing `.` and `。`; durations, dates and numbers use Foundation format styles. One English word with two meanings, such as the Agent status Done and a Done button, gets a second key through `String(localized:defaultValue:)`.
- Developer text (crash messages, logs, previews, empty strings) is not localized.
- `String(localized:)` resolves when the value is created, so a language change applies to values created afterwards; iOS relaunches the app when its per-app language changes. Display text written to disk carries the language it was written in: a Chat cache document records the localization its entries are worded in, and one in another language still shows (a Saved Chat's messages live only there) but never joins rows read now, so the next save words it anew; and the Usage widget snapshot stores why a Host is left out as a token that the widget names in its own language. The snapshot's limit notes and window names are written as text and follow a language change when the app next writes the snapshot.
- Agent content, program names, commands, paths, and Agent rows a Host renders into a Live Activity keep their original form.
- `InfoPlist.xcstrings` keeps each usage description `extracted_with_value` with its English value from `project.yml`. A manual entry without English compiles to an English table that maps the key to its own name, which iOS would show in the permission prompt.
- Tests run in English (`language: en` in the schemes). `xcodebuild -testLanguage <language>` runs a suite under a translation to check that comparisons do not depend on the language.

## Consequences

A new user-visible string shows in English until a language translates it, and translations may follow in a later pull request (amended 2026-11-08; the `ja` value used to land with the string). Permission prompts are the exception: every shipped language translates them. `scripts/check-localizations.py`, run by `make test-tools`, reports each language's untranslated keys and fails on a changed format specifier or an untranslated permission prompt; its `--sync` brings `Localizable.xcstrings` in line with a command-line build, which Xcode syncs only in the IDE. Keys that code no longer emits become stale and are removed. `LocalizationBundleTests` checks the compiled bundle: every language it holds ships its table and resolves the permission prompts to their purpose strings. [docs/agents/localization.md](../agents/localization.md) is the runbook for new text and new languages.
