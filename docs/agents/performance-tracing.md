# Performance tracing

Use this when a screen stutters and the question is what the main thread was
doing. The trace is built into the app and off by default.

## Turn it on

Start the app with `--perf-trace`, or set the `perf.trace` default and start
it any way:

```sh
xcrun simctl launch --terminate-running-process "$SIMULATOR_UDID" dev.bybee.heeler --perf-trace
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing dev.bybee.heeler --perf-trace
```

The switch is read once, as the process starts. Off, every call returns at
once: no display link, no thread, no signal handler.

## What it records

[PerfTrace](../../Sources/Heeler/Support/PerfTrace.swift) writes one JSON Lines
file per launch under the app container's `Library/Caches/PerfTrace`, keeping
the newest eight.

| Record | Meaning |
| --- | --- |
| `launch` | Build, OS, device and frame rate. A Debug build runs Swift several times slower than Release: compare like with like. |
| `hitch` | A frame that came at least half a frame late: its gap (`ms`), the time over (`over`), whether a scroll view was moving (`scroll`), the spans and counts recorded on the main actor since the frame before, and main-thread stacks. |
| `stat` | One second: frames, hitches, the time the main run loop spent awake (`busyMs`), and every span and count. |
| `interval` | Work that waits: a Host read, rows built off the main actor. |
| `event` | A moment: a Host's connection status. |

Hitches also go to the unified log under category `Perf`, and spans to
signposts (category `PerfTrace`) for Instruments.

Stacks come from [PerfMainThreadSampler](../../Sources/Heeler/Support/PerfMainThreadSampler.swift):
a watchdog thread signals the main thread (`SIGUSR2`) once a frame is half a
frame overdue, and the handler walks its own frame pointers. Symbols stay
mangled in the file. A stack therefore shows code no span covers, and a hitch
with no stack was shorter than the sampler's first look.

The clock is the app's display link, so it sees the main thread holding a
frame. It does not see the render server: a frame the app committed on time
and the system drew late is not in the trace. Use Instruments on a device for
that.

## Read a trace

```sh
python3 scripts/perf-trace-summary.py --udid "$SIMULATOR_UDID"
python3 scripts/perf-trace-summary.py trace.jsonl --since <epoch> --until <epoch>
python3 scripts/perf-trace-summary.py trace.jsonl --stacks 5
```

The summary gives hitch time per second, hitches while scrolling and at rest,
the spans inside late frames, counts per second (a view's `body`, cells
configured), and where the sampled stacks were. `--since` and `--until` cut one
scenario out of a long run: note `date +%s` before and after it. `--stacks`
prints the worst frames' stacks in full.

From a device, copy the file out first:

```sh
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier dev.bybee.heeler --source Library/Caches/PerfTrace --destination ./PerfTrace
```

## Add a measurement

- `PerfTrace.begin` and `end`, or `PerfTrace.span { }`, time main-actor work
  against the frame it runs in. Nested spans each count their own time, so the
  summary takes the longest one as what a late frame is explained by.
- `PerfTrace.count` counts what happens many times a frame. In a view's `body`,
  write `let _ = PerfTrace.count("Name.body")`.
- `PerfTrace.beginInterval` and `endInterval` time work that suspends, on any
  actor. Their detail is `key=value` pairs.
- `PerfTrace.setContext` names what is on screen in every later hitch.

Names are string literals: `area.step` for spans, `Type.body` for views. Keep a
span out of a loop that runs thousands of times a frame; count there instead.
