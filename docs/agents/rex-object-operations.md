# Rex object operations

## Scope

On 2026-11-27, a private Rex 0.1.0-preview.25 server (build 2147, commit `b070aae645f5`, Darwin arm64) ran on macOS 27.0.1 (26A434). Its native API revision was 24. Two pairs of independent control connections exercised the operations below, separately at revisions 12 and 19, the endpoints supported by Heeler at `10148154`. A hello with a floor of 25 was refused with WebSocket close 1008. The server reported its range as 0–24. Negotiating 12 on this binary does not establish which options an older binary implements.

The server had its own socket, empty configuration, state, home, and working directory. One connection stood in for a desktop client, owned a block, set its grid and read back the session's selection. The other connection performed the operations. A second session held another owned terminal as a witness. Evidence here covers the real server's shared focus, ownership, layout, processes and events. Native Rex.app rendering, an SSH connection, iOS UI, Linux and Windows were outside this run. Earlier runs name their own versions and platforms. [Rex compatibility observations](rex-compatibility.md)

## Starting a program

An older server can describe its own terminal flavor without starting a block. Send `block_creator.list {}`, select the entry in `creators[].flavors[]` whose `flavor` is `com.superlogical.terminal.shell`, and inspect `options_schema.properties`. On preview.25 at both 12 and 19, `command` and `args` allowed an array with string items, `shell` was a string, `login` allowed a boolean, and `cwd` was a string. The earlier preview.23 run verified this discovery method and `cwd`; it did not record the `command` schema or an argv receipt. Check the running server before choosing a launch shape. A missing schema gives no assurance that it accepts literal argv.

For management calls, `help.all {}` returned `methods[]` entries with `name`, `input_schema`, and `output_schema`. Check the method and exact fields used in the table below. At negotiated revisions 12 and 19 this same reply advertised both `client.undo_close` and `session.transfer_window`, despite their higher minimum revisions. A descriptor establishes what the server knows about a method; its negotiated revision and behavior are separate evidence. [Earlier revision 19 observations](rex-compatibility.md#api-revision-19)

A new window took this payload. `SESSION`, the directory, executable, names and arguments below stand for literal strings.

```json
{
  "session_id": "SESSION",
  "window_label": "heeler-lab-tab",
  "focus": false,
  "layout": {
    "block": {
      "flavor": "com.superlogical.terminal.shell",
      "label": "heeler-lab-block",
      "options": {
        "shell": "none",
        "login": false,
        "cwd": "/absolute/working/directory",
        "command": ["/usr/bin/env", "HEELER_LAB_TAG=one two = 三", "/absolute/program", "two words", ""]
      }
    }
  }
}
```

- `session.new_window` returned `{window_id, block_ids, revision}`. With an existing active window, `focus:false` preserved its ID and focused block. A creator individually attached through `session.attach` initially owned the new block. `session.disown_block {session_id,block_ids:[newBlock]}` returned `{blocks:[{block_id,owner:null}]}` when nobody else had requested it. The desktop client kept its original 93×31 grid, owner and focus. Its other session's entire view also compared equal.
- `session.create {label,initial_windows:[{window_label,layout}]}` used the same layout. It returned `{session_id,initial_windows:[{window_id,block_ids,revision}]}`. The new block began with no owner. Its child independently recorded the requested directory, arguments, and environment value.
- Seven arguments reached the recorder in order. They included an empty string, spaces, single and double quotes, a literal dollar expression, Unicode and an option carrying spaces. The `/usr/bin/env` assignment in the argument vector delivered the value including its spaces and equals sign. The shell flavor has no advertised `env` option. Supplying an `options.env` object succeeded but the child received no such variable. An inherited server variable and an assignment specific to one launch are different operations.
- On this Mac, `shell:"none"` with `login` omitted ran the recorder but the terminal reported `login` as its foreground, with a different PID, in four samples through another write to the terminal. With `login:false`, all four samples identified the recorder and its PID. Using the default shell with `command`, or `shell:"/bin/sh",login:true` with `command`, also identified the recorder in all four samples. A successful create response alone carries no foreground identity.
- The deprecated `shell:"/usr/bin/env",args:[assignment,executable,...],login:false` also preserved the same arguments, environment and directory. Sending both `args` and `command` returned `bad_request`. A missing absolute program with direct launch returned `internal` and a spawn error. A nonexistent `cwd` **succeeded** and ran in the lab server's home. Verify a required working directory on the Host before relying on this option.

## Labels, layout and close

All IDs below came from the live session. An ordinary terminal's program controls its OSC title. Rex stores management labels independently at the session, window and block levels.

| Control method and fields sent | Result fields | Observed effect at 12 and 19 |
| --- | --- | --- |
| `session.set_label {session_id,label}` | `revision` | Trimmed surrounding spaces and renamed that Workspace. It emitted `session_label_changed` and `session_view_changed`. |
| `session.set_block_label {session_id,block_id,label}` | `revision` | Changed the block's `label` in inventory and left its window label and OSC title intact. When the program later changed its OSC title, the management label survived. A placed block emitted `session_view_changed`. A detached block appeared with its new label in `session.list_blocks` while its view revision stayed the same and no session event announced the rename. |
| `session.set_window_label {session_id,window_id,label}` | `revision` | Changed just the tab label. It emitted `window_label_changed`, then `session_view_changed`. |
| `session.new_split {session_id,anchor_id,direction:"horizontal",side:"after",ratio:0.4,focus:false,layout}` | `anchor_id,block_ids,split_ids,revision` | Added one block beside the named block in its background window. The anchor stayed focused in that window. The active window, desktop block and witness session kept their selection. The creator released the new block's ownership. |
| `session.move_window {session_id,window_id,before_window_id}` | `revision` | Reordered the tab directly before its named neighbor and kept the active window. |
| `session.move_block {session_id,block_id,anchor_block_id,direction,side}` | `created_split_id,revision`, and `removed_split_id` when a split was removed | A nonfocused block moved beside the exact anchor in another window with the same running PID and no change to the active window. Moving the focused block of an **inactive** window made its destination active and focused the moved block. Its empty source window closed. |
| `block.close {session_id,block_id}` | `block_id,revision` | Removed exactly that block. A sibling remained alive, and a second close of the same ID returned `not_found`. Closing the sole block closed its window. Closing the sole block of the final window left an existing, empty session. `keep_last:true` rejected the last block of a window with `bad_request`. |
| `session.close_window {session_id,window_id}` | `revision` | Removed the selected background window and both of its live blocks. The desktop's active window, focused block, size owner and 96×33 grid survived. The witness session's full view compared equal. |
| `session.destroy {session_id}` | No result fields | Removed the fixture session containing a placed and a detached block. Reads of that session then returned `session_not_found`. The witness session's view compared equal. |

The block accepted 128 Unicode code points. It rejected 129 and an embedded newline with `bad_request`. Clearing its label produced `Block <ID suffix>`. Giving the wrong containing session to block rename, window rename, split, move or close returned `not_found`. A block label identifies a Rex object. No tested control call renamed an agent's own conversation or changed what its process wrote as its title.

## Foreground races and revision gates

- **Close has no atomic foreground comparison.** A recorder in a split executed `/bin/cat`, keeping the PID and block ID. A second connection observed the foreground name change from `Python` to `cat`. Sending `block.close` with the old `expected_foreground:{pid,name}` still succeeded and closed `cat`. The neighbor continued running. The live help schema advertises `additionalProperties:false`, but this unrecognized field on a raw control request was ignored. Reading and comparing the foreground locally can catch a change that has already happened. It cannot prevent a change between the read and the close.
- **Undo starts at revision 20.** At 12 and 19, an individually attached client sent `block.close {session_id,block_id,undoable:true}`. The block disappeared and the recorded child PID exited. `client.undo_close {}` returned `revision_too_low`, naming 20. At 20 the same close and undo restored the original running process and block, returning `{session_id,window_id,block_id}`.
- **Transferring a window between sessions starts at 22.** Although the native server's method list includes `session.transfer_window`, calls at 12, 19 and 21 returned `revision_too_low` naming 22. At 22, `{session_id,window_id,to_session_id,focus:false}` returned `{revision,to_revision}`. The destination gained the same window and block IDs and the same process PID, the source lost them, and the destination's existing active window stayed selected. The transferring client was attached to the destination and became owner of the moved block until it disowned it.

## Reproduce on macOS

The following command starts an empty server under `/tmp/heeler-lab-*` and removes it on exit. It requires the tested Rex Beta, Bash, Python 3 and the Python `websockets` package (16.0 in this run). It checks the launch receipt, independent labels, focus, size ownership, a sibling, a neighboring session and the foreground-close race at both revisions. The CLI reads the installed server's descriptions. The two persistent sockets pin the negotiated revision. [Rex server API](https://www.superlogical.com/rex/docs/automate/server-api)

```bash
(
  set -eu
  lab=$(mktemp -d /tmp/heeler-lab-rex-ops.XXXXXX)
  rex='/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex'
  mkdir "$lab/home" "$lab/run" "$lab/state" "$lab/work"
  : > "$lab/init.lua"
  sock="$lab/run/server.sock"
  r() {
    env -i HOME="$lab/home" SHELL=/bin/sh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      REX_RUNTIME_DIR="$lab/run" "$rex" -S "$sock" --autostart=false "$@"
  }
  r server run --listen "unix://$sock" --restore=false --state-dir "$lab/state" \
    --config "$lab/init.lua" >"$lab/server.log" 2>&1 &
  server_job=$!
  cleanup() {
    if [ -S "$sock" ]; then r server stop >/dev/null 2>&1 || true; fi
    wait "$server_job" 2>/dev/null || true
    rm -rf "$lab"
  }
  trap cleanup EXIT
  for attempt in {1..100}; do [ -S "$sock" ] && break; sleep 0.05; done
  test -S "$sock"
  r api call server.version
  r api describe session.new_window --json > "$lab/new-window.json"
  r api describe block.close --json > "$lab/close.json"
  r block types --json > "$lab/block-types.json"
  python3 - "$lab" <<'PY'
import json
import sys
import time
from pathlib import Path
from websockets.sync.client import unix_connect

lab = Path(sys.argv[1]).resolve()
child = lab / "record.py"
child.write_text("""import json, os, sys
from pathlib import Path
out = Path(sys.argv[1])
tmp = out.with_suffix('.partial')
tmp.write_text(json.dumps([os.getpid(), os.getcwd(), os.getenv('HEELER_LAB_TAG'), sys.argv[2:]]))
tmp.replace(out)
print('\\x1b]2;program title\\x07ready', flush=True)
input()
os.execv('/bin/cat', ['cat'])
""")

def link(rev, name):
    ws = unix_connect(str(lab / "run/server.sock"), "ws://localhost/api/control",
                      subprotocols=["rex.control.v1"], proxy=None)
    ws.send(json.dumps({"type": "hello", "api_revision": rev, "api_min_revision": rev,
                        "client": {"kind": "other", "name": name}}))
    assert json.loads(ws.recv(timeout=5))["api_revision"] == rev
    sequence = 0
    def call(method_name, **payload):
        nonlocal sequence
        sequence += 1
        tag = str(sequence)
        ws.send(json.dumps({"type": "request", "id": tag, "method": method_name, "payload": payload}))
        while True:
            frame = json.loads(ws.recv(timeout=30))
            if frame.get("type") == "response" and frame.get("id") == tag:
                if frame.get("error"):
                    raise RuntimeError(frame["error"])
                return frame.get("payload", {})
    return ws, call

def until(read):
    for _ in range(100):
        value = read()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError("the child did not reach the requested state")

def layout(argv):
    return {"block": {"flavor": "com.superlogical.terminal.shell",
            "options": {"shell": "none", "login": False, "cwd": str(lab / "work"), "command": argv}}}

def workspace(call, name):
    new = call("session.create", label=name, initial_windows=[{"layout": layout(["/bin/cat"])}])
    win = new["initial_windows"][0]
    return new["session_id"], win["window_id"], win["block_ids"][0]

for rev in (12, 19):
    mobile, call = link(rev, "heeler-lab-mobile")
    desktop, observe = link(rev, "heeler-lab-observer")
    s, win, anchor = workspace(call, f"heeler-lab-target-{rev}")
    other, _, _ = workspace(call, f"heeler-lab-neighbor-{rev}")
    call("session.attach", session_id=s)
    for sid in (s, other):
        observe("session.attach", session_id=sid)
    observe("session.own_block", session_id=s, block_ids=[anchor], mode="take")
    def term(block, method, **args):
        return observe("block.method", session_id=s, block_id=block, method=method, args=args)
    term(anchor, "resize", columns=93, rows=31)
    grid = term(anchor, "size")
    neighbors = observe("session.view", session_id=other)

    out = lab / f"receipt-{rev}.json"
    args = ["two words", "a'b", '"quoted"', "dollar $HOME", "咖啡", "", "--flag=two words"]
    cmd = ["/usr/bin/env", "HEELER_LAB_TAG=one two = 三", sys.executable, str(child), str(out), *args]
    new = call("session.new_window", session_id=s, focus=False, layout=layout(cmd))
    block = new["block_ids"][0]
    call("session.disown_block", session_id=s, block_ids=[block])
    until(out.exists)
    pid, cwd, value, delivered = json.loads(out.read_text())
    assert (cwd, value, delivered) == (str(lab / "work"), "one two = 三", args)
    until(lambda: term(block, "title").get("title") == "program title")
    call("session.set_label", session_id=s, label="heeler-lab-workspace")
    call("session.set_window_label", session_id=s, window_id=new["window_id"], label="heeler-lab-tab")
    call("session.set_block_label", session_id=s, block_id=block, label="heeler-lab-block")
    v = observe("session.view", session_id=s)
    tab = next(w for w in v["windows"] if w["window_id"] == new["window_id"])
    entry = next(b for b in tab["layers"][0]["blocks"] if b["block_id"] == block)
    assert (v["label"], tab["label"], entry["label"], term(block, "title")["title"]) == (
        "heeler-lab-workspace", "heeler-lab-tab", "heeler-lab-block", "program title")

    split = call("session.new_split", session_id=s, anchor_id=block, direction="horizontal",
                 side="after", focus=False, layout=layout(["/bin/cat"]))
    sibling = split["block_ids"][0]
    call("session.disown_block", session_id=s, block_ids=[sibling])
    def original_holder():
        process = term(block, "process").get("foreground") or {}
        return process if process.get("pid") == pid else None
    holder = until(original_holder)
    term(block, "write", data="replace\n")
    def successor():
        term(block, "write", data="sample\n")
        return (term(block, "process").get("foreground") or {}).get("name") == "cat"
    until(successor)
    closed = call("block.close", session_id=s, block_id=block,
                  expected_foreground={"pid": pid, "name": holder["name"]})
    assert closed["block_id"] == block
    left = observe("session.list_blocks", session_id=s)["blocks"]
    assert {b["block_id"] for b in left} == {anchor, sibling}
    after = observe("session.view", session_id=s)
    assert after["active_window_id"] == win
    assert next(w for w in after["windows"] if w["window_id"] == win)["focused_block_id"] == anchor
    assert term(anchor, "size") == grid and observe("session.view", session_id=other) == neighbors
    print(f"revision {rev}: argv, labels, focus, ownership, sibling and successor verified")
    mobile.close()
    desktop.close()
PY
)
```
