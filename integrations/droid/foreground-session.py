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

def birth():
    if sys.platform == "darwin":
        raw = subprocess.check_output(["/bin/ps", "-o", "lstart=", "-p", pid], text=True, timeout=1).strip()
        return raw, time.mktime(time.strptime(raw))
    stat = pathlib.Path("/proc", pid, "stat").read_text().rsplit(")", 1)[1].split()[19]
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

def recent_lines(path):
    # Bound the read on a busy shared Host and stop as soon as this process
    # has a complete, current decision. Do not send log contents over SSH.
    with path.open("rb") as stream:
        position = stream.seek(0, 2)
        limit = max(0, position - 12 * 1024 * 1024)
        partial = b""
        while position > limit:
            step = min(128 * 1024, position - limit)
            stream.seek(position - step)
            data = stream.read(step) + partial
            if position == stream.seek(0, 2) and not data.endswith(b"\n"):
                return
            position -= step
            lines = data.split(b"\n")
            partial = lines.pop(0)
            yield from reversed(lines)
        if position == 0:
            yield partial


def active():
    actual, earliest = birth()
    if actual != start:
        return
    events = recent_lines(root / "logs/droid-log-single.log")
    closed = set()
    instance = None
    for line in events:
        if not any(m in line[:150] for m in (b"INFO: [SessionController] Session created |", b"INFO: [SessionController] Session loaded |", b"INFO: [Daemon] Session closed |")):
            continue
        head, payload = line.split(b" | ", 1)
        info = json.loads(payload[payload.index(b"{"):])
        if str(info.get("process.pid")) != pid:
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
        if sid not in closed and birth()[0] == start:
            return sid, file
        return

try:
    result = active()
    if result:
        print(json.dumps({"session": result[0], "file": str(result[1])}))
except (OSError, ValueError, KeyError, IndexError, StopIteration, subprocess.SubprocessError):
    pass
