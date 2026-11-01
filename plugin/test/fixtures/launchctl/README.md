# launchctl print fixtures

Real output of `launchctl print user/<uid>/<label>`, for the LaunchAgent health
parser. Each came from a plain SSH exec with no PTY against a throwaway Tart VM
of macOS 26.5 (25F71), not a bare-metal Mac. The agent was an absolute Node.js
24.16.0 path with `KeepAlive`, `RunAtLoad` and
`LimitLoadToSessionType = Background`, in `user/501`. Home paths and user names
are placeholders; the label, uid, pids and counters are as printed. The results
are written up in `docs/agents/herdr-compatibility.md`.

| File | Exit | State |
| --- | --- | --- |
| `running.txt` | 0 | Bootstrapped, first run, desktop logged in |
| `restarted.txt` | 0 | Running again after SIGKILL, desktop logged in |
| `failed-node-missing.txt` | 0 | Node.js path moved away, desktop logged in |
| `failed-node-missing-logged-out.txt` | 0 | The same with nobody logged in; launchd has no monitor for the path |
| `failed-exit-1.txt` | 0 | Node.js present, script missing, exits 1 about every ten seconds |
| `failed-signal-abort.txt` | 0 | Dies on SIGABRT at start, between runs: a signal and `successive crashes`, no `last exit code` |
| `failed-signal-running.txt` | 0 | The same loop read during a run: `state = running` with a pid, while still failing |
| `recovered-after-signal.txt` | 0 | Running and staying up after that loop: `successive crashes` and the signal remain |
| `not-loaded.txt` | 113 | Stderr for a label the domain does not hold |

No single read separates `failed-signal-running.txt` from
`recovered-after-signal.txt`: their only differences are the counters and pid.
`state = xpcproxy` also appeared for a moment before a run, and has no fixture.
