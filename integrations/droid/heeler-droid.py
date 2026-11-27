# Heeler Droid Chat hook
"""Factory lifecycle hook for Droid Chat in herdr-core, tmux and Rex terminals."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time
import uuid


def ps(pid, fields):
    return subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", fields],
        env={"LC_ALL": "C", "TZ": "UTC"}, stderr=subprocess.DEVNULL, timeout=1,
        text=True,
    ).strip()


def process_start(pid):
    if sys.platform == "darwin":
        return ps(pid, "lstart=")
    stat = Path(f"/proc/{pid}/stat").read_text()
    return stat[stat.rindex(")") + 2:].split()[19]


def foreground_droid():
    """Factory can start a hook through a shell. Stop at the nearest Droid."""
    pid = os.getppid()
    for _ in range(6):
        if pid <= 1:
            return None
        parent, group, foreground, tty, image = ps(pid, "ppid=,pgid=,tpgid=,tty=,comm=").split(None, 4)
        if Path(image).name == "droid":
            # /cd restarts the session controller in a direct JSON-RPC child
            # of the interactive job. Its hooks still belong to that terminal.
            if parent == group == foreground and int(group) != pid and tty not in ("?", "??"):
                command = ps(pid, "args=")
                entry, separator, arguments = command.partition(" exec ")
                if separator and Path(entry).name == "droid" and arguments == "--input-format stream-jsonrpc --output-format stream-jsonrpc":
                    pid = int(parent)
                    continue
            if int(group) != pid or group != foreground or tty in ("?", "??"):
                return None
            return pid, process_start(pid), "/dev/" + tty
        pid = int(parent)
    return None


def write_session(path, record):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        try:
            json.dump(record, f)
            f.close()
            os.replace(f.name, path)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(f.name)


def core_request(method, params):
    request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(0.4)
        client.connect(os.environ["HC_TERMINAL_SOCKET"])
        client.sendall(json.dumps(request).encode() + b"\n")
        with client.makefile("rb") as response:
            return json.loads(response.readline(65536)).get("result", {})


def label_core(record):
    terminal = os.environ["HC_TERMINAL_ID"]
    current = core_request("terminal.get", {"terminal": terminal})
    if (current.get("foreground") or {}).get("pid") == record["pid"]:
        core_request("terminal.label", {"terminal": terminal, "labels": {"heeler.session": json.dumps(record)}})


def stored_tmux(socket_path):
    if sys.platform == "darwin":
        data = Path.home() / "Library/Application Support"
    else:
        data = Path(os.environ.get("XDG_DATA_HOME", ""))
        if not data.is_absolute():
            data = Path.home() / ".local/share"
    directory = data / "heeler/host-helper/tmux" / Path(socket_path).name
    digest = hashlib.sha256(os.fsencode(socket_path)).hexdigest()
    # tmux can spell a symlinked parent differently (e.g. /private/tmp).
    for path in (directory / f"droid-{digest}.json", directory / "paths.json", *directory.glob("droid-*.json")):
        with contextlib.suppress(OSError, ValueError, KeyError, TypeError):
            paths = json.loads(path.read_text())
            if os.path.isabs(paths["executable"]) and os.path.isabs(paths["socket"]) and os.path.realpath(paths["socket"]) == os.path.realpath(socket_path):
                return paths["executable"]
    return None


def tmux_status(record, tty, state, name_session):
    socket_path, server, _ = os.environ["TMUX"].rsplit(",", 2)
    pane = os.environ["TMUX_PANE"]
    if not socket_path.startswith("/") or not server.isdecimal() or not pane.startswith("%") or not pane[1:].isdecimal():
        return
    executable = stored_tmux(socket_path)
    if not executable:
        return
    tmux = [executable, "-N", "-S", socket_path]
    target = ["-t", pane]
    # An inner terminal can inherit the outer Pane's environment.
    actual = subprocess.check_output(
        tmux + ["display-message", "-p"] + target + ["#{pid}\t#{pane_tty}\t#{@heeler-status}"],
        stderr=subprocess.DEVNULL, timeout=1, text=True,
    ).rstrip("\n").split("\t")
    if len(actual) != 3 or actual[:2] != [server, tty]:
        return
    fields = dict(part.split("=", 1) for part in actual[2].split(":") if "=" in part)
    turn = int(fields.get("turn", "0"))
    blocked = int(fields.get("blocked", "0"))
    if fields.get("app") == "droid" and fields.get("state") in ("working", "blocked") and state in ("done", "error"):
        turn += 1
    if state == "blocked" and fields.get("state") != "blocked":
        blocked += 1
    status = f"state={state}:app=droid:turn={turn}:blocked={blocked}"
    command = tmux + ["set-option", "-p"] + target + ["@heeler-status", status]
    if name_session:
        command += [";", "set-option", "-p"] + target + ["@heeler-session", json.dumps(record)]
    subprocess.run(command, check=True, timeout=1, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def report(record, tty, state, name_session=False):
    if os.environ.get("TMUX") and os.environ.get("TMUX_PANE"):
        if tmux_status(record, tty, state, name_session):
            return
    if os.environ.get("HC_TERMINAL_SOCKET") or os.environ.get("REX_BLOCK"):
        if name_session and os.environ.get("HC_TERMINAL_SOCKET"):
            with contextlib.suppress(OSError, ValueError, KeyError):
                label_core(record)
        fd = os.open(tty, os.O_WRONLY | os.O_NONBLOCK | os.O_NOCTTY)
        try:
            os.write(fd, f"\x1b]7501;state={state}:app=droid\x1b\\".encode())
        finally:
            os.close(fd)


@contextlib.contextmanager
def locked(folder):
    fd = os.open(folder, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def reap_sessions(folder):
    # A killed Droid cannot send SessionEnd.
    with os.scandir(folder) as entries:
        for index, entry in enumerate(entries):
            if index >= 128:
                break
            stem, ext = os.path.splitext(entry.name)
            if ext == ".json" and stem.isdecimal() and 0 < int(stem) <= 2147483647:
                try:
                    os.kill(int(stem), 0)
                except ProcessLookupError:
                    os.unlink(entry.path)
                except PermissionError:
                    pass


def session_file(pid):
    return Path.home() / ".factory" / "heeler-session" / f"{pid}.json"


def watch_turn(pid, token, offset):
    """Escape writes an outcome without running Stop. Follow only this turn."""
    path = session_file(pid)
    record = json.loads(path.read_text())
    if record.get("turn") != token:
        return
    with open(record["file"], "rb") as transcript, contextlib.ExitStack() as stack:
        transcript.seek(offset)
        queue = stack.enter_context(contextlib.closing(select.kqueue())) if hasattr(select, "kqueue") else None
        if queue is not None:
            queue.control([select.kevent(transcript.fileno(), filter=select.KQ_FILTER_VNODE,
                          flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                          fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME)], 0, 0)
        skipping = False
        while json.loads(path.read_text()).get("turn") == token:
            os.kill(pid, 0)
            position = transcript.tell()
            line = transcript.readline(65536)
            if line.endswith(b"\n"):
                if not skipping and b'"agent_turn_outcome"' in line:
                    outcome = json.loads(line)
                    if outcome.get("type") == "agent_turn_outcome":
                        with locked(path.parent):
                            current = json.loads(path.read_text())
                            if current.get("turn") == token and process_start(pid) == record["start"]:
                                current.pop("turn")
                                write_session(path, current)
                                state = {"completed": "done", "cancelled": "idle", "failed": "error",
                                         "error": "error", "model_provider_unreachable": "error"}.get(outcome.get("reason"))
                                group, foreground, tty = ps(pid, "pgid=,tpgid=,tty=").split()
                                if state and int(group) == pid and group == foreground:
                                    report(current, "/dev/" + tty, state)
                        return
                skipping = False
            elif len(line) == 65536:
                skipping = True
            else:
                transcript.seek(position)
                if process_start(pid) != record["start"]:
                    return
                if queue is not None:
                    queue.control([], 1, 5)
                else:
                    time.sleep(0.5)


def main(event):
    env = os.environ
    if not (env.get("HC_TERMINAL_ID") or env.get("TMUX_PANE") or env.get("REX_BLOCK")):
        return
    name = event["hook_event_name"]
    session = str(uuid.UUID(event["session_id"]))
    file = Path(event["transcript_path"])
    if not file.is_absolute() or file.name != session + ".jsonl" or file.parent.parent.name != "sessions":
        return
    # Factory can run a child in the parent process. Its SessionStart and
    # SessionEnd do not change the main conversation on this terminal.
    if name == "SessionStart" and file.is_file():
        with file.open("rb") as handle:
            header = json.loads(handle.readline(65536))
        if header.get("callingSessionId"):
            return
    process = foreground_droid()
    if not process:
        return
    pid, start, tty = process
    path = session_file(pid)
    path.parent.mkdir(mode=0o700, exist_ok=True)
    identity = {"pid": pid, "start": start, "session": session, "file": str(file)}
    with locked(path.parent):
        if name == "SessionStart":
            write_session(path, identity)
            reap_sessions(path.parent)
            report(identity, tty, "idle", name_session=True)
            return
        current = json.loads(path.read_text())
        turn = current.pop("turn", None)
        if current != identity:
            return
        if name == "SessionEnd":
            path.unlink()
        elif name == "UserPromptSubmit":
            token = uuid.uuid4().hex
            offset = file.stat().st_size
            write_session(path, dict(identity, turn=token))
            report(identity, tty, "working")
            subprocess.Popen([sys.executable, __file__, "--watch-turn", str(pid), token, str(offset)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        elif name == "Notification" and event.get("notification_type") in ("permission_prompt", "elicitation_dialog") and turn:
            report(identity, tty, "blocked")
        elif name == "PostToolUse" and turn:
            report(identity, tty, "working")
        # Stop can precede a cancelled or failed transcript outcome. The turn
        # watcher owns completion and counts it once even when Stop also fires.


if __name__ == "__main__":
    # An unavailable terminal or an unrecognized event must never interrupt Droid.
    with contextlib.suppress(OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        if len(sys.argv) == 5 and sys.argv[1] == "--watch-turn":
            watch_turn(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]))
        else:
            main(json.load(sys.stdin))
