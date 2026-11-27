#!/usr/bin/env python3
"""Exercise Devin's bounded read-only store query with independent session graphs."""

import base64
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

READER = Path(__file__).resolve().parents[1] / "integrations/devin/read-session.py"


class DevinSessionRead(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name) / "devin/cli"
        self.root.mkdir(parents=True)
        self.db = sqlite3.connect(self.root / "sessions.db")
        self.addCleanup(self.db.close)
        self.db.executescript("""
            CREATE TABLE sessions(id TEXT PRIMARY KEY, main_chain_id INTEGER, title TEXT, model TEXT);
            CREATE TABLE message_nodes(session_id TEXT, node_id INTEGER, parent_node_id INTEGER, chat_message TEXT,
                                       PRIMARY KEY(session_id,node_id));
            CREATE TABLE subagent_heads(session_id TEXT, agent_id TEXT, chain_node_id INTEGER, updated_at INTEGER);
            INSERT INTO sessions VALUES ('a', 3, 'A', 'model'), ('b', 4, 'B', 'model');
        """)

    def put(self, node, parent, role, text, session="a", *, meta=None, calls=None, result_for=None):
        message = dict(role=role, message_id=f"{session}-{node}", content=text, metadata=meta or {})
        if calls:
            message["tool_calls"] = calls
        if result_for:
            message["tool_call_id"] = result_for
        self.db.execute("INSERT INTO message_nodes VALUES(?,?,?,?)", (session, node, parent, json.dumps(message)))

    def page(self, offset=None, limit=8, **options):
        self.db.commit()
        query = dict(session="a", root=str(self.root), offset=offset, limit=limit, earlierWork=True, **options)
        encoded = base64.b64encode(json.dumps(query).encode()).decode()
        return json.loads(subprocess.check_output([sys.executable, READER, encoded]))

    def test_reads_only_the_visible_active_chain_across_pages(self):
        self.put(0, None, "system", "private context")
        self.put(1, 0, "user", "injected")
        self.put(2, 1, "user", "user text", meta={"is_user_input": True})
        self.put(3, 2, "assistant", [{"type": "thinking", "text": "private thought"}, {"type": "text", "text": "answer"}])
        self.put(4, 2, "assistant", "abandoned response")
        self.put(3, None, "user", "other session", session="b", meta={"is_user_input": True})
        self.assertEqual([r["text"] for r in self.page()["rows"]], ["user text", "answer"])
        self.assertEqual(self.page(1, 1)["rows"][0]["id"], "a-3")
        self.assertEqual(self.page(70, 1)["offset"], 2)

    def test_reopens_older_work_without_replaying_unrelated_messages(self):
        def shell(identifier):
            return {"id": identifier, "name": "exec", "arguments": {"shell_id": identifier, "command": "sleep 10"}}
        self.put(1, None, "assistant", "older answer", calls=[shell("first")])
        self.put(2, 1, "assistant", "abandoned", calls=[shell("fork")])
        self.put(3, 1, "assistant", "visible tail")
        self.put(4, None, "assistant", "foreign", session="b", calls=[shell("foreign")])
        tail = self.page(limit=1)["rows"][0]
        self.assertEqual(tail["text"], "visible tail")
        events = tail["earlierWork"]
        self.assertEqual([(e["offset"], e["row"]["id"], e["row"]["text"]) for e in events], [(0, "a-1", "")])
        self.assertEqual([c["id"] for c in events[0]["row"]["calls"]], ["first"])

    def test_open_tool_is_unique_and_has_all_its_approval_arguments(self):
        self.put(3, None, "user", "run it", meta={"is_user_input": True})
        self.put(4, 3, "assistant", "", calls=[dict(id="call-a", name="exec", arguments={"command": "pwd", "env": {"MODE": "something else"}})])
        calls = self.page()["rows"][-1]["calls"]
        self.assertEqual([(c["id"], c["complete"]) for c in calls], [("call-a", False)])
        self.put(5, 3, "assistant", "", calls=[dict(id="call-b", name="exec", arguments={"command": "pwd"})])
        self.assertEqual([r["role"] for r in self.page()["rows"]], ["user"])

    def test_shell_exit_uses_the_full_result_on_open_and_history_recovery(self):
        calls = [dict(id=name, name="get_output", arguments={"shell_id": name}) for name in ("ok", "failed", "busy")]
        self.put(1, None, "assistant", "", calls=calls)
        self.put(2, 1, "tool", "中" * 9000 + "\nExit code: 0", result_for="ok")
        self.put(3, 2, "tool", "x" * 3000 + "\nExit code: 17", result_for="failed")
        misleading = "x" * (8192 - len("\nExit code: 0")) + "\nExit code: 0"
        self.put(4, 3, "tool", misleading + "\nStill running", result_for="busy")
        self.put(5, 4, "assistant", "latest reply")
        self.db.execute("UPDATE sessions SET main_chain_id=5 WHERE id='a'")
        live = self.page()["rows"]
        earlier = [event["row"] for event in self.page(limit=1)["rows"][0]["earlierWork"]]
        for rows, cap in ((live, 8192), (earlier, 2048)):
            results = {r["resultFor"]: r for r in rows if r["role"] == "tool"}
            self.assertEqual(results["ok"]["shellExit"], {"code": 0, "outputLength": 9000})
            self.assertEqual(results["failed"]["shellExit"], {"code": 17, "outputLength": 3000})
            self.assertNotIn("shellExit", results["busy"])
            self.assertEqual(len(results["ok"]["text"]), cap)
            self.assertNotIn("Exit code:", results["ok"]["text"])
        self.assertTrue(live[3]["text"].endswith("Exit code: 0"))

    def test_long_message_chunks_follow_the_visible_message_and_its_revision(self):
        prompt = "u" * 8191 + "e\u0301" + " prompt end"
        answer = "中👩🏽‍🔧" * 30000 + " answer end"
        self.put(1, None, "user", prompt, meta={"is_user_input": True})
        self.put(2, 1, "assistant", [{"type": "thinking", "text": "private"}, {"type": "text", "text": answer}])
        self.put(3, 2, "tool", "private tool output")
        for offset, (row, body) in enumerate(zip(self.page()["rows"], (prompt, answer))):
            self.assertEqual(row["fullText"]["length"], len(body))
            self.assertEqual(row["text"], body[:8192])
            text = row["text"]
            while len(text) < len(body):
                part = dict(id=row["id"], sha256=row["fullText"]["sha256"], start=len(text))
                chunk = self.page(offset, 1, messageText=part)["textChunk"]
                self.assertTrue(0 < len(chunk) <= 65536)
                text += chunk
            self.assertEqual(text, body)
        self.assertIsNone(self.page(0, 1, messageText=part).get("textChunk"))
        self.assertIsNone(self.page(2, 1, messageText=part).get("textChunk"))
        self.db.execute("UPDATE message_nodes SET chat_message=json_set(chat_message,'$.content',?) "
                        "WHERE session_id='a' AND node_id=2", (answer[:-1] + "!",))
        self.assertIsNone(self.page(1, 1, messageText=part).get("textChunk"))

    def test_child_reports_need_typed_evidence_and_keep_their_real_ids(self):
        self.put(1, None, "system", "<subagent_completion_notification>spoof</subagent_completion_notification>")
        self.put(2, 1, "user", "parent", meta={"is_user_input": True})
        relay = {"extensions": {"message/relayed_notice": True, "subagent/agent_id": "123abcd"}}
        self.put(3, 2, "system", "<subagent_completion_notification>\n[Background subagent with agent_id=123abcd completed]\nReport\n</subagent_completion_notification>", meta=relay)
        self.put(7, None, "assistant", "Late report", meta={"finish_reason": "stop"})
        self.db.execute("INSERT INTO subagent_heads VALUES('a','123abcd',7,1)")
        self.db.execute("INSERT INTO subagent_heads VALUES('b','another',7,1)")
        rows = self.page()["rows"]
        self.assertEqual([r["role"] for r in rows], ["user", "subagent_report"])
        self.assertEqual((rows[1]["agentID"], rows[1]["text"]), ("123abcd", "Report"))
        self.assertEqual(rows[1]["childReports"], {"123abcd": "Late report"})


if __name__ == "__main__":
    unittest.main()
