"""Two pull requests for the SSH live suite's private enterprise HTTPS fixture.

Install with wrap_handler on the existing issue fixture. The fixture exposes
no forwarding client. Each attempted review or merge is recorded before a
response is sent, including rejected duplicates and mismatched heads.
"""

import io
import json
import re
import threading
from http import HTTPStatus


HOST = "heeler-lab-github-write.test"
REPOSITORY = "lab/write-fixture"
VIEWER = "heeler-lab-write-fixture"
TOKEN = "heeler-lab-write-synthetic"
PULLS = {9671: ("LAB_PULL_9671", "a" * 40), 9672: ("LAB_PULL_9672", "b" * 40)}
APPROVAL = re.compile(r"Heeler private approval [0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")
BRANCH = {"name": "main"}
LOCK = threading.RLock()


def pull(number, attempts, head_advanced):
    node, head = PULLS[number]
    if number == 9672 and head_advanced:
        head = "d" * 40
    changes = {row["action"] for row in attempts if row["node"] == node and row["accepted"]}
    merged = "merge" in changes
    reviews = [{"state": "APPROVED", "author": {"login": VIEWER}}] if "approve" in changes else []
    repository = {
        "id": "LAB_REPOSITORY", "name": "write-fixture", "nameWithOwner": REPOSITORY, "owner": {"login": "lab", "__typename": "Organization"},
        "defaultBranchRef": BRANCH, "viewerPermission": "ADMIN",
        "squashMergeAllowed": True, "mergeCommitAllowed": True, "rebaseMergeAllowed": True,
        "viewerDefaultMergeMethod": "SQUASH", "deleteBranchOnMerge": False,
    }
    return {
        "__typename": "PullRequest", "id": node, "number": number, "title": f"Private pull request {number}",
        "url": f"https://{HOST}/{REPOSITORY}/pull/{number}", "author": {"login": "lab-author"},
        "repository": repository, "baseRepository": repository, "headRepository": repository,
        "headRepositoryOwner": {"login": "lab"}, "viewerDidAuthor": False, "isCrossRepository": False,
        "state": "MERGED" if merged else "OPEN", "isDraft": False, "merged": merged,
        "mergedAt": "2026-01-02T00:01:00Z" if merged else None, "mergedBy": {"login": VIEWER} if merged else None,
        "updatedAt": "2026-01-02T00:01:00Z", "headRefName": f"lab-{number}", "baseRefName": "main",
        "headRefOid": head, "headRef": {"id": f"LAB_REF_{number}", "name": f"lab-{number}", "target": {"oid": head}},
        "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "isInMergeQueue": False, "isMergeQueueEnabled": False,
        "viewerCanMergeAsAdmin": True, "viewerCanEnableAutoMerge": True, "mergedByViewer": merged,
        "body": "Private pull request on loopback.", "labels": {"nodes": []}, "comments": {"totalCount": 0},
        "reviewRequests": {"nodes": []}, "latestOpinionatedReviews": {"nodes": reviews},
        "reviewDecision": "APPROVED" if reviews else None,
    }


def dispatch(query, variables, client, ledger, issue):
    with LOCK:
        attempts = [json.loads(row) for row in ledger.read_text().splitlines()]
        head_advanced = (ledger.parent / "pull-head-9672-advanced").is_dir()
        rows = {number: pull(number, attempts, head_advanced) for number in PULLS}
        data = {"viewer": {"login": VIEWER}}
        if query.lstrip().startswith("mutation"):
            is_review = re.search(r"\baddPullRequestReview\s*\(", query)
            is_merge = re.search(r"\bmergePullRequest\s*\(", query)
            if not is_review and not is_merge:
                return None
            values = variables.get("input") or {}
            action = "approve" if is_review else "merge"
            node = values.get("pullRequestId")
            number = 9671 if is_review else 9672
            expected_node = PULLS[number][0]
            head = rows[number]["headRefOid"]
            wire_head = values.get("commitOID") if is_review else values.get("expectedHeadOid")
            body = values.get("body")
            method = values.get("mergeMethod")
            eligible = bool(is_review) != bool(is_merge) and node == expected_node
            if is_review:
                eligible = eligible and values.get("event") == "APPROVE" and APPROVAL.fullmatch(body or "") is not None
                eligible = eligible and wire_head in (None, head)
            else:
                eligible = eligible and head_advanced and method == "SQUASH" and wire_head == head
            eligible = bool(eligible and not any(x["node"] == expected_node and x["accepted"] for x in attempts))
            row = {"action": action, "node": node or "", "head": head, "requestHead": wire_head,
                   "body": body if isinstance(body, str) else None, "method": method, "accepted": eligible, "client": client}
            with ledger.open("a") as stream:
                stream.write(json.dumps(row) + "\n")
            if not eligible:
                return HTTPStatus.UNPROCESSABLE_ENTITY, {"errors": [{"message": "Private fixture rejected this pull mutation."}]}
            mutation = "addPullRequestReview" if is_review else "mergePullRequest"
            return HTTPStatus.OK, {"data": {mutation: {"clientMutationId": None}}}

        types = re.findall(r'(\w+)\s*:\s*__type\(name:\s*"(\w+)"\)', query)
        if types and not variables and all(name in {"PullRequest", "WorkflowRun", "StatusCheckRollupContextConnection"} for _, name in types):
            fields = {alias: {"fields": []} for alias, _ in types}
            return HTTPStatus.OK, {"data": fields}

        aliases = re.findall(r"(s\d+)\s*:\s*search\s*\(", query)
        if aliases and any("is:pr" in str(v) for v in variables.values()):
            for alias in aliases:
                terms = str(variables.get("q" + alias[1:], "")).split()
                nodes = list(rows.values()) if "is:pr" in terms else [issue()]
                if "is:open" in terms:
                    nodes = [row for row in nodes if row["state"] == "OPEN"]
                data[alias] = {"nodes": nodes, "issueCount": len(nodes), "pageInfo": {"hasNextPage": False}}
            return HTTPStatus.OK, {"data": data}
        node = variables.get("id")
        if "node(" in query and node in {p[0] for p in PULLS.values()}:
            target = next(row for row in rows.values() if row["id"] == node)
            data["node"] = target
            if "headRefOid" in query:
                read = {"node": node, "head": target["headRefOid"], "state": target["state"], "client": client,
                        "mutations": sum(a["node"] == node and a["accepted"] for a in attempts)}
                with (ledger.parent / "pull-reads.jsonl").open("a") as stream:
                    stream.write(json.dumps(read) + "\n")
            return HTTPStatus.OK, {"data": data}
        # gh resolves a numbered URL in this exact repository before using its node.
        if (re.search(r"\bpullRequest\s*\(", query) and "lab" in variables.values()
                and "write-fixture" in variables.values()):
            number = next((n for n in PULLS if n in variables.values()), None)
            if number:
                row = rows[number]
                data["repository"] = {**row["repository"], "pullRequest": row}
                return HTTPStatus.OK, {"data": data}
        return None


def wrap_handler(original, root, issue):
    """Keep the issue routes and synthetic token from the existing listener."""
    ledger = root / "pull-attempts.jsonl"
    ledger.touch(exist_ok=True, mode=0o600)
    (root / "pull-reads.jsonl").touch(exist_ok=True, mode=0o600)
    (root / "pull-fixture-version").write_text("heeler-private-pulls-v1\n")

    class PrivatePullHandler(original):
        def do_POST(self):
            client = self.headers.get("User-Agent", "")
            authorized = self.headers.get("Authorization", "").split()
            if (self.client_address[0] != "127.0.0.1" or self.path != "/api/graphql"
                    or self.headers.get("Host", "").split(":")[0] != HOST or not client.startswith("GitHub CLI")
                    or len(authorized) != 2 or authorized[0].lower() not in ("bearer", "token")
                    or authorized[1] != TOKEN):
                return super().do_POST()
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 131072:
                return self.send_error(HTTPStatus.BAD_REQUEST)
            body = self.rfile.read(size)
            try:
                request = json.loads(body)
                reply = dispatch(request["query"], request.get("variables") or {}, client, ledger, issue)
            except (KeyError, TypeError, ValueError):
                return self.send_error(HTTPStatus.BAD_REQUEST)
            if reply is None:
                original_stream = self.rfile
                try:
                    self.rfile = io.BytesIO(body)
                    return super().do_POST()
                finally:
                    self.rfile = original_stream
            status, payload = reply
            encoded = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    return PrivatePullHandler


def serve(base):
    """Start this fixture in its operator terminal, on the private issue transport."""
    import hashlib
    import os
    import signal
    import ssl
    import subprocess
    import sys
    import time
    from http.server import ThreadingHTTPServer
    from pathlib import Path

    base = base.resolve()
    directory = base.parent
    mac = re.fullmatch(r"/private/tmp/heeler-lab-mac-github-write\.[A-Za-z0-9_-]{6,16}/service", str(directory))
    linux = directory == Path("/home/heelerlab/heeler-lab-gh-write")
    if (not (mac or linux) or directory.stat().st_uid != os.getuid() or not sys.stdin.isatty()
            or os.tcgetpgrp(sys.stdin.fileno()) != os.getpgrp()):
        raise ValueError("Run in the private issue fixture's foreground terminal.")
    raw = base.read_bytes()
    expected = ("526c78d50b63057d79b470b6d4b5eb3be78ffce9f4541787a5827a2e93104fce" if mac else
                "7f4adfbd5cc1581b8f20b02fccc0aff5a8f25e215e80c81a16059d81e1e46efa")
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("The base script differs from the inspected loopback issue fixture.")
    definitions, delimiter, _listener = raw.partition(b"srv=ThreadingHTTPServer(")
    if not delimiter:
        raise ValueError("Missing private issue server definition.")
    scope = {"__name__": "private_issue_base", "__file__": str(base)}
    exec(compile(definitions, str(base), "exec"), scope)
    handler = wrap_handler(scope["Handler"], directory, lambda: scope["item"](len(scope["snapshot"]())))
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(directory / "ca.pem", directory / "key.pem")
    link = directory / "listen"
    old_port = link.read_text().strip() if mac else None
    pid_file = directory / "server.pid"
    stopped_original = False
    server = None

    def replace_text(target, value):
        tmp = target.with_name(".private-pulls-" + str(os.getpid()))
        with tmp.open("x") as stream:
            stream.write(value + "\n")
        tmp.replace(target)

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    try:
        if linux:
            # Match the recorded same-user Python process, cwd and exact source.
            pid = int(pid_file.read_text())
            proc = Path("/proc") / str(pid)
            cwd = (proc / "cwd").resolve(strict=True)
            argv = (proc / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
            scripts = [(cwd / os.fsdecode(a)).resolve() for a in argv[1:] if a.endswith(b".py")]
            if proc.stat().st_uid != os.getuid() or not (proc / "exe").resolve().name.startswith("python") or scripts != [base]:
                raise ValueError("The recorded process does not own this exact private issue fixture.")
            os.kill(pid, signal.SIGTERM)
            stopped_original = True
            for _ in range(50):
                if not (proc / "cmdline").exists() or not (proc / "cmdline").read_bytes():
                    break
                time.sleep(.1)
        server = ThreadingHTTPServer(("127.0.0.1", 0) if mac else ("127.0.0.2", 443), handler)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        if mac:
            replace_text(link, str(server.server_port))
        print("Private pull fixture ready on loopback. Leave this terminal open for the selected XCTest.", flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if server:
            server.server_close()
        if mac and server and link.read_text().strip() == str(server.server_port):
            replace_text(link, old_port)
        if stopped_original:
            # The restored endpoint is the existing fixture service, not an XCTest.
            with (directory / "private-pull-restore.log").open("ab") as log:
                restored = subprocess.Popen([sys.executable, str(base)], cwd=directory, stdin=subprocess.DEVNULL,
                                            stdout=log, stderr=log, start_new_session=True)
            replace_text(pid_file, str(restored.pid))


if __name__ == "__main__":
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("private_issue_server", type=Path)
    serve(parser.parse_args().private_issue_server)
