#!/usr/bin/env python3
"""Loopback model provider for RexForegroundChatLiveTests with nativeControls enabled.

Run this on the same host as the two real CLIs. Pass their shared disposable
working directory. Set Claude's ANTHROPIC_BASE_URL to the printed address, or
append /v1 for a private Codex Responses provider. Each log line names only the
test marker and protocol event. The CLIs run the tool calls themselves.
"""

import argparse
import json
import re
import select
import shlex
import socket
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def latest_marker(inputs):
    if not isinstance(inputs, list):
        return "fixture ready", False
    for entry in reversed(inputs):
        if entry.get("type") == "function_call_output":
            return "fixture operation finished", False
        if entry.get("role") != "user":
            continue
        parts = entry.get("content", [])
        if isinstance(parts, str):
            parts = [{"type": "text", "text": parts}]
        for part in reversed(parts):
            if not isinstance(part, dict):
                continue
            if part.get("type") == "tool_result":
                return "fixture operation finished", False
            if part.get("type") not in ("text", "input_text"):
                continue
            markers = re.findall(r"REX_LAB_[A-Z0-9_]+", part.get("text", ""))
            if markers:
                marker = markers[-1]
                return marker, marker.startswith(("REX_LAB_APPROVE_", "REX_LAB_DECLINE_"))
    return "fixture ready", False


def messages_response(marker, permission, stream):
    message = {
        "id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
        "model": "fixture", "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 10, "output_tokens": 0},
    }
    if permission:
        filename = "heeler-lab-" + marker.lower() + ".txt"
        code = f"from pathlib import Path; Path({filename!r}).write_text({marker!r})"
        arguments = {"command": "python3 -c " + shlex.quote(code), "description": "Write the named Heeler lab marker"}
        part = {"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex, "name": "Bash", "input": arguments}
        start = dict(part, input={})
        delta = {"type": "input_json_delta", "partial_json": json.dumps(arguments)}
        end = "tool_use"
    else:
        part = {"type": "text", "text": marker}
        start = {"type": "text", "text": ""}
        delta = {"type": "text_delta", "text": marker}
        end = "end_turn"
    if not stream:
        return dict(message, content=[part], stop_reason=end, usage={"input_tokens": 10, "output_tokens": 3})
    return [
        {"type": "message_start", "message": message},
        {"type": "content_block_start", "index": 0, "content_block": start},
        {"type": "content_block_delta", "index": 0, "delta": delta},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": end, "stop_sequence": None}, "usage": {"output_tokens": 3}},
        {"type": "message_stop"},
    ]


def responses_response(marker, permission, stream, directory):
    if permission:
        filename = "heeler-lab-" + marker.lower() + ".txt"
        arguments = {
            "cmd": f"printf %s {shlex.quote(marker)} > {shlex.quote(filename)}",
            "workdir": str(directory), "sandbox_permissions": "require_escalated",
            "justification": "Write the named Heeler lab marker.",
        }
        raw = json.dumps(arguments)
        item = {
            "id": "fc_" + uuid.uuid4().hex, "type": "function_call", "call_id": "call_" + uuid.uuid4().hex,
            "name": "exec_command", "arguments": raw, "status": "completed",
        }
        start = dict(item, arguments="", status="in_progress")
        events = [
            {"type": "response.function_call_arguments.delta", "delta": raw},
            {"type": "response.function_call_arguments.done", "arguments": raw},
        ]
    else:
        part = {"type": "output_text", "text": marker, "annotations": []}
        item = {
            "id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
            "status": "completed", "content": [part],
        }
        start = dict(item, content=[], status="in_progress")
        events = [
            {"type": "response.content_part.added", "content_index": 0, "part": dict(part, text="")},
            {"type": "response.output_text.delta", "content_index": 0, "delta": marker},
        ]
    result = {
        "id": "resp_" + uuid.uuid4().hex, "object": "response", "created_at": int(time.time()),
        "status": "completed", "model": "fixture", "output": [item],
        "usage": {"input_tokens": 10, "output_tokens": 3, "total_tokens": 13},
    }
    if not stream:
        return result
    return [
        {"type": "response.created", "response": dict(result, status="in_progress", output=[])},
        {"type": "response.output_item.added", "output_index": 0, "item": start},
        *(dict(event, item_id=item["id"], output_index=0) for event in events),
        {"type": "response.output_item.done", "output_index": 0, "item": item},
        {"type": "response.completed", "response": result},
    ]


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, result):
        if isinstance(result, list):
            content_type = "text/event-stream"
            text = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in result)
        else:
            content_type = "application/json"
            text = json.dumps(result)
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({"data": [{"id": "fixture", "object": "model", "owned_by": "lab"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if "count_tokens" in self.path:
            self.reply({"input_tokens": 10})
            return
        messages = "messages" in self.path
        marker, permission = latest_marker(body.get("messages" if messages else "input", []))
        if permission:
            tool = "Bash" if messages else "exec_command"
            permission = any(entry.get("name") == tool for entry in body.get("tools", []))
        protocol = "messages" if messages else "responses"
        print(protocol, "request", marker, flush=True)
        if marker.startswith("REX_LAB_STOP_"):
            # Either the CLI closes the request after the user interrupts, or a
            # deliberately distinct reply exposes a turn that was left running.
            ready, _, _ = select.select([self.connection], [], [], 45)
            if ready and not self.connection.recv(1, socket.MSG_PEEK):
                print(protocol, "cancelled", marker, flush=True)
                return
            marker = "UNINTERRUPTED_" + marker
        if marker.startswith("REX_LAB_SUCCESSOR_"):
            time.sleep(4)
        stream = body.get("stream", False)
        response = (messages_response(marker, permission, stream) if messages
                    else responses_response(marker, permission, stream, self.server.directory))
        try:
            self.reply(response)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    directory = args.directory.resolve(strict=True)
    if not directory.is_dir() or not any(part.startswith("heeler-lab-") for part in directory.parts):
        parser.error("expected a disposable directory inside heeler-lab-*")
    with ThreadingHTTPServer(("127.0.0.1", args.port), Provider) as server:
        server.directory = directory
        print(f"http://127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
