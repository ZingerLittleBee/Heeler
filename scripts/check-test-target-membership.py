#!/usr/bin/env python3
"""Check that the committed project builds and runs every app test source.

CI builds the committed Heeler.xcodeproj without regenerating it, and the full
ordinary lane proves only that the tests compiled into HeelerTests executed. A
Swift file under Tests/HeelerTests that the project omits, or a scheme that
skips tests, would drop those tests from every lane without failing one.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = "HeelerTests"


def object_body(project: str, comment: str, isa: str) -> str:
    """The body of the one project object with this comment and type."""
    matches = re.findall(
        r"^\s*[0-9A-F]{24} /\* " + re.escape(comment) + r" \*/ = \{\s*isa = " + isa
        + r";(.*?)^\s*\};", project, re.M | re.S)
    if len(matches) != 1:
        raise ValueError(f"Expected one {isa} named {comment}, found {len(matches)}")
    return matches[0]


def target_sources(project: str, target: str = TARGET) -> set[str]:
    """Names of the files in the target's Sources build phase."""
    phases = re.search(r"buildPhases = \((.*?)\);", object_body(project, target, "PBXNativeTarget"), re.S)
    identifiers = re.findall(r"([0-9A-F]{24}) /\* Sources \*/", phases.group(1) if phases else "")
    if len(identifiers) != 1:
        raise ValueError(f"{target} needs exactly one Sources build phase")
    phase = re.search(
        r"^\s*" + identifiers[0] + r" /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(.*?)^\s*\};",
        project, re.M | re.S)
    if phase is None:
        raise ValueError(f"The {target} Sources build phase is missing")
    return set(re.findall(r"/\* (.+?) in Sources \*/", phase.group(1)))


def scheme_problems(scheme: str, target: str = TARGET) -> list[str]:
    """Ways the shared scheme's test action would leave target tests out."""
    root = ElementTree.fromstring(scheme)
    testables = [testable for testable in root.iterfind("TestAction/Testables/TestableReference")
                 if testable.find(f"BuildableReference[@BlueprintName='{target}']") is not None]
    if len(testables) != 1:
        return [f"the test action has {len(testables)} {target} testables"]
    testable = testables[0]
    problems = []
    if testable.get("skipped") != "NO":
        problems.append(f"{target} is skipped")
    if testable.get("useTestSelectionWhitelist", "NO") != "NO" or testable.find("SelectedTests") is not None:
        problems.append(f"{target} runs only selected tests")
    if testable.find("SkippedTests") is not None:
        problems.append(f"{target} skips tests")
    return problems


def check(root: Path = ROOT) -> int:
    project = (root / "Heeler.xcodeproj/project.pbxproj").read_text()
    scheme = (root / "Heeler.xcodeproj/xcshareddata/xcschemes/Heeler.xcscheme").read_text()
    # Swift rejects two sources with one file name in a module, so names
    # identify the target's sources without resolving project groups.
    sources = sorted(path.name for path in (root / "Tests" / TARGET).rglob("*.swift"))
    missing = sorted(set(sources) - target_sources(project))
    problems = [f"{name} is not compiled into {TARGET}" for name in missing] + scheme_problems(scheme)
    if problems:
        raise ValueError("; ".join(problems) + ". Run make generate and commit Heeler.xcodeproj.")
    return len(sources)


def main() -> int:
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        count = check()
    except (OSError, ValueError, ElementTree.ParseError) as error:
        print(f"Test target membership check failed: {error}", file=sys.stderr)
        return 1
    print(f"Test target membership check passed ({count} {TARGET} Swift sources).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
