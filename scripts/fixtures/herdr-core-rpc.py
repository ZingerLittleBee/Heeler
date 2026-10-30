#!/usr/bin/env python3
"""Send one plain request to a running herdr-core, for tests and lab checks.

Reads the session's core.lock, connects to the socket it names and prints the
result as JSON. It runs no `hc` and no herdr-core subcommand, because every one
of those but `server stop` can start a core with this process's environment
(ADR 0031). Nothing listening is a failure, never a reason to start anything.

    herdr-core-rpc.py --session <s> server.status [--params '{"key": "value"}']

Exit status: 0 with a result, 3 with no core.lock, 4 when nothing listens, 5 when
the core answers with an error or an unreadable line.
"""

import argparse
import json
import os
from pathlib import Path
import socket
import sys

MAX_REPLY = 16 * 1024 * 1024


def default_state_root():
    return Path(os.environ["HOME"]) / ".local/state/herdr-core"


def request(socket_path, method, params, timeout=10):
    """One line out, one line back, over a connection that stays plain."""
    line = json.dumps({"jsonrpc": "2.0", "id": "rpc", "method": method, "params": params})
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(socket_path)
        connection.sendall(line.encode() + b"\n")
        reply = bytearray()
        while b"\n" not in reply and len(reply) < MAX_REPLY:
            chunk = connection.recv(65536)
            if not chunk:
                break
            reply += chunk
    return json.loads(bytes(reply).split(b"\n", 1)[0])


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("method")
    parser.add_argument("--session", required=True)
    parser.add_argument("--state-root", type=Path)
    parser.add_argument("--params", default="{}")
    args = parser.parse_args(arguments)
    lock = (args.state_root or default_state_root()) / args.session / "core.lock"
    try:
        socket_path = lock.read_text()
    except OSError as error:
        print(f"no core.lock for session {args.session!r}: {error}", file=sys.stderr)
        return 3
    try:
        reply = request(socket_path, args.method, json.loads(args.params))
    except OSError as error:
        print(f"nothing listens at {socket_path}: {error}", file=sys.stderr)
        return 4
    except ValueError as error:
        print(f"unreadable reply from {socket_path}: {error}", file=sys.stderr)
        return 5
    if "result" not in reply:
        print(json.dumps(reply.get("error", reply)), file=sys.stderr)
        return 5
    print(json.dumps(reply["result"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
