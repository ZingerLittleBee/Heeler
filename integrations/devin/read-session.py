"""Read one local Devin session from its active SQLite chain. Writes only stdout."""
import base64
import hashlib
import json
import pathlib
import re
import sqlite3
import sys
import time


SHELL_EXIT_LINE = re.compile(r"Exit code: ([+-]?[0-9]{1,10})")


def content_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(part["text"] for part in value if isinstance(part, dict)
                         and part.get("type") in ("text", "input_text") and isinstance(part.get("text"), str))
    return ""


def message_chunk(message, part):
    # Streaming replies can retain their message ID while their text changes.
    if message["role"] not in ("user", "assistant") or message["message_id"] != part["id"]:
        return None
    body = content_text(message.get("content"))
    start = part["start"]
    if start >= len(body) or hashlib.sha256(body.encode()).hexdigest() != part["sha256"]:
        return None
    return body[start:start + 65536]


def row(message, limit):
    role = message["role"]
    meta = message.get("metadata") or {}
    extra = meta.get("extensions") or {}
    agent = extra.get("subagent/agent_id")
    body = content_text(message.get("content"))
    if role == "system":
        # This single typed envelope is the only system content sent to Chat.
        pattern = (r"<subagent_completion_notification>\s*\[Background subagent with agent_id="
                   + re.escape(str(agent)) + r" completed\]\s*(.*?)\s*</subagent_completion_notification>")
        report = re.fullmatch(pattern, body, flags=re.DOTALL) if extra.get("message/relayed_notice") is True else None
        role, body = "subagent_report", report[1] if report else ""
        if not report:
            agent = None
    calls = []
    for call in message.get("tool_calls") or ():
        if not isinstance(call.get("id"), str) or not isinstance(call.get("name"), str):
            continue
        args = call.get("arguments") or {}
        if not isinstance(args, dict):
            continue
        # Display complete arguments for an approval, or leave it to the terminal.
        inputs = {k: v for k, v in args.items() if k in (
            "file_path", "path", "content", "old_string", "new_string", "command",
            "description", "prompt", "questions", "plan", "shell_id", "agent_id", "task", "title", "is_background")}
        if call["name"] == "exec" and type(args.get("timeout")) is int and args["timeout"] == 0:
            inputs["timeout"] = 0
        options = {"write": {"file_path", "content"}, "edit": {"file_path", "old_string", "new_string"},
                   "exec": {"command", "shell_id", "timeout"}, "exit_plan_mode": {"plan"},
                   "ask_user_question": {"questions"}}
        known = options.get(call["name"])
        understood = known is None or all(k in known or (k == "replace_all" and v is False) for k, v in args.items())
        complete = understood and len(json.dumps(inputs, ensure_ascii=False).encode()) <= 16384
        calls.append(dict(id=call["id"], name=call["name"], arguments=inputs if complete else {}, complete=complete))
    record = dict(id=message["message_id"], role=role, text=body[:limit], truncated=len(body) > limit,
                  calls=calls, resultFor=message.get("tool_call_id"), finish=meta.get("finish_reason"),
                  timestamp=meta.get("created_at"), agentID=agent,
                  success=(extra.get("chisel/tool_result_meta") or {}).get("success"))
    if role == "tool":
        # Only the actual final line is evidence. A preview can end on a line
        # printed by the command, or cut through Devin's exit line.
        last = body.rfind("\n") + 1
        exit_line = SHELL_EXIT_LINE.fullmatch(body, last)
        if exit_line:
            record["shellExit"] = dict(code=int(exit_line[1]), outputLength=max(0, last - 1))
    elif limit and role in ("user", "assistant") and record["truncated"]:
        record["fullText"] = dict(length=len(body), sha256=hashlib.sha256(body.encode()).hexdigest())
    return record


def earlier_work(db, session, ids):
    """Recover public task events preceding the opening page, without adding older conversation text."""
    positions = {node: index for index, node in enumerate(ids)}
    events, call_ids = {}, set()
    launches = db.execute("""
        SELECT m.node_id, m.chat_message FROM message_nodes m
        WHERE m.session_id=? AND m.node_id<=? AND EXISTS (
            SELECT 1 FROM json_each(m.chat_message,'$.tool_calls') c
            WHERE json_extract(c.value,'$.name') IN ('run_subagent','exec','get_output')
              AND (json_type(c.value,'$.arguments.shell_id')='text'
                   OR (json_extract(c.value,'$.name')='exec' AND json_type(c.value,'$.arguments.timeout')='integer'
                       AND json_extract(c.value,'$.arguments.timeout')=0)
                   OR json_extract(c.value,'$.arguments.is_background')=1))
        ORDER BY m.node_id DESC LIMIT 128
    """, (session, ids[-1]))
    for node, raw in launches:
        if node not in positions:
            continue
        event = row(json.loads(raw), 0)
        calls = []
        for call in event["calls"]:
            args = call["arguments"]
            if not ((call["name"] == "run_subagent" and args.get("is_background") is True)
                    or (call["name"] == "exec" and args.get("timeout") == 0)
                    or (call["name"] in ("exec", "get_output") and args.get("shell_id"))):
                continue
            call["arguments"] = {k: args[k] for k in ("shell_id", "timeout", "command", "title", "is_background") if k in args}
            if len(json.dumps(call).encode()) <= 4096 and len(call_ids) < 128:
                call_ids.add(call["id"])
                calls.append(call)
        if calls:
            event["calls"] = calls
            events[node] = event
    if call_ids:
        params = ",".join("?" for _ in call_ids)
        results = db.execute("""
            SELECT node_id, chat_message FROM message_nodes WHERE session_id=? AND node_id<=?
            AND json_extract(chat_message,'$.role')='tool' AND json_extract(chat_message,'$.tool_call_id') IN ("""
            + params + ") ORDER BY node_id DESC LIMIT 256", (session, ids[-1], *call_ids))
        for node, raw in results:
            if node in positions:
                events[node] = row(json.loads(raw), 2048)
    remaining = 128 * 1024
    bounded = []
    for node in sorted(events, reverse=True):
        event = dict(offset=positions[node], row=events[node])
        remaining -= len(json.dumps(event, ensure_ascii=False).encode())
        if remaining < 0:
            break
        bounded.append(event)
    return list(reversed(bounded))


def read(db, request):
    session = request["session"]
    offset, limit = request.get("offset"), request["limit"]
    if not 1 <= limit <= 33 or (offset is not None and not 0 <= offset < 2**31):
        raise ValueError("invalid page")
    part = request.get("messageText")
    if part is not None and (limit != 1 or offset is None or not isinstance(part["start"], int) or part["start"] < 0):
        raise ValueError("invalid message range")
    db.execute("BEGIN")
    header = db.execute("SELECT main_chain_id,title,model FROM sessions WHERE id=?", (session,)).fetchone()
    if header is None:
        return dict(offset=0, total=0, rows=[])
    head, title, model = header
    # During a tool approval the ACP writer has staged a direct child but has
    # not advanced main_chain_id. Never follow siblings or a subagent head.
    if head is not None:
        child = db.execute("""
            SELECT m.node_id FROM message_nodes m
            WHERE m.session_id=? AND m.parent_node_id=? AND json_extract(m.chat_message,'$.role')='assistant'
            AND m.node_id=(SELECT MAX(node_id) FROM message_nodes WHERE session_id=m.session_id)
            AND 1=(SELECT COUNT(*) FROM message_nodes WHERE session_id=m.session_id AND parent_node_id=m.parent_node_id)
            AND NOT EXISTS(SELECT 1 FROM subagent_heads WHERE session_id=m.session_id AND chain_node_id=m.node_id)
        """, (session, head)).fetchone()
        if child:
            head = child[0]
    chain = """
        WITH RECURSIVE chain(id) AS (
            SELECT ? UNION ALL SELECT m.parent_node_id FROM message_nodes m JOIN chain ON m.node_id=chain.id
            WHERE m.session_id=? AND m.parent_node_id < m.node_id
        )
        SELECT m.node_id FROM chain JOIN message_nodes m ON m.node_id=chain.id AND m.session_id=?
        WHERE json_extract(m.chat_message,'$.role') IN ('assistant','tool') OR
              (json_extract(m.chat_message,'$.role')='user' AND json_extract(m.chat_message,'$.metadata.is_user_input')=1)
              OR (json_extract(m.chat_message,'$.role')='system'
                  AND json_extract(m.chat_message,'$.metadata.extensions."message/relayed_notice"')=1
                  AND json_type(m.chat_message,'$.metadata.extensions."subagent/agent_id"')='text')
        ORDER BY m.node_id
    """
    ids = [r[0] for r in db.execute(chain, (head, session, session))]
    start = max(0, len(ids) - limit) if offset is None else min(len(ids), offset)
    result = []
    # Limit both one row and the entire reply. A tool detail may request one larger row.
    text_limit = 131072 if request.get("expanded") and limit == 1 else 8192
    for node in ids[start:start + limit]:
        (raw,) = db.execute("SELECT chat_message FROM message_nodes WHERE session_id=? AND node_id=?",
                            (session, node)).fetchone()
        message = json.loads(raw)
        if part is not None:
            return dict(offset=start, total=len(ids), rows=[], textChunk=message_chunk(message, part))
        result.append(row(message, text_limit))
    if result and offset is None and start and request.get("earlierWork"):
        result[0]["earlierWork"] = earlier_work(db, session, ids[:start])
    if result and start + len(result) == len(ids):
        # A child can finish after the main turn. Only its final public text
        # accompanies the tail. The reducer associates it with a launch on this chain.
        reports = {}
        for agent, raw in db.execute("""
            SELECT h.agent_id,m.chat_message FROM subagent_heads h JOIN message_nodes m
            ON m.session_id=h.session_id AND m.node_id=h.chain_node_id
            WHERE h.session_id=? AND json_extract(m.chat_message,'$.role')='assistant'
              AND json_extract(m.chat_message,'$.metadata.finish_reason')='stop'
            ORDER BY h.updated_at DESC LIMIT 32
        """, (session,)):
            child = json.loads(raw)
            reports[agent] = content_text(child.get("content"))[:4096]
        result[-1]["childReports"] = reports
    return dict(offset=start, total=len(ids), title=title, model=model, rows=result)


def main():
    request = json.loads(base64.b64decode(sys.argv[1], validate=True))
    path = pathlib.Path(request["root"]) / "sessions.db"
    # mode=ro includes committed WAL data and refuses a missing database.
    with sqlite3.connect(path.as_uri() + "?mode=ro", timeout=0.5, uri=True) as db:
        deadline = time.monotonic() + 3
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 3000)
        answer = read(db, request)
    data = json.dumps(answer, ensure_ascii=False, separators=(",", ":")).encode()
    if len(data) > 1048576:
        raise ValueError("page too large")
    sys.stdout.buffer.write(data)


if __name__ == "__main__":
    main()
