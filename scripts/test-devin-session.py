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

    def put(self, node, parent, role, text, session="a", *, meta=None, calls=None):
        message = dict(role=role, message_id=f"{session}-{node}", content=text, metadata=meta or {})
        if calls:
            message["tool_calls"] = calls
        self.db.execute("INSERT INTO message_nodes VALUES(?,?,?,?)", (session, node, parent, json.dumps(message)))

    def page(self, offset=None, limit=8):
        self.db.commit()
        query = dict(session="a", root=str(self.root), offset=offset, limit=limit)
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
