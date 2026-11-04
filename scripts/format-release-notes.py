#!/usr/bin/env python3
"""Join CHANGELOG bullet wrapping before GitHub renders it as hard breaks."""

import re
import sys


def format_notes(text: str) -> str:
    """Unwrap two-space prose continuations, preserving Markdown blocks."""
    output: list[str] = []
    in_bullet = False
    fence = None
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        stripped = content.lstrip()
        marker = re.match(r"(`{3,}|~{3,})", stripped)
        if fence:
            output.append(line)
            if re.fullmatch(re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", stripped):
                fence = None
            continue
        if marker:
            fence = marker[1]
            in_bullet = False
        elif re.match(r"[-+*] \S", content):
            in_bullet = True
        elif (
            in_bullet
            and re.match(r"^  \S", content)
            and not re.match(r"(?:[-+*] |1[.)] |#{1,6} |>|\||[-*_]{3,}\s*$)", stripped)
            and not output[-1].rstrip("\r\n").endswith(("  ", "\\"))
        ):
            output[-1] = output[-1].rstrip("\r\n") + " " + line[2:]
            continue
        else:
            in_bullet = False
        output.append(line)
    return "".join(output)


if __name__ == "__main__":
    sys.stdout.write(format_notes(sys.stdin.read()))
