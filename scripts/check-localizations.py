#!/usr/bin/env python3
"""Check Heeler's String Catalogs, and sync them with a build's strings.

Heeler ships English plus every language its catalogs hold. A new string may
ship in English until someone translates it (ADR 0041), so an untranslated key
is reported, never failed. The check fails on what breaks a shipped language:
a translation whose format specifiers differ from its English source, which
garbles the text or crashes when it is formatted, and a permission prompt
(an `NS…UsageDescription` in InfoPlist.xcstrings) missing in a language,
which iOS would show in English.

Xcode syncs Localizable.xcstrings with the code only when it builds in the
IDE. `--sync` runs Xcode's `xcstringstool sync` on the `.stringsdata` files a
command-line build leaves in DerivedData, so the catalog gains the keys the
code uses and marks the rest stale, as an IDE build would.

    python3 scripts/check-localizations.py                  # summary per language
    python3 scripts/check-localizations.py --list zh-Hans   # and its untranslated keys
    python3 scripts/check-localizations.py --sync build/DerivedData-simulator
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = Path("Sources/Heeler/Resources")
LOCALIZABLE = RESOURCES / "Localizable.xcstrings"
INFO_PLIST = RESOURCES / "InfoPlist.xcstrings"
# The targets whose resources include Localizable.xcstrings (project.yml).
CATALOG_TARGETS = ("Heeler", "HeelerWidgets", "HeelerNotificationService")

# Info.plist purpose strings, which iOS shows in its permission prompts.
PERMISSION_PROMPT = re.compile(r"NS\w+UsageDescription")
SPECIFIER = re.compile(
    r"%(?:(\d+)\$)?[-+0#']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])")


def load(path: Path) -> tuple[dict, bool]:
    """The catalog, and whether its file ends with a newline."""
    text = path.read_text(encoding="utf-8")
    return json.loads(text), text.endswith("\n")


def dump(catalog: dict, newline: bool) -> str:
    """The catalog as Xcode writes it, so a sync leaves an unchanged key's lines alone."""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
    return text + "\n" if newline else text


def specifiers(text: str) -> list[tuple[int | None, str]]:
    """The text's format specifiers in order, as (position, type); `%%` is a literal."""
    return [(int(match.group(1)) if match.group(1) else None, (match.group(2) or "") + match.group(3))
            for match in SPECIFIER.finditer(text.replace("%%", ""))]


def specifiers_match(source: str, value: str) -> bool:
    """Whether `value` formats the same arguments as `source`, in order or positionally."""
    expected = [kind for _, kind in specifiers(source)]
    found = specifiers(value)
    if not any(position for position, _ in found):
        return [kind for _, kind in found] == expected
    positions = [position for position, _ in found]
    if None in positions or sorted(positions) != list(range(1, len(expected) + 1)):
        return False
    return all(expected[position - 1] == kind for position, kind in found)


def leaves(localization: dict, path: str = "") -> list[tuple[str, dict]]:
    """Every string unit of one language's localization, through any variations."""
    found = []
    if "stringUnit" in localization:
        found.append((path, localization["stringUnit"]))
    for kind, cases in localization.get("variations", {}).items():
        for case, nested in cases.items():
            found += leaves(nested, f"{path}/{kind}.{case}")
    return found


def source_text(key: str, entry: dict, source_language: str) -> str:
    """What the key says in the source language: its own value, or the key itself."""
    units = dict(leaves(entry.get("localizations", {}).get(source_language, {})))
    unit = units.get("") or units.get("/plural.other") or next(iter(units.values()), None)
    return unit.get("value", key) if unit else key


def translatable(catalog: dict) -> dict[str, dict]:
    return {key: entry for key, entry in catalog["strings"].items()
            if entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"}


def languages(catalog: dict) -> list[str]:
    source = catalog.get("sourceLanguage", "en")
    return sorted({language for entry in catalog["strings"].values()
                   for language in entry.get("localizations", {})} - {source})


def is_translated(localization: dict | None) -> bool:
    units = leaves(localization or {})
    return bool(units) and all(unit.get("state") == "translated" and unit.get("value") for _, unit in units)


def specifier_errors(catalog: dict, name: str) -> list[str]:
    """Translations that would format different arguments than their source."""
    source_language = catalog.get("sourceLanguage", "en")
    errors = []
    for key, entry in catalog["strings"].items():
        source = source_text(key, entry, source_language)
        for language, localization in entry.get("localizations", {}).items():
            if language == source_language:
                continue
            for path, unit in leaves(localization):
                value = unit.get("value", "")
                # A plural case may name its count in words ("once"); every
                # other case formats the source's arguments.
                if path.startswith("/plural.") and not specifiers(value):
                    continue
                if not specifiers_match(source, value):
                    errors.append(f"{name} {language}{path}: {key!r} => {value!r}")
    return errors


def check(root: Path = ROOT, list_language: str | None = None, out=sys.stdout) -> int:
    """Print what each language covers; return the number of failures."""
    localizable, _ = load(root / LOCALIZABLE)
    info_plist, _ = load(root / INFO_PLIST)
    errors = specifier_errors(localizable, LOCALIZABLE.name) + specifier_errors(info_plist, INFO_PLIST.name)

    keys = translatable(localizable)
    stale = sum(1 for entry in localizable["strings"].values() if entry.get("extractionState") == "stale")
    print(f"{LOCALIZABLE.name}: {len(keys)} keys to translate"
          + (f", {stale} stale (no code uses them; remove them)" if stale else ""), file=out)
    for language in languages(localizable):
        missing = sorted(key for key, entry in keys.items()
                         if not is_translated(entry.get("localizations", {}).get(language)))
        note = f", {len(missing)} in English until translated" if missing else ""
        print(f"  {language:<8} {len(keys) - len(missing)} translated{note}", file=out)
        if language == list_language:
            for key in missing:
                print(f"    {key!r}", file=out)

    prompts = {key: entry for key, entry in translatable(info_plist).items() if PERMISSION_PROMPT.match(key)}
    for language in sorted(set(languages(info_plist)) | set(languages(localizable))):
        for key, entry in sorted(prompts.items()):
            if not is_translated(entry.get("localizations", {}).get(language)):
                errors.append(f"{INFO_PLIST.name} {language}: {key} is not translated; "
                              "iOS shows permission prompts in every shipped language")

    for error in errors:
        print(f"error: {error}", file=out)
    return len(errors)


def stringsdata(derived_data: Path) -> list[Path]:
    """The `.stringsdata` files a build left for the targets that compile the catalog.

    One outlives its source file in DerivedData, so a file whose source is gone
    is left out; its strings would otherwise never turn stale.
    """
    build = derived_data / "Build" / "Intermediates.noindex"
    found = []
    for target in CATALOG_TARGETS:
        for path in sorted(build.glob(f"*.build/*/{target}.build/**/*.stringsdata")):
            source = json.loads(path.read_text(encoding="utf-8")).get("source", "")
            if source and Path(source).exists():
                found.append(path)
    return found


def sync(derived_data: Path, root: Path = ROOT, out=sys.stdout, run=subprocess.run) -> int:
    """Sync Localizable.xcstrings with the build's strings as Xcode does; return 1 on failure.

    `xcstringstool sync` adds the keys code uses, marks the rest stale, copies
    comments and default values, and marks a translation `needs_review` when
    its English changes. The file then keeps the repository's formatting.
    """
    files = stringsdata(derived_data)
    if not files:
        print(f"error: no .stringsdata for {', '.join(CATALOG_TARGETS)} under {derived_data}; "
              "build the app first", file=out)
        return 1
    path = root / LOCALIZABLE
    before, newline = load(path)
    command = ["xcrun", "xcstringstool", "sync", str(path)]
    for file in files:
        command += ["--stringsdata", str(file)]
    try:
        result = run(command, capture_output=True, text=True)
    except FileNotFoundError:
        print("error: xcrun not found; the sync needs Xcode", file=out)
        return 1
    if result.returncode != 0:
        path.write_text(dump(before, newline), encoding="utf-8")
        print(f"error: xcstringstool sync failed: {result.stderr.strip()}", file=out)
        return 1
    after, _ = load(path)
    path.write_text(dump(after, newline), encoding="utf-8")

    old, new = before["strings"], after["strings"]
    def state(entry: dict | None) -> str | None:
        return (entry or {}).get("extractionState")
    report = (
        ("added", [key for key in new if key not in old]),
        ("stale (delete them once no code needs them)",
         [key for key in new if state(new[key]) == "stale" and state(old.get(key)) != "stale"]),
        ("in use again", [key for key in new if state(old.get(key)) == "stale" and state(new[key]) != "stale"]),
        ("changed", [key for key in new if key in old and new[key] != old[key]
                     and (state(new[key]) == "stale") == (state(old[key]) == "stale")]),
    )
    for label, keys in report:
        print(f"{len(keys)} {label}", file=out)
        for key in sorted(keys):
            print(f"  {key!r}", file=out)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--list", metavar="LANGUAGE", help="also list the language's untranslated keys")
    parser.add_argument("--sync", metavar="DERIVED_DATA", type=Path,
                        help="first sync Localizable.xcstrings with this DerivedData's last build")
    arguments = parser.parse_args(argv)
    if arguments.sync is not None and sync(arguments.sync):
        return 1
    return 1 if check(list_language=arguments.list) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
