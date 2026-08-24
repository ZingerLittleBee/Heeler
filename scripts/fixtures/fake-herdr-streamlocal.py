#!/usr/bin/env python3

import argparse
import json
import os
import re
import signal
import socket
import threading
import time
from typing import Optional

# One scripted run, spelled `fixture:<behavior>:<unique>`. Tests plant it in a
# request parameter the Transport carries to herdr — `tab.create`'s cwd,
# `worktree.create`'s branch, `workspace.create`'s cwd — and the fixture
# derives every id it answers with from it, so each later request in the same
# launch carries the token onward. That both steers the scripted failures and
# keeps one test's recorded requests from being confused with another's.
SCRIPT_TOKEN_PATTERN = re.compile(r"fixture:[a-z0-9]+:[0-9a-f-]+")

# `pane.read` on this pane id answers with the requests recorded under the
# token that follows it, rather than pane output.
RECORD_QUERY_PREFIX = "record:"

AGENT_PANE_BUSY = {
    "code": "agent_pane_busy",
    "message": "pane is not an available shell",
}
# Any API error that is not `agent_pane_busy`, which is the whole contract the
# compensating close and remove hang off. The code is the fixture's own on
# purpose: herdr 0.7.5's refusal of an unsupported kind is recorded only by its
# message, so inventing a plausible code here would read as a verified fact.
NON_RETRYABLE_START_FAILURE = {
    "code": "fixture_agent_start_refused",
    "message": "scripted non-retryable agent.start failure",
}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--stale-socket", action="append", required=True)
    parser.add_argument("--count-file", required=True)
    return parser.parse_args()


class _OneShotBarrier:
    def __init__(self, condition: threading.Condition) -> None:
        self.condition = condition
        self.tokens: set[str] = set()

    def record(self, token: object) -> None:
        if not isinstance(token, str):
            return
        with self.condition:
            self.tokens.add(token)
            self.condition.notify_all()

    def wait(self, token: object) -> bool:
        if not isinstance(token, str):
            return False
        with self.condition:
            observed = self.condition.wait_for(
                lambda: token in self.tokens,
                timeout=20,
            )
            if observed:
                self.tokens.discard(token)
            return observed


class Server:
    def __init__(self, socket_path: str, stale_socket_paths: list[str], count_file: str) -> None:
        self.socket_path = socket_path
        self.stale_socket_paths = stale_socket_paths
        self.count_file = count_file
        self.count = 0
        self.count_lock = threading.Lock()
        self.hang_condition = threading.Condition()
        self.hang_requests = _OneShotBarrier(self.hang_condition)
        self.pane_hangs = _OneShotBarrier(self.hang_condition)
        self.pane_delays = _OneShotBarrier(self.hang_condition)
        self.script_lock = threading.Lock()
        self.recorded_requests: dict[str, list[str]] = {}
        self.agent_start_attempts: dict[str, int] = {}
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
                self.hang_requests.record(envelope.get("id"))
                time.sleep(30)
                return
            params = envelope.get("params", {})
            if method == "pane.read" and params.get("pane_id") == "hang":
                time.sleep(30)
                return
            pane_id = params.get("pane_id") if isinstance(params, dict) else None
            pane_hang_token = self._fixture_token(pane_id, "fixture:hang:")
            if method == "pane.read" and pane_hang_token is not None:
                self.pane_hangs.record(pane_hang_token)
                time.sleep(30)
                return
            pane_delay_token = self._fixture_token(pane_id, "fixture:delay:")
            pane_await_delay_token = self._fixture_token(
                pane_id,
                "fixture:await-delay:",
            )
            pane_observer_token = self._fixture_token(
                pane_id,
                "fixture:await-hang:",
            )
            record_query = self._fixture_token(pane_id, RECORD_QUERY_PREFIX)
            if method == "pane.read" and pane_delay_token is not None:
                self.pane_delays.record(pane_delay_token)
                time.sleep(5)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(pane_id, "delayed"),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "pane.read" and pane_await_delay_token is not None:
                observed = self.pane_delays.wait(pane_await_delay_token)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(
                        pane_id,
                        "observed" if observed else "not observed",
                    ),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "pane.read" and record_query is not None:
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(
                        pane_id,
                        self._recorded(record_query),
                    ),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "pane.read" and pane_observer_token is not None:
                observed = self.pane_hangs.wait(pane_observer_token)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(
                        pane_id,
                        "observed" if observed else "not observed",
                    ),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "fixture.await_hang":
                response = {
                    "id": envelope.get("id"),
                    "result": {
                        "observed": self.hang_requests.wait(envelope.get("extra"))
                    },
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "oversized":
                payload = b"x" * (1_048_576 + 1)
                chunk_size = 16 * 1024
            else:
                token = self._scripted_run_token(params)
                if token is not None:
                    self._record(token, method, params)
                    if (
                        method == "agent.start"
                        and token.split(":")[1] == "startdrop"
                    ):
                        return
                error = self._scripted_error(method, token)
                if error is not None:
                    response = {"id": envelope.get("id"), "error": error}
                elif method == "agent.rename" and params.get("target") == "api-error":
                    response = {
                        "id": envelope.get("id"),
                        "error": {"code": 500, "message": "scripted failure"},
                    }
                else:
                    response = {
                        "id": envelope.get("id"),
                        "result": self._result(method, params, token),
                    }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7

            for offset in range(0, len(payload), chunk_size):
                try:
                    connection.sendall(payload[offset : offset + chunk_size])
                except BrokenPipeError:
                    return

    @staticmethod
    def _fixture_token(value: object, prefix: str) -> Optional[str]:
        if not isinstance(value, str) or not value.startswith(prefix):
            return None
        token = value[len(prefix) :]
        return token or None

    @staticmethod
    def _scripted_run_token(params: object) -> Optional[str]:
        if not isinstance(params, dict):
            return None
        match = SCRIPT_TOKEN_PATTERN.search(
            json.dumps(params, separators=(",", ":"), sort_keys=True)
        )
        return match.group(0) if match else None

    def _record(self, token: str, method: str, params: object) -> None:
        entry = "{} {}".format(
            method,
            json.dumps(params, separators=(",", ":"), sort_keys=True),
        )
        with self.script_lock:
            self.recorded_requests.setdefault(token, []).append(entry)

    def _recorded(self, token: str) -> str:
        with self.script_lock:
            return "\n".join(self.recorded_requests.get(token, []))

    def _scripted_error(self, method: str, token: Optional[str]) -> Optional[dict]:
        """The failure a token scripts for `agent.start`, or None to succeed.

        `busyN` refuses the first N starts the way herdr 0.7.5 refuses a pane
        whose shell has not reached its prompt, then lets the launch through;
        `busyforever` never lets it through; `startfails` refuses once with a
        code no retry policy may swallow; `startdrop` is handled in `_serve`
        by closing the channel with no reply (an ambiguous transport failure);
        `ok` scripts no failure at all.

        A word outside that set is refused rather than treated as `ok`: a
        mistyped behaviour would otherwise leave a test green while proving
        nothing, which is the one way a fixture can lie.
        """
        if token is None or method != "agent.start":
            return None
        behavior = token.split(":")[1]
        if behavior == "ok":
            return None
        if behavior == "startdrop":
            return None
        if behavior == "startfails":
            return dict(NON_RETRYABLE_START_FAILURE)
        if behavior == "busyforever":
            return dict(AGENT_PANE_BUSY)
        if behavior.startswith("busy") and behavior[4:].isdigit():
            with self.script_lock:
                served = self.agent_start_attempts.get(token, 0)
                self.agent_start_attempts[token] = served + 1
            if served < int(behavior[4:]):
                return dict(AGENT_PANE_BUSY)
            return None
        return {
            "code": "fixture_unknown_behavior",
            "message": "no scripted behaviour named " + behavior,
        }

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

    def _result(self, method: str, params: object, token: Optional[str] = None) -> object:
        if token is not None:
            scripted = self._scripted_result(method, token)
            if scripted is not None:
                return scripted
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
            request = params if isinstance(params, dict) else {}
            pane_id = request.get("pane_id", "pane-1")
            source = request.get("source", "recent")
            output_format = request.get("format", "text")
            return self._pane_read_result(
                pane_id,
                "fixture output",
                source=source,
                output_format=output_format,
            )
        if method == "agent.read":
            request = params if isinstance(params, dict) else {}
            target = request.get("target", "pane-1")
            source = request.get("source", "recent")
            output_format = request.get("format", "text")
            text = "fixture agent output"
            if output_format == "ansi" and request.get("strip_ansi") is False:
                text = "\x1b[31mfixture agent output\x1b[0m"
            return self._pane_read_result(
                target,
                text,
                source=source,
                output_format=output_format,
            )
        if method == "agent.prompt":
            request = params if isinstance(params, dict) else {}
            is_expected_prompt = (
                request.get("target") == "pane-1"
                and request.get("text") == "fixture prompt"
                and "wait" not in request
            )
            pane_id = "pane-1" if is_expected_prompt else "fixture:invalid-prompt"
            return {
                "type": "agent_prompted",
                "agent": self._agent(pane_id, "workspace-1", status="working"),
            }
        if method == "agent.send_keys":
            # Thin ok-envelope RPC; key-spelling contract is asserted in unit
            # tests against the spellings Monitor ships (enter/esc/ctrl+c/…).
            return {"type": "ok"}
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
        if method == "workspace.create":
            return {
                "type": "workspace_created",
                "workspace": self._workspace("workspace-new"),
                "tab": self._tab("tab-workspace", "workspace-new"),
                "root_pane": self._pane(
                    "pane-workspace", "tab-workspace", "workspace-new"
                ),
            }
        if method == "workspace.close":
            return {"type": "ok"}
        if method == "agent.start":
            pane_id = params.get("pane_id", "pane-new") if isinstance(params, dict) else "pane-new"
            workspace_id = (
                "workspace-worktree"
                if pane_id == "pane-worktree"
                else "workspace-new"
                if pane_id == "pane-workspace"
                else "workspace-1"
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

    def _scripted_result(self, method: str, token: str) -> Optional[object]:
        """Ids derived from `token`, so a scripted launch stays self-identifying.

        `tab.create`, `worktree.create` and `workspace.create` hand the
        Transport a pane the token names; the `agent.start`, `pane.close`,
        `worktree.remove` and `workspace.close` that follow therefore carry
        it back without the test having to inject anything else.
        """
        pane_id = "pane:" + token
        tab_id = "tab:" + token
        workspace_id = "workspace:" + token
        if method == "tab.create":
            return {
                "type": "tab_created",
                "tab": self._tab(tab_id, "workspace-1"),
                "root_pane": self._pane(pane_id, tab_id, "workspace-1"),
            }
        if method == "worktree.create":
            return {
                "type": "worktree_created",
                "workspace": self._workspace(workspace_id),
                "tab": self._tab(tab_id, workspace_id),
                "root_pane": self._pane(pane_id, tab_id, workspace_id),
                "worktree": {
                    "path": "/tmp/worktree/" + token,
                    "branch": "task/" + token,
                    "is_bare": False,
                    "is_detached": False,
                    "is_prunable": False,
                    "is_linked_worktree": True,
                    "label": "fixture",
                    "open_workspace_id": workspace_id,
                },
            }
        if method == "workspace.create":
            return {
                "type": "workspace_created",
                "workspace": self._workspace(workspace_id),
                "tab": self._tab(tab_id, workspace_id),
                "root_pane": self._pane(pane_id, tab_id, workspace_id),
            }
        if method == "agent.start":
            return {
                "type": "agent_started",
                "argv": ["codex"],
                "agent": self._agent(pane_id, workspace_id, tab_id=tab_id),
            }
        if method == "worktree.remove":
            return {
                "type": "worktree_removed",
                "forced": False,
                "path": "/tmp/worktree/" + token,
                "workspace_id": workspace_id,
            }
        return None

    @staticmethod
    def _pane_read_result(
        pane_id: str,
        text: str,
        source: str = "recent",
        output_format: str = "text",
    ) -> object:
        return {
            "type": "pane_read",
            "read": {
                "pane_id": pane_id,
                "workspace_id": "workspace-1",
                "tab_id": "tab-1",
                "source": source,
                "format": output_format,
                "text": text,
                "revision": 1,
                "truncated": False,
            },
        }

    def _agent(
        self,
        pane_id: str = "pane-1",
        workspace_id: str = "workspace-1",
        status: str = "idle",
        tab_id: Optional[str] = None,
    ) -> object:
        if tab_id is None:
            if workspace_id == "workspace-worktree":
                tab_id = "tab-worktree"
            elif workspace_id == "workspace-new":
                tab_id = "tab-workspace"
            else:
                tab_id = "tab-new"
        return {
            "terminal_id": "terminal-1",
            "agent": "codex",
            "terminal_title": "fixture",
            "terminal_title_stripped": "fixture",
            "agent_status": status,
            "workspace_id": workspace_id,
            "tab_id": tab_id,
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
