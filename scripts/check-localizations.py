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
IDE. `--sync` does the same from the `.stringsdata` files a command-line build
leaves in DerivedData: it adds the keys the code uses, marks keys no code uses
any more stale, and copies comments and default values from the code.

    python3 scripts/check-localizations.py                  # summary per language
    python3 scripts/check-localizations.py --list zh-Hans   # and its untranslated keys
    python3 scripts/check-localizations.py --sync build/DerivedData-simulator
"""

from __future__ import annotations

import argparse
import json
import re
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


def emitted(derived_data: Path) -> dict[str, dict]:
    """The Localizable keys a build extracted, with their comments and default values.

    A `.stringsdata` file outlives its source file in DerivedData, so files
    whose source is gone are skipped.
    """
    strings: dict[str, dict] = {}
    build = derived_data / "Build" / "Intermediates.noindex"
    for target in CATALOG_TARGETS:
        for path in sorted(build.glob(f"*.build/*/{target}.build/**/*.stringsdata")):
            data = json.loads(path.read_text(encoding="utf-8"))
            if not Path(data.get("source", "")).exists():
                continue
            for item in data.get("tables", {}).get("Localizable", []):
                found = strings.setdefault(item["key"], {"comments": set(), "values": set()})
                if item.get("comment"):
                    found["comments"].add(item["comment"])
                if item.get("value") is not None and item["value"] != item["key"]:
                    found["values"].add(item["value"])
    return strings


def sync(derived_data: Path, root: Path = ROOT, out=sys.stdout) -> int:
    """Bring Localizable.xcstrings in line with the build's strings; return 1 if none were found."""
    used = emitted(derived_data)
    if not used:
        print(f"error: no .stringsdata for {', '.join(CATALOG_TARGETS)} under {derived_data}; "
              "build the app first", file=out)
        return 1
    path = root / LOCALIZABLE
    catalog, newline = load(path)
    strings = catalog["strings"]
    source_language = catalog.get("sourceLanguage", "en")
    added, revived, retired, changed = [], [], [], []

    for key, found in sorted(used.items()):
        entry = strings.get(key)
        if entry is None:
            entry = strings[key] = {}
            added.append(key)
        elif entry.get("extractionState") == "stale":
            del entry["extractionState"]
            revived.append(key)
        before = json.dumps(entry, sort_keys=True)
        if found["comments"]:
            entry["comment"] = "\n".join(sorted(found["comments"]))
        if len(found["values"]) == 1:
            value = next(iter(found["values"]))
            entry["extractionState"] = "extracted_with_value"
            unit = entry.setdefault("localizations", {}).setdefault(source_language, {}).setdefault("stringUnit", {})
            if unit.get("value") != value:
                unit.update(state="new", value=value)
        if key not in added and json.dumps(entry, sort_keys=True) != before:
            changed.append(key)

    for key, entry in strings.items():
        if key not in used and entry.get("extractionState") not in ("manual", "stale"):
            entry["extractionState"] = "stale"
            retired.append(key)

    path.write_text(dump(catalog, newline), encoding="utf-8")
    for label, keys in (("added", added), ("in use again", revived), ("stale", retired),
                        ("comment or default value updated", changed)):
        print(f"{len(keys)} {label}", file=out)
        for key in keys:
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
