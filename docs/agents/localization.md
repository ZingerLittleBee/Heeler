# Localization

Use this guide when adding or rewording user-visible text, translating the
String Catalogs, or adding a language. What to localize and what stays a plain
literal is decided in
[ADR 0041](../adr/0041-localize-display-text-where-it-is-created.md).

## Adding or changing text

1. Create display text as a SwiftUI literal or `String(localized:)` where the
   value is made, one whole sentence per key. Add a `comment` when the English
   alone does not say where the text shows or what a placeholder holds.
2. Word it so a translator needs only the catalog:
   - A count is an argument of the key (`"\(files) files"`). English's
     singular goes in that key's `en` plural variation (`one`: `%lld file`)
     rather than an `n == 1` branch in code.
   - Close a sentence with `asSentence`, test for a closing mark with
     `endsSentence`, and join short phrases with `joinedAsPhrases()`
     ([LocalizedPhrasing](../../Sources/Heeler/Support/LocalizedPhrasing.swift)).
     Durations, dates and numbers use Foundation format styles.
   - When one English word means two things, such as the Agent status Done
     and a Done button, one of them gets its own key:
     `String(localized: "Agent status Done", defaultValue: "Done")`.
3. Build, then sync and check the catalog. Only Xcode's IDE updates
   `Localizable.xcstrings` on build; a command-line build needs the sync.

   ```sh
   python3 scripts/check-localizations.py --sync build/DerivedData-simulator
   ```

   The sync runs Xcode's `xcstringstool sync`: it adds the keys code uses,
   marks keys no code uses `stale` (delete those entries), copies comments and
   default values from code, and marks a translation `needs_review` when its
   English changes (check it, then set it back to `translated`). The check
   then reports how many keys each language still shows in English
   (`--list <language>` names them). It fails on a translation whose format
   specifiers differ from the English, and on a permission prompt missing in a
   language. `make test-tools` runs the same check.
4. Translations may land in the same pull request or a later one; until then
   the key shows its English text.

## Translating

Edit only catalog values: `localizations.<language>.stringUnit`, with
`state` set to `translated`.

- Keep every format specifier of the English text with its type. Reorder with
  positional forms (`%2$@ の %1$lld 個`), numbering every specifier in that
  value.
- Keep leading and trailing whitespace; such a value sits beside other text.
- A language with plural forms gives a count key `variations.plural` in its own
  localization; one without them uses a single `stringUnit`.
- Leave `shouldTranslate: false` keys alone. They are matched against what
  other programs print.
- Permission prompts (`NS…UsageDescription` in `InfoPlist.xcstrings`) are
  translated in every language Heeler ships, because iOS shows them before the
  app can explain anything.

## Adding a language

No Swift change is needed: Settings › Language opens Heeler's page in iOS
Settings, which lists every language in the app bundle.

1. Add the language's values to `Localizable.xcstrings` and
   `InfoPlist.xcstrings`. The permission prompts are required; other keys may
   follow later.
2. Run `make generate`. XcodeGen adds the language to the project's
   `knownRegions` from the catalogs; commit the regenerated project.
3. Run `python3 scripts/check-localizations.py`, then the localization suites
   under the new language:

   ```sh
   TEST_FLAGS="-testLanguage zh-Hans -testRegion CN \
     -only-testing:HeelerTests/LocalizationBundleTests \
     -only-testing:HeelerTests/ConsoleRestLocalizationTests" \
     python3 scripts/run-app-simulator-tests.py -project Heeler.xcodeproj -scheme Heeler \
     -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
     -derivedDataPath build/DerivedData-simulator test
   ```

   These suites iterate every language in the bundle, so the new one joins
   them without a test change. A glossary that fixes the status words can add
   them to `statusWordsFollowTheGlossary`.
4. Add a `CHANGELOG.md` entry.
