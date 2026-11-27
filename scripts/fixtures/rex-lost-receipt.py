#!/usr/bin/env python3
"""Drop one real Enter response on a disposable Rex control socket."""
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
    assert target != record["peer"] and config["program"] == "pi"
    source = Path(config["rexSocket"])
    assert any(part.startswith("heeler-lab-") for part in source.parts)
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    socket = args.output / "receipt.sock"

    def save():
        (args.output / "evidence.json").write_text(json.dumps(record, indent=2) + "\n")

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
                    if from_client and payload.get("block_id") == target:
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
                            raise ValueError("Rex did not accept the test Enter")
                        record["droppedResponses"] += 1
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
    path.write_text(json.dumps(dict(config, rexSocket=str(socket), receiptFaultBlock=target)) + "\n")
    path.chmod(0o600)
    async with listener:
        await listener.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    asyncio.run(main(parser.parse_args()))
