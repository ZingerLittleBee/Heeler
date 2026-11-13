#!/usr/bin/env python3
"""Summarize a Heeler performance trace (see docs/agents/performance-tracing.md).

The app writes one JSON Lines file per launch under its container's
Library/Caches/PerfTrace when started with --perf-trace. Pass a file, or
--udid to read the newest one from a Simulator's installed app.

  python3 scripts/perf-trace-summary.py --udid <simulator-udid>
  python3 scripts/perf-trace-summary.py trace.jsonl --since 1762850000 --until 1762850060
  python3 scripts/perf-trace-summary.py trace.jsonl --json

Times are milliseconds. A hitch is a frame that came at least half a frame
late; "over" is how late. Stacks are the main thread's, sampled while a frame
was overdue, innermost frame first.
"""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import shutil
import subprocess
import sys

BUNDLE_ID = "dev.bybee.heeler"
APP_IMAGES = ("Heeler", "Heeler.debug.dylib")


def newest_trace(udid: str) -> pathlib.Path:
    container = subprocess.run(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    traces = sorted(pathlib.Path(container, "Library", "Caches", "PerfTrace").glob("perf-*.jsonl"))
    if not traces:
        raise SystemExit(f"no trace under {container}/Library/Caches/PerfTrace; launch with --perf-trace")
    return traces[-1]


def load(path: pathlib.Path, since: float | None, until: float | None) -> list[dict]:
    records = []
    with path.open(encoding="utf-8") as lines:
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                # The app may be mid-write on the last line.
                continue
            time = record.get("t", 0)
            if record.get("k") != "launch":
                if since is not None and time < since:
                    continue
                if until is not None and time > until:
                    continue
            records.append(record)
    return records


def demangle(names: list[str]) -> dict[str, str]:
    """Swift symbols, readable. The trace keeps them mangled so the app
    needs no demangler."""
    mangled = sorted({name for name in names if name.startswith(("$s", "_$s", "$S", "_T0"))})
    if not mangled or not shutil.which("xcrun"):
        return {}
    try:
        output = subprocess.run(
            ["xcrun", "swift-demangle", "--simplified"],
            input="\n".join(mangled), check=True, capture_output=True, text=True,
        ).stdout.splitlines()
    except (subprocess.CalledProcessError, OSError):
        return {}
    return dict(zip(mangled, output)) if len(output) == len(mangled) else {}


def split_frame(frame: str) -> tuple[str, str]:
    image, _, rest = frame.partition(" ")
    symbol = rest.rsplit("+", 1)[0] if "+" in rest else rest
    return image, symbol


def is_entry_point(symbol: str) -> bool:
    return symbol in ("main", "__debug_main_executable_dylib_entry_point") or symbol.endswith("5$mainyyFZ")


def summarize(records: list[dict], top: int) -> dict:
    launch = next((record for record in records if record.get("k") == "launch"), None)
    stats = [record for record in records if record.get("k") == "stat"]
    hitches = [record for record in records if record.get("k") == "hitch"]
    intervals = [record for record in records if record.get("k") == "interval"]
    events = [record for record in records if record.get("k") == "event"]

    seconds = sum(record.get("window", 0) for record in stats) / 1000
    frames = sum(record.get("frames", 0) for record in stats)
    scroll_frames = sum(record.get("scrollFrames", 0) for record in stats)
    busy = sum(record.get("busyMs", 0) for record in stats)

    def hitch_group(group: list[dict]) -> dict:
        overs = sorted(record.get("over", 0) for record in group)
        return {
            "count": len(group),
            "over_ms": round(sum(overs), 1),
            "worst_ms": round(max((record.get("ms", 0) for record in group), default=0), 1),
            "over_100ms": sum(1 for record in group if record.get("ms", 0) >= 100),
            "over_250ms": sum(1 for record in group if record.get("ms", 0) >= 250),
            "median_over_ms": round(overs[len(overs) // 2], 1) if overs else 0,
        }

    scrolling = [record for record in hitches if record.get("scroll")]
    resting = [record for record in hitches if not record.get("scroll")]
    in_chat = [record for record in hitches if (record.get("ctx") or {}).get("chat")]

    # What ran in late frames, and what ran at all.
    hitch_spans: dict[str, dict] = collections.defaultdict(lambda: {"hitches": 0, "ms": 0.0, "max": 0.0, "runs": 0})
    for record in hitches:
        for span in record.get("spans") or []:
            entry = hitch_spans[span["n"]]
            entry["hitches"] += 1
            entry["ms"] += span["ms"]
            entry["runs"] += span["c"]
            entry["max"] = max(entry["max"], span["max"])
    all_spans: dict[str, dict] = collections.defaultdict(lambda: {"runs": 0, "ms": 0.0, "max": 0.0})
    counts: collections.Counter[str] = collections.Counter()
    peak_counts: dict[str, int] = collections.defaultdict(int)
    for record in stats:
        for span in record.get("spans") or []:
            entry = all_spans[span["n"]]
            entry["runs"] += span["c"]
            entry["ms"] += span["ms"]
            entry["max"] = max(entry["max"], span["max"])
        for name, amount in (record.get("counts") or {}).items():
            counts[name] += amount
            peak_counts[name] = max(peak_counts[name], amount)

    # How much of each late frame the spans explain.
    explained = unexplained = 0.0
    for record in hitches:
        spans = record.get("spans") or []
        # Nested spans share time; the longest one stands for the frame.
        covered = max((span["ms"] for span in spans), default=0.0)
        explained += min(covered, record.get("ms", 0))
        unexplained += max(record.get("ms", 0) - covered, 0)

    leaf: collections.Counter[str] = collections.Counter()
    leaf_image: collections.Counter[str] = collections.Counter()
    app_frame: collections.Counter[str] = collections.Counter()
    app_inclusive: collections.Counter[str] = collections.Counter()
    samples = 0
    symbols: list[str] = []
    for record in hitches:
        for stack in record.get("stacks") or []:
            frames_ = stack.get("f") or []
            if not frames_:
                continue
            samples += 1
            image, symbol = split_frame(frames_[0])
            leaf[f"{image} {symbol}"] += 1
            leaf_image[image] += 1
            symbols.append(symbol)
            # The process's entry points are in every stack and name nothing.
            ours = [split_frame(frame)[1] for frame in frames_ if split_frame(frame)[0] in APP_IMAGES]
            ours = [symbol for symbol in ours if not is_entry_point(symbol)]
            symbols.extend(ours)
            app_frame[ours[0] if ours else "(system frames only)"] += 1
            for symbol in set(ours):
                app_inclusive[symbol] += 1
    readable = demangle(symbols)

    def named(key: str) -> str:
        image, _, symbol = key.partition(" ")
        if symbol:
            return f"{image} {readable.get(symbol, symbol)}"
        return readable.get(key, key)

    interval_totals: dict[str, dict] = collections.defaultdict(lambda: {"count": 0, "ms": 0.0, "max": 0.0})
    for record in intervals:
        entry = interval_totals[record.get("n", "?")]
        entry["count"] += 1
        entry["ms"] += record.get("ms", 0)
        entry["max"] = max(entry["max"], record.get("ms", 0))

    worst = sorted(hitches, key=lambda record: -record.get("ms", 0))[:top]

    def ranked(table: dict[str, dict], key: str) -> list[dict]:
        rows = [{"name": name, **{k: round(v, 1) if isinstance(v, float) else v for k, v in entry.items()}}
                for name, entry in table.items()]
        return sorted(rows, key=lambda row: -row[key])[:top]

    return {
        "launch": (launch or {}).get("info"),
        "seconds": round(seconds, 1),
        "frames": frames,
        "scroll_frames": scroll_frames,
        "fps": round(frames / seconds, 1) if seconds else 0,
        "main_busy_percent": round(busy / (seconds * 10), 1) if seconds else 0,
        "hitch_ms_per_s": round(sum(record.get("over", 0) for record in hitches) / seconds, 1) if seconds else 0,
        "hitches": {
            "all": hitch_group(hitches),
            "while_scrolling": hitch_group(scrolling),
            "at_rest": hitch_group(resting),
            "chat_shown": hitch_group(in_chat),
        },
        "explained_ms": round(explained, 1),
        "unexplained_ms": round(unexplained, 1),
        "spans_in_hitches": ranked(hitch_spans, "ms"),
        "spans_overall": ranked(all_spans, "ms"),
        "counts": [
            {"name": name, "total": total, "per_s": round(total / seconds, 1) if seconds else 0,
             "peak_per_s": peak_counts[name]}
            for name, total in counts.most_common(top)
        ],
        "intervals": ranked(interval_totals, "ms"),
        "stack_samples": samples,
        "stack_leaf": [{"frame": named(name), "samples": n} for name, n in leaf.most_common(top)],
        "stack_leaf_image": [{"frame": name, "samples": n} for name, n in leaf_image.most_common(top)],
        "stack_app_frame": [{"frame": readable.get(name, name), "samples": n} for name, n in app_frame.most_common(top)],
        "stack_app_inclusive": [
            {"frame": readable.get(name, name), "samples": n} for name, n in app_inclusive.most_common(top)
        ],
        "worst": [
            {
                "t": record.get("t"),
                "ms": record.get("ms"),
                "scroll": record.get("scroll"),
                "ctx": record.get("ctx"),
                "spans": [f'{span["n"]} {span["ms"]}ms x{span["c"]}' for span in (record.get("spans") or [])[:4]],
                "counts": record.get("counts"),
                "stacks": len(record.get("stacks") or []),
            }
            for record in worst
        ],
        "events": len(events),
    }


def show(summary: dict) -> None:
    info = summary["launch"] or {}
    if info:
        print("launch: " + " ".join(f"{key}={value}" for key, value in sorted(info.items())))
    print(
        f'{summary["seconds"]} s traced, {summary["frames"]} frames ({summary["fps"]} fps), '
        f'{summary["scroll_frames"]} while scrolling, main thread awake {summary["main_busy_percent"]}%'
    )
    print(f'hitch time: {summary["hitch_ms_per_s"]} ms/s')
    print("\nhitches               count   over ms  median  worst  >=100ms  >=250ms")
    for label, key in (("all", "all"), ("while scrolling", "while_scrolling"), ("at rest", "at_rest"),
                       ("Chat on screen", "chat_shown")):
        group = summary["hitches"][key]
        print(
            f'  {label:<18} {group["count"]:>6} {group["over_ms"]:>9} {group["median_over_ms"]:>7} '
            f'{group["worst_ms"]:>6} {group["over_100ms"]:>8} {group["over_250ms"]:>8}'
        )
    print(
        f'\nlate-frame time the spans cover: {summary["explained_ms"]} ms; not covered: '
        f'{summary["unexplained_ms"]} ms'
    )

    def table(title: str, rows: list[dict], columns: list[tuple[str, str]]) -> None:
        if not rows:
            return
        print(f"\n{title}")
        print("  " + "  ".join(f"{heading:>9}" for heading, _ in columns) + "  name")
        for row in rows:
            print("  " + "  ".join(f"{row[key]:>9}" for _, key in columns) + f'  {row["name"]}')

    table("spans in late frames", summary["spans_in_hitches"],
          [("ms", "ms"), ("hitches", "hitches"), ("runs", "runs"), ("max", "max")])
    table("spans overall", summary["spans_overall"], [("ms", "ms"), ("runs", "runs"), ("max", "max")])
    table("counts", summary["counts"], [("total", "total"), ("per s", "per_s"), ("peak/s", "peak_per_s")])
    table("intervals (work that waits)", summary["intervals"], [("ms", "ms"), ("count", "count"), ("max", "max")])

    if summary["stack_samples"]:
        print(f'\nmain-thread stacks in late frames: {summary["stack_samples"]} samples')
        for title, key in (
            ("innermost frame, by image", "stack_leaf_image"),
            ("innermost frame", "stack_leaf"),
            ("innermost app frame", "stack_app_frame"),
            ("app frames anywhere in the stack", "stack_app_inclusive"),
        ):
            print(f"  {title}")
            for row in summary[key]:
                print(f'  {row["samples"]:>6}  {row["frame"]}')

    if summary["worst"]:
        print("\nworst frames")
        for row in summary["worst"]:
            context = " ".join(f"{key}={value}" for key, value in (row["ctx"] or {}).items())
            print(
                f'  t={row["t"]} {row["ms"]} ms scroll={row["scroll"]} {context} '
                f'stacks={row["stacks"]} | ' + ("; ".join(row["spans"]) or "no span")
            )


def show_stacks(records: list[dict], limit: int) -> None:
    hitches = sorted((record for record in records if record.get("k") == "hitch" and record.get("stacks")),
                     key=lambda record: -record.get("ms", 0))[:limit]
    symbols = [split_frame(frame)[1] for record in hitches for stack in record["stacks"] for frame in stack["f"]]
    readable = demangle(symbols)
    for record in hitches:
        print(f'\n=== t={record["t"]} {record["ms"]} ms scroll={record.get("scroll")} ===')
        for span in (record.get("spans") or [])[:6]:
            print(f'  span {span["n"]} {span["ms"]} ms x{span["c"]}')
        for stack in record["stacks"]:
            print(f'  --- {stack["at"]} ms overdue')
            for frame in stack["f"]:
                image, symbol = split_frame(frame)
                print(f"    {image}  {readable.get(symbol, symbol)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("trace", nargs="?", type=pathlib.Path, help="a perf-*.jsonl file")
    parser.add_argument("--udid", help="read the newest trace from this Simulator's installed app")
    parser.add_argument("--since", type=float, help="only records at or after this time (seconds since 1970)")
    parser.add_argument("--until", type=float, help="only records at or before this time")
    parser.add_argument("--top", type=int, default=15, help="rows per table (default 15)")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    parser.add_argument("--stacks", type=int, metavar="N", help="print every stack of the N worst frames instead")
    args = parser.parse_args()

    if args.trace is None and not args.udid:
        parser.error("pass a trace file or --udid")
    path = args.trace or newest_trace(args.udid)
    records = load(path, args.since, args.until)
    if args.stacks:
        show_stacks(records, args.stacks)
        return 0
    summary = summarize(records, args.top)
    if args.json:
        json.dump({"trace": str(path), **summary}, sys.stdout, indent=2)
        print()
    else:
        print(f"trace: {path}")
        show(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
