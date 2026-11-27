# Read-only Factory Droid 1.21.1 foreground identity probe.
import datetime
import json
import os
import pathlib
import subprocess
import sys
import time
import uuid

pid, start, home, cwd = sys.argv[1:]
root = pathlib.Path(home) / ".factory"
sessions = root / "sessions"
os.environ.update(LC_ALL="C", TZ="UTC")
time.tzset()

def birth(process):
    if sys.platform == "darwin":
        raw = subprocess.check_output(["/bin/ps", "-o", "lstart=", "-p", process], text=True, timeout=1).strip()
        return raw, time.mktime(time.strptime(raw))
    stat = pathlib.Path("/proc", process, "stat").read_text().rsplit(")", 1)[1].split()[19]
    boot = next(x for x in pathlib.Path("/proc/stat").read_text().splitlines() if x.startswith("btime "))
    return stat, int(boot.split()[1]) + int(stat) / os.sysconf("SC_CLK_TCK")

def session_file(sid):
    if str(uuid.UUID(sid)) != sid:
        return
    direct = sessions / cwd.replace("/", "-") / (sid + ".jsonl")
    if direct.is_file():
        return direct
    for index, project in enumerate(sessions.iterdir()):
        if index >= 512:
            return
        file = project / (sid + ".jsonl")
        if file.is_file():
            return file

def header(file, sid):
    with file.open("rb") as stream:
        record = json.loads(stream.readline(65536))
    if record.get("type") != "session_start" or record.get("id") != sid:
        raise ValueError("header")
    return record

class IncompleteLog(Exception):
    pass


def recent_lines(process):
    # Many unrelated turns can follow an idle Droid's last session event.
    # Bound total local I/O, including rotations. No raw logs cross SSH.
    pid_bytes = process.encode("ascii")
    log = root / "logs/droid-log-single.log"
    rotated = sorted(log.parent.glob(log.name + ".????-??-??"), reverse=True)[:2]
    budget = 128 * 1024 * 1024
    for path in [log, *rotated]:
        with path.open("rb") as stream:
            end = position = stream.seek(0, 2)
            partial = b""
            while position and budget:
                step = min(256 * 1024, position, budget)
                position -= step
                stream.seek(position)
                data = stream.read(step)
                if len(data) != step or (position + step == end and not data.endswith(b"\n")):
                    raise IncompleteLog()
                budget -= step
                lines = (data + partial).split(b"\n")
                partial = lines.pop(0)
                yield from (line for line in reversed(lines) if b"process.pid" in line and pid_bytes in line)
            if position == 0 and pid_bytes in partial:
                yield partial
            if not budget:
                return


def controller():
    # /cd can move the controller into a direct RPC child. It shares the
    # interactive Droid's foreground job and terminal, unlike a Task worker.
    fields = "ppid=,pgid=,tpgid=,tty=,comm="
    def job(process):
        return subprocess.check_output(["/bin/ps", "-p", process, "-o", fields], text=True, timeout=1).split(None, 4)
    _, group, foreground, tty, image = job(pid)
    if group != pid or group != foreground or tty in ("?", "??") or pathlib.Path(image.strip()).name != "droid":
        return None
    children = subprocess.run(["pgrep", "-P", pid, "-x", "droid"], capture_output=True, text=True, timeout=1)
    if children.returncode not in (0, 1):
        return None
    owners = []
    for child in children.stdout.split():
        parent, child_group, child_foreground, child_tty, _ = job(child)
        if (parent, child_group, child_foreground, child_tty) != (pid, group, foreground, tty):
            continue
        args = subprocess.check_output(["/bin/ps", "-p", child, "-o", "args="], text=True, timeout=1).strip()
        entry, separator, arguments = args.partition(" exec ")
        if separator and pathlib.Path(entry).name == "droid" and arguments == "--input-format stream-jsonrpc --output-format stream-jsonrpc":
            owners.append(child)
    if len(owners) > 1:
        return None
    return owners[0] if owners else pid


def active():
    if birth(pid)[0] != start:
        return
    owner = controller()
    if not owner:
        return
    owner_start, earliest = birth(owner)
    events = recent_lines(owner)
    closed = set()
    instance = None
    for line in events:
        if not any(m in line[:150] for m in (b"INFO: [SessionController] Session created |", b"INFO: [SessionController] Session loaded |", b"INFO: [Daemon] Session closed |")):
            continue
        head, payload = line.split(b" | ", 1)
        info = json.loads(payload[payload.index(b"{"):])
        if str(info.get("process.pid")) != owner:
            continue
        timestamp = datetime.datetime.fromisoformat(head[1:head.index(b"]")].decode().replace("Z", "+00:00")).timestamp()
        current = str(uuid.UUID(info["factory.process.instance_id"]))
        if timestamp < earliest or (instance and current != instance):
            return
        instance = current
        sid = info["sessionId"]
        if b"[Daemon] Session closed" in head:
            closed.add(sid)
            continue
        file = session_file(sid)
        if not file:
            return
        if header(file, sid).get("callingSessionId"):
            continue
        if sid not in closed and birth(pid)[0] == start and controller() == owner and birth(owner)[0] == owner_start:
            return {"session": sid, "file": str(file), "controller": owner, "controllerStart": owner_start}
        return

try:
    for attempt in range(3):
        try:
            result = active()
            if result:
                print(json.dumps(result))
            break
        except IncompleteLog:
            time.sleep(0.03)
except (OSError, ValueError, KeyError, IndexError, StopIteration, subprocess.SubprocessError):
    pass
