#!/usr/bin/env python3

import argparse
import json
import os
import signal
import socket
import threading
import time


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--stale-socket", action="append", required=True)
    parser.add_argument("--count-file", required=True)
    return parser.parse_args()


class Server:
    def __init__(self, socket_path: str, stale_socket_paths: list[str], count_file: str) -> None:
        self.socket_path = socket_path
        self.stale_socket_paths = stale_socket_paths
        self.count_file = count_file
        self.count = 0
        self.count_lock = threading.Lock()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    def start(self) -> None:
        self._unlink_paths()
        for stale_socket_path in self.stale_socket_paths:
            stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            stale.bind(stale_socket_path)
            stale.close()
            os.chmod(stale_socket_path, 0o777)

        self.listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o777)
        self.listener.listen()
        self._write_count()

        while True:
            connection, _ = self.listener.accept()
            threading.Thread(
                target=self._serve,
                args=(connection,),
                daemon=True,
            ).start()

    def close(self) -> None:
        self.listener.close()
        self._unlink_paths()

    def _serve(self, connection: socket.socket) -> None:
        with connection:
            self._increment_count()
            request = bytearray()
            while not request.endswith(b"\n"):
                chunk = connection.recv(1024)
                if not chunk:
                    return
                request.extend(chunk)

            envelope = json.loads(request)
            method = envelope.get("method")
            if method == "events.subscribe":
                self._serve_events(connection, envelope)
                return
            if method == "eof":
                return
            if method == "hang":
                time.sleep(30)
                return
            params = envelope.get("params", {})
            if method == "pane.read" and params.get("pane_id") == "hang":
                time.sleep(30)
                return
            if method == "oversized":
                payload = b"x" * (1_048_576 + 1)
                chunk_size = 16 * 1024
            else:
                if method == "agent.rename" and params.get("target") == "api-error":
                    response = {
                        "id": envelope.get("id"),
                        "error": {"code": "fixture_error", "message": "scripted failure"},
                    }
                else:
                    response = {
                        "id": envelope.get("id"),
                        "result": self._result(method, params),
                    }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7

            for offset in range(0, len(payload), chunk_size):
                try:
                    connection.sendall(payload[offset : offset + chunk_size])
                except BrokenPipeError:
                    return

    def _serve_events(self, connection: socket.socket, envelope: object) -> None:
        request_id = envelope.get("id") if isinstance(envelope, dict) else None
        params = envelope.get("params", {}) if isinstance(envelope, dict) else {}
        subscriptions = params.get("subscriptions", []) if isinstance(params, dict) else []
        pane_ids = {
            subscription.get("pane_id")
            for subscription in subscriptions
            if isinstance(subscription, dict) and subscription.get("pane_id") is not None
        }

        if "fixture:reject" in pane_ids:
            self._send_event_line(
                connection,
                {
                    "id": request_id,
                    "error": {
                        "code": "fixture_rejected",
                        "message": "scripted rejection",
                    },
                },
            )
            return

        if "fixture:no-ack" in pane_ids:
            while connection.recv(1024):
                pass
            return

        self._send_event_line(
            connection,
            {
                "id": request_id,
                "result": {"type": "subscription_started"},
            },
        )

        if "fixture:remote-close" in pane_ids:
            self._send_event_line(
                connection,
                {
                    "event": "pane_agent_status_changed",
                    "data": {"pane_id": "fixture:remote-close"},
                },
            )
            return

        if subscriptions != [{"type": "pane.created"}]:
            self._send_event_line(
                connection,
                {"event": "fixture_noncanonical_subscription", "data": subscriptions},
            )
            return

        try:
            connection.sendall(b"this is not json\n")
        except BrokenPipeError:
            return
        lines = [
            {
                "event": "future_herdr_event",
                "data": {"value": "preserved"},
            },
            {
                "event": "pane_created",
                "data": {"pane_id": "fixture:event"},
            },
            {
                "event": "pane_created",
                "data": {"pane_id": "fixture:event"},
            },
        ]
        for line in lines:
            self._send_event_line(connection, line)

        while connection.recv(1024):
            pass

    def _send_event_line(self, connection: socket.socket, line: object) -> None:
        payload = json.dumps(line, separators=(",", ":")).encode() + b"\n"
        for offset in range(0, len(payload), 7):
            try:
                connection.sendall(payload[offset : offset + 7])
            except BrokenPipeError:
                return

    def _result(self, method: str, params: object) -> object:
        if method == "ping" or method == "partial":
            return {"protocol": 17, "version": "fake"}
        if method == "agent.list":
            return {"type": "agent_list", "agents": []}
        if method == "session.snapshot":
            return {
                "type": "session_snapshot",
                "snapshot": {
                    "version": "fake",
                    "protocol": 17,
                    "workspaces": [],
                    "tabs": [],
                    "panes": [],
                    "layouts": [],
                    "agents": [],
                },
            }
        if method == "pane.read":
            pane_id = params.get("pane_id", "pane-1") if isinstance(params, dict) else "pane-1"
            return {
                "type": "pane_read",
                "read": {
                    "pane_id": pane_id,
                    "workspace_id": "workspace-1",
                    "tab_id": "tab-1",
                    "source": "recent",
                    "format": "text",
                    "text": "fixture output",
                    "revision": 1,
                    "truncated": False,
                },
            }
        if method == "pane.close":
            return {"type": "ok"}
        if method == "tab.create":
            return {
                "type": "tab_created",
                "tab": self._tab("tab-new", "workspace-1"),
                "root_pane": self._pane("pane-new", "tab-new", "workspace-1"),
            }
        if method == "worktree.create":
            return {
                "type": "worktree_created",
                "workspace": self._workspace("workspace-worktree"),
                "tab": self._tab("tab-worktree", "workspace-worktree"),
                "root_pane": self._pane(
                    "pane-worktree", "tab-worktree", "workspace-worktree"
                ),
                "worktree": {
                    "path": "/tmp/worktree",
                    "branch": "task/fixture",
                    "is_bare": False,
                    "is_detached": False,
                    "is_prunable": False,
                    "is_linked_worktree": True,
                    "label": "fixture",
                    "open_workspace_id": "workspace-worktree",
                },
            }
        if method == "agent.start":
            pane_id = params.get("pane_id", "pane-new") if isinstance(params, dict) else "pane-new"
            workspace_id = (
                "workspace-worktree" if pane_id == "pane-worktree" else "workspace-1"
            )
            return {
                "type": "agent_started",
                "argv": ["codex"],
                "agent": self._agent(pane_id, workspace_id),
            }
        if method == "agent.rename":
            return {"type": "agent_info", "agent": self._agent()}
        if method == "workspace.rename":
            return {"type": "workspace_info", "workspace": self._workspace()}
        return {"type": "ok"}

    def _agent(self, pane_id: str = "pane-1", workspace_id: str = "workspace-1") -> object:
        return {
            "terminal_id": "terminal-1",
            "agent": "codex",
            "terminal_title": "fixture",
            "terminal_title_stripped": "fixture",
            "agent_status": "idle",
            "workspace_id": workspace_id,
            "tab_id": "tab-worktree" if workspace_id == "workspace-worktree" else "tab-new",
            "pane_id": pane_id,
            "focused": False,
            "cwd": "/tmp",
            "foreground_cwd": "/tmp",
            "revision": 1,
        }

    def _workspace(self, workspace_id: str = "workspace-1") -> object:
        return {
            "workspace_id": workspace_id,
            "number": 1,
            "label": "Fixture",
            "focused": False,
            "pane_count": 1,
            "tab_count": 1,
            "active_tab_id": "tab-1",
            "agent_status": "idle",
        }

    def _tab(self, tab_id: str, workspace_id: str) -> object:
        return {
            "tab_id": tab_id,
            "workspace_id": workspace_id,
            "number": 1,
            "label": "Fixture",
            "focused": False,
            "pane_count": 1,
            "agent_status": "idle",
        }

    def _pane(self, pane_id: str, tab_id: str, workspace_id: str) -> object:
        return {
            "pane_id": pane_id,
            "terminal_id": f"terminal-{pane_id}",
            "workspace_id": workspace_id,
            "tab_id": tab_id,
            "focused": False,
            "agent_status": "idle",
            "revision": 1,
        }

    def _increment_count(self) -> None:
        with self.count_lock:
            self.count += 1
            self._write_count()

    def _write_count(self) -> None:
        temporary = f"{self.count_file}.tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.write(f"{self.count}\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, self.count_file)

    def _unlink_paths(self) -> None:
        for path in (self.socket_path, *self.stale_socket_paths):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def main() -> None:
    arguments = parse_arguments()
    server = Server(arguments.socket, arguments.stale_socket, arguments.count_file)

    def stop(_signal: int, _frame: object) -> None:
        server.close()
        raise SystemExit(0)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    server.start()


if __name__ == "__main__":
    main()
