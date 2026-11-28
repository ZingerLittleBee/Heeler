#!/usr/bin/env python3
"""Exercise a Terminal Composer paste whose foreground returns to its shell on macOS or Linux.

Run prepare, then give fixture.json's fields and the disposable SSH connection to
RexTerminalTakeoverLiveTests. The app's positive paste receipt is held until a
separate client has typed into the replacement Bash. read prints the host proof.
stop shuts down only this fixture. Requires real rex, pi, Bash 4+ and Python 3.9+.
"""
import argparse
import asyncio
import base64
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid

frame = runpy.run_path(str(Path(__file__).with_name("rex-lost-receipt.py")))["frame"]


def write(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def wait(description, probe, seconds=10):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        value = probe()
        if value:
            return value
        time.sleep(.025)
    raise RuntimeError(description)


def process_start(pid):
    if sys.platform == "darwin":
        return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                       env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True).strip()
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


class Lab:
    def __init__(self, root):
        self.root = root
        self.settings = json.loads((root / "setup.json").read_text())

    def rex(self, *args):
        command = [self.settings["rex"], "--autostart=false", "-S", str(self.root / "server.sock"), *args]
        return subprocess.check_output(command, text=True, timeout=6)

    def call(self, peer, method, arguments=None):
        body = {"block_id": peer["block"]}
        if arguments is not None:
            body["args"] = arguments
        output = self.rex("api", "call", "-s", peer["session"], "com.superlogical.terminal." + method, json.dumps(body))
        return json.loads(output or "{}")

    def foreground(self, peer):
        return self.call(peer, "process").get("foreground") or {}

    def capture(self, peer):
        return self.rex("capture", "-s", peer["session"], "-b", peer["block"], "--unwrap", "--trim")

    def keys(self, peer, text):
        self.call(peer, "write", {"data": text})

    def measure(self, peer):
        # The binding inspects the current Readline buffer without submitting it.
        path = self.root / (peer["side"] + ".readline")
        old = len(path.read_bytes().splitlines()) if path.exists() else 0
        self.keys(peer, "\x18\x07")
        def result():
            rows = path.read_bytes().splitlines() if path.exists() else []
            return rows[old:] if len(rows) > old else None
        lines = wait("The QA Bash did not publish its Readline line", result, 4)
        if len(lines) != 1:
            raise RuntimeError("Unexpected Readline observations")
        return lines[0].decode()

    def swap(self, config):
        target = config["target"]
        pid = config["agentPID"]
        current = self.foreground(target)
        if current.get("pid") != pid or current.get("cwd") != config["directory"]:
            raise RuntimeError("The target is no longer the disposable Pi")
        tick = process_start(pid)
        if tick != config["agentStart"]:
            raise RuntimeError("Pi's process identity changed")
        wait("Pi did not display the accepted mobile paste", lambda: config["phoneText"] in self.capture(target))
        os.kill(pid, signal.SIGTERM)
        wait("Bash did not reclaim its original terminal", lambda: self.foreground(target).get("pid") == target["shellPID"], 5)
        self.keys(target, config["desktopText"])
        if self.measure(target) != config["desktopText"]:
            raise RuntimeError("The independently typed command was not staged in Bash")

    def finish(self):
        config = json.loads((self.root / "fixture.json").read_text())
        counts = json.loads((self.root / "wire.json").read_text())
        if counts["releasedPasteReceipts"] != 1:
            raise RuntimeError("The intended paste has not completed its handover")
        observed = {}
        for name, text in (("target", config["desktopText"]), ("peer", config["peerText"])):
            peer = config[name]
            foreground = self.foreground(peer)
            current = self.measure(peer)
            observed[name] = {"sameShellPID": foreground.get("pid") == peer["shellPID"],
                              "expectedReadlineBase64": base64.b64encode(text.encode()).decode(),
                              "actualReadlineBase64": base64.b64encode(current.encode()).decode(),
                              "exactDesktopText": current == text,
                              "commandExecuted": (self.root / (name + ".executed")).exists()}
        value = {"wire": counts, "shells": observed}
        write(self.root / "after.json", value)
        return value


def prepare(root, rex, pi, bash):
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    project = root / "project"
    project.mkdir()
    home = root / "home"
    home.mkdir()
    agent = root / "pi"
    agent.mkdir()
    tag = uuid.uuid4().hex[:10].upper()
    write(agent / "models.json", {"providers": {"lab": {"baseUrl": "http://127.0.0.1:9/v1", "api": "openai-completions",
          "apiKey": "heeler-lab-loopback", "models": [{"id": "local", "name": "Local",
          "input": ["text"], "contextWindow": 32000, "maxTokens": 256}]}}})
    settings = {"rex": str(Path(rex).absolute()), "pi": str(Path(pi).absolute())}
    write(root / "setup.json", settings)
    lab = Lab(root)
    lab.rex("server", "start", "--restore=false", "--state-dir", str(root / "state"))
    status = json.loads(lab.rex("api", "call", "server.status"))
    settings["instance"] = status["instance_id"]
    write(root / "setup.json", settings)
    rc = root / "bashrc"
    rc.write_text("PS1='heeler-lab-shell> '\nHISTFILE=/dev/null\nset -o emacs\n"
                  "heeler_lab_observe() { printf '%s\\n' \"$READLINE_LINE\" >> \"$OBSERVE\"; }\n"
                  "bind -m emacs-standard -x '\"\\C-x\\C-g\":heeler_lab_observe'\n")
    config = {"directory": str(project), "phoneText": "REX_LAB_MOBILE_" + tag, "rexSocket": str(root / "phone.sock"),
              "desktopText": "printf '%s' DESKTOP_" + tag + " > " + str(root / "target.executed"),
              "peerText": "printf '%s' PEER_" + tag + " > " + str(root / "peer.executed")}
    for side in ("target", "peer"):
        row = json.loads(lab.rex("session", "new", "--json", "--cwd", str(project), "--shell", "none",
                               "heeler-lab-swap-" + side, "--", "/usr/bin/env", "HOME=" + str(home), "HISTFILE=/dev/null",
                               "OBSERVE=" + str(root / (side + ".readline")), bash, "--noprofile", "--rcfile", str(rc), "-i"))
        peer = {"side": side, "session": row["session_id"], "block": row["initial_windows"][0]["block_ids"][0]}
        wait("The new Bash did not display its prompt", lambda: "heeler-lab-shell>" in lab.capture(peer))
        peer["shellPID"] = lab.foreground(peer)["pid"]
        config[side] = peer
    lab.keys(config["peer"], config["peerText"])
    if lab.measure(config["peer"]) != config["peerText"]:
        raise RuntimeError("Unexpected peer line")
    target = config["target"]
    launch = shlex.join(["/usr/bin/env", "PI_CODING_AGENT_DIR=" + str(agent), "PI_TELEMETRY_DISABLED=1",
                         "PI_SKIP_VERSION_CHECK=1", settings["pi"], "--no-tools", "--no-context-files", "--no-skills", "--model", "lab/local"])
    lab.keys(target, launch + "\r")
    def pi_pid():
        fg = lab.foreground(target)
        return fg.get("pid") if Path(fg.get("argv0", "")).name == "pi" and fg.get("cwd") == str(project) else None
    config["agentPID"] = wait("Pi did not become the foreground", pi_pid, 15)
    config["agentStart"] = process_start(config["agentPID"])
    wait("Pi did not draw its editor", lambda: "local" in lab.capture(target), 15)
    config["evidence"] = str(root / "wire.json")
    write(root / "fixture.json", config)
    with (root / "proxy.log").open("w") as log:
        child = subprocess.Popen([sys.executable, __file__, "serve", str(root)], start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    (root / "proxy.pid").write_text(str(child.pid))
    wait("The socket was not bound", lambda: (root / "phone.sock").is_socket())
    return config


async def serve(root):
    lab = Lab(root)
    config = json.loads((root / "fixture.json").read_text())
    target = config["target"]["block"]
    peer = config["peer"]["block"]
    counts = {"acceptedPastes": 0, "releasedPasteReceipts": 0, "mobileAfterPaste": [], "peerWrites": 0,
              "desktopTextVerifiedBeforeRelease": False}

    async def connection(client, mobile):
        backend, upstream = await asyncio.open_unix_connection(root / "server.sock")
        tasks = []
        handled_swap = False
        try:
            for source, destination in ((client, upstream), (backend, mobile)):
                destination.write(await source.readuntil(b"\r\n\r\n"))
                await destination.drain()
            pending = None
            async def pump(reader, writer, from_mobile):
                nonlocal pending, handled_swap
                while True:
                    raw, message = await frame(reader)
                    payload = message.get("payload") or {}
                    block, method = payload.get("block_id"), message.get("method", "")
                    if from_mobile and block in (target, peer):
                        event = payload.get("event") or {}
                        if method == "block.event" and event.get("type") == "paste":
                            text = (event.get("payload") or {}).get("text")
                            if block == target and text == config["phoneText"] and not counts["acceptedPastes"]:
                                pending = message["id"]
                            elif block == peer:
                                counts["peerWrites"] += 1
                        if method.endswith(".write"):
                            received = payload.get("args", {}).get("data", "").encode()
                            if block == peer:
                                counts["peerWrites"] += 1
                            elif counts["acceptedPastes"]:
                                counts["mobileAfterPaste"].append(base64.b64encode(received).decode())
                        write(root / "wire.json", counts)
                    if not from_mobile and pending is not None and message.get("type") == "response" and message.get("id") == pending:
                        if message.get("error"):
                            raise RuntimeError("Rex rejected the intended paste")
                        pending = None
                        counts["acceptedPastes"] += 1
                        write(root / "wire.json", counts)
                        await asyncio.to_thread(lab.swap, config)
                        counts["desktopTextVerifiedBeforeRelease"] = True
                        counts["releasedPasteReceipts"] += 1
                        handled_swap = True
                        write(root / "wire.json", counts)
                    writer.write(raw)
                    await writer.drain()
            tasks = [asyncio.create_task(pump(client, upstream, True)), asyncio.create_task(pump(backend, mobile, False))]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            mobile.close()
            upstream.close()
            if handled_swap:
                await asyncio.to_thread(lab.finish)

    server = await asyncio.start_unix_server(connection, path=root / "phone.sock")
    os.chmod(root / "phone.sock", 0o600)
    write(root / "wire.json", counts)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "serve", "read", "stop"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--rex", default=shutil.which("rex"))
    parser.add_argument("--pi", default=shutil.which("pi"))
    parser.add_argument("--bash", default=shutil.which("bash"))
    args = parser.parse_args()
    root = args.root.resolve()
    if not re.fullmatch(r"heeler-lab-[A-Za-z0-9-]+", root.name) or root.parent != Path("/tmp").resolve():
        parser.error("Use a fresh /tmp/heeler-lab-… directory in a disposable Host account")
    if args.action == "prepare":
        if not args.rex or not args.pi or not args.bash:
            parser.error("The official rex and pi executables and Bash 4+ are required")
        print(json.dumps(prepare(root, args.rex, args.pi, args.bash)))
    elif args.action == "serve":
        asyncio.run(serve(root))
    elif args.action == "read":
        print(json.dumps(Lab(root).finish()))
    else:
        lab = Lab(root)
        if json.loads(lab.rex("api", "call", "server.status"))["instance_id"] != lab.settings["instance"]:
            raise RuntimeError("The server instance changed")
        pid = int((root / "proxy.pid").read_text())
        if sys.platform == "darwin":
            command = subprocess.check_output(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], text=True).strip()
            owns_proxy = command.endswith(f" {Path(__file__).resolve()} serve {root}")
        else:
            argv = [os.fsdecode(v) for v in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if v]
            owns_proxy = argv[-3:] == [str(Path(__file__).resolve()), "serve", str(root)]
        if not owns_proxy:
            raise RuntimeError("The proxy PID changed")
        os.kill(pid, signal.SIGTERM)
        lab.rex("server", "stop")
