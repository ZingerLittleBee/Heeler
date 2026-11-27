#!/usr/bin/env python3
"""Prepare or release a signed, isolated Mac Devin Composer background fixture."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import time


def owned_root(path):
    root = path.resolve()
    if root.parent != Path("/tmp").resolve() or not root.name.startswith("heeler-lab-"):
        raise ValueError("Use a private heeler-lab- directory directly below /tmp")
    return root


def write_new(path, content):
    with path.open("x", encoding="utf-8") as stream:
        stream.write(content)
    path.chmod(0o600)


def prepare(source, backend, store, tag):
    root = owned_root(source.parent)
    lab = json.loads(source.read_text())
    if not lab.get("sessions", {}).get(backend):
        raise ValueError("First verify the signed foreground and its independent ACP writer slug")
    work = Path(lab["directory"]).resolve()
    if root not in work.parents or not work.is_dir() or root not in store.resolve().parents:
        raise ValueError("The private working directory and writer store must be inside this fixture")
    if not re.fullmatch(r"[A-Z0-9]{4,32}", tag):
        raise ValueError("Use a new short uppercase alphanumeric tag")
    actions = []
    for name, code in [("ZERO", 0), ("FAILED", 17)]:
        path = work / f"phone-{tag.lower()}-{name.lower()}.py"
        marker = f"REX_LAB_PHONE_{name}_{tag}"
        output = repr(marker + "\n")
        if code:
            output += " + '0123456789abcdef' * 768 + '\\n'"
        code_text = (
            "from pathlib import Path\nimport sys, time\ntime.sleep(2)\n"
            f"data = ({output}).encode('utf-8')\n"
            + ("Path(__file__).with_suffix('.stdout').write_bytes(data)\n" if code else "")
            + f"sys.stdout.buffer.write(data)\nsys.exit({code})\n"
        )
        write_new(path, code_text)
        actions.append(f"python3 {path.name}")
    witness = work / f"child-{tag.lower()}.txt"
    write_new(witness, "PENDING\n")
    configuration = {
        "lab": lab, "backend": backend, "tag": tag, "storeRoot": str(store.resolve()),
        "successCommand": actions[0], "failureCommand": actions[1], "childFile": str(witness),
        "releaseSignal": f"release-{tag.lower()}",
        "childReport": f"REX_LAB_PRIVATE_REPORT_{secrets.token_hex(8).upper()}",
    }
    destination = root / f"phone-work-{tag.lower()}.json"
    write_new(destination, json.dumps(configuration))
    print(f"HEELER_DEVIN_COMPOSER_WORK_LAB={destination}")


def watch(contract):
    root = owned_root(contract.parent)
    cfg = json.loads(contract.read_text())
    signal = (root / cfg["releaseSignal"]).resolve()
    witness = Path(cfg["childFile"]).resolve()
    if signal.parent != root or root not in witness.parents or witness.read_text() != "PENDING\n":
        raise ValueError("The child witness must belong to this still-pending run")
    until = time.monotonic() + 1200
    while time.monotonic() < until:
        if signal.is_file() and signal.read_text() == cfg["tag"]:
            tmp = witness.with_suffix(".new")
            write_new(tmp, cfg["childReport"] + "\n")
            tmp.replace(witness)
            print("Released the dedicated child after the phone observed the lead's reply")
            return
        time.sleep(0.2)
    raise TimeoutError("The test never released this child")


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    mk = actions.add_parser("prepare")
    mk.add_argument("signed_lab", type=Path)
    mk.add_argument("backend", choices=["rex", "herdrTUI"])
    mk.add_argument("private_store", type=Path)
    mk.add_argument("tag", help="Unique uppercase label for this run")
    gate = actions.add_parser("watch")
    gate.add_argument("contract", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.signed_lab.resolve(), args.backend, args.private_store.resolve(), args.tag)
    else:
        watch(args.contract.resolve())
