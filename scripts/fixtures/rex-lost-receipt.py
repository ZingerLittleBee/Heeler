#!/usr/bin/env python3
"""Drop one accepted Enter or approval response on a disposable Rex control socket."""
import argparse
import asyncio
import json
import os
import re
from pathlib import Path


async def frame(reader):
    head = await reader.readexactly(2)
    length = head[1] & 127
    extra = await reader.readexactly({126: 2, 127: 8}.get(length, 0))
    if extra:
        length = int.from_bytes(extra, "big")
    if length > 16 * 1024 * 1024:
        raise ValueError("Oversized test frame")
    mask = await reader.readexactly(4 if head[1] & 128 else 0)
    body = await reader.readexactly(length)
    message = {}
    if head[0] == 0x81:
        decoded = bytes(value ^ mask[i % 4] for i, value in enumerate(body)) if mask else body
        message = json.loads(decoded)
    return head + extra + mask + body, message


async def main(args):
    config = json.loads(args.fixture.read_text())
    target = config["rexBlock"]
    record = {"target": target, "peer": config["peerBlock"], "matchingPastes": 0, "enterRequests": 0, "droppedResponses": 0}
    approval = args.approval_marker is not None
    assert target != record["peer"]
    if approval:
        assert config["program"] in ("claude", "codex")
        assert re.fullmatch(r"REX_LAB_APPROVE_[0-9A-F]{8}", args.approval_marker)
        assert re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", args.call_id or "")
        record = {"target": target, "peer": config["peerBlock"], "targetWrites": 0, "peerWrites": 0,
                  "successfulTargetResponses": 0, "droppedResponses": 0}
    else:
        assert config["program"] == "pi" and args.call_id is None
    source = Path(config["rexSocket"])
    assert any(part.startswith("heeler-lab-") for part in source.parts)
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    socket = args.output / "receipt.sock"

    def save():
        scratch = args.output / "evidence.tmp"
        scratch.write_text(json.dumps(record, indent=2) + "\n")
        scratch.replace(args.output / "evidence.json")

    async def serve(client, to_client):
        upstream, to_server = await asyncio.open_unix_connection(source)
        tasks = []
        try:
            for reader, writer in [(client, to_server), (upstream, to_client)]:
                writer.write(await reader.readuntil(b"\r\n\r\n"))
                await writer.drain()
            pending = None

            async def relay(reader, writer, from_client):
                nonlocal pending
                while True:
                    data, message = await frame(reader)
                    payload = message.get("payload", {}) or {}
                    if approval and from_client and message.get("method", "").endswith(".write"):
                        block = payload.get("block_id")
                        if block == record["peer"]:
                            record["peerWrites"] += 1
                        elif block == target:
                            record["targetWrites"] += 1
                            if record["targetWrites"] == 1:
                                key = payload.get("args", {}).get("data", "")
                                # A Rex write can carry one Kitty keypress and its release together.
                                # A release for another key or a second press must still fail the probe.
                                press = key.removesuffix("\x1b[49;1:3u")
                                if press not in ("1", "\x1b[49u", "\x1b[49;1u", "\x1b[49;;49u"):
                                    raise ValueError("The first target write was not option one")
                                record["optionOneWireHex"] = key.encode("ascii").hex()
                                pending = message["id"]
                        save()
                    if not approval and from_client and payload.get("block_id") == target:
                        method = message.get("method", "")
                        if method == "block.event":
                            event = payload.get("event", {})
                            marker = re.search(r"REX_LAB_RECEIPT_[0-9A-F]{8}", event.get("payload", {}).get("text", ""))
                            if event.get("type") == "paste" and marker:
                                record["marker"] = marker.group()
                                record["matchingPastes"] += 1
                                save()
                        if method.endswith(".write") and payload.get("args", {}).get("data") == "\r" and "marker" in record:
                            record["enterRequests"] += 1
                            if record["droppedResponses"] == 0:
                                pending = message.get("id")
                            save()
                    if not from_client and pending and message.get("id") == pending and message.get("type") == "response":
                        if message.get("error") is not None:
                            raise ValueError("Rex did not accept the test input")
                        record["droppedResponses"] += 1
                        if approval:
                            record["successfulTargetResponses"] += 1
                            pending = None
                            save()
                            # Keep the control link live while Heeler's input deadline expires.
                            continue
                        save()
                        return
                    writer.write(data)
                    await writer.drain()

            tasks = [asyncio.create_task(relay(client, to_server, True)), asyncio.create_task(relay(upstream, to_client, False))]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            to_client.close()
            to_server.close()

    listener = await asyncio.start_unix_server(serve, path=socket)
    os.chmod(socket, 0o600)
    save()
    path = args.output / "fixture.json"
    config.update(rexSocket=str(socket), receiptFaultBlock=target)
    if approval:
        config["approvalReceipt"] = {"evidence": str(args.output / "evidence.json"),
                                     "marker": args.approval_marker, "callID": args.call_id}
    path.write_text(json.dumps(config) + "\n")
    path.chmod(0o600)
    async with listener:
        await listener.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--approval-marker", help="unique marker already pending on an isolated Claude or Codex client")
    parser.add_argument("--call-id", help="independent call ID of that official pending request")
    asyncio.run(main(parser.parse_args()))
