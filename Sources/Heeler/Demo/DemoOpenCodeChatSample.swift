#if DEBUG && targetEnvironment(simulator)
    import Foundation

    /// An invented OpenCode conversation for api:p7, never copied from a
    /// user's database. OpenCode keeps conversations in its own database,
    /// which Chat reads by query rather than as a file (ADR 0025), so the
    /// sample is the lines that query prints, and the demo transport answers
    /// each query with them in process. The production record source and
    /// reducer read them. No Host and no SSH.
    enum DemoOpenCodeChatSample {
        static let sessionID = "ses_6c1e8f3a9d24Kp7Wq2Zr5Xn8Tb"
        /// What herdr's OpenCode integration reports for api:p7.
        static let session = AgentSessionInfo(
            agent: "opencode", kind: .id, source: "herdr:opencode", value: sessionID)

        /// What OpenCode's database answers `query`. The sample never
        /// changes, so every poll finds the event counter where the first
        /// read left it. Any other session is missing.
        static func response(_ query: OpenCodeQuery) -> OpenCodeQueryResponse {
            guard query.session.rawValue == sessionID else { return .sessionMissing(otherStores: []) }
            switch query.kind {
            case .tail:
                return records(conversation.rows)
            case .poll:
                return .unchanged(eventSeq: conversation.eventSeq)
            case .older(let before, _):
                return records(conversation.rows.filter { $0.seq < before })
            case .row(let seq, _):
                return records(conversation.rows.filter { $0.seq == seq })
            }
        }

        private static func records(_ rows: [OpenCodeRowLine]) -> OpenCodeQueryResponse {
            .records(
                OpenCodeRecords(
                    sqliteVersion: "3.51.0", eventSeq: conversation.eventSeq,
                    sessionLine: conversation.sessionLine, inboxLine: Data(#"{"k":"inbox","items":[],"more":0}"#.utf8),
                    rows: rows, firstSeq: conversation.rows.first?.seq, windowCount: nil, overflow: false,
                    ignoredLines: 0))
        }

        // MARK: Conversation

        private struct Conversation {
            var rows: [OpenCodeRowLine]
            var sessionLine: Data
            /// The counter stands at the newest row.
            var eventSeq: Int64
        }

        private static let conversation = makeConversation()
        private static let directory = "/workspace/payments-api"
        private static let worker = "src/webhooks/deliver.ts"

        /// api:p7, working: a finished turn, a `/compact`, and a turn that
        /// is running the retry matrix again.
        private static func makeConversation() -> Conversation {
            var rows = OpenCodeRowWriter(start: 1_791_291_600)
            rows.prompt(
                "Webhook deliveries give up after the first timeout. Add retries with backoff, and make sure a receiver never applies the same event twice."
            )
            rows.step([
                .reasoning(
                    "A retry is only safe if the receiver can tell a repeat from a new event. Check whether each delivery carries a stable event id before changing how it's sent.",
                    seconds: 5),
                .text("I'll read the delivery worker first, then find everything that sends a webhook."),
                .tool(
                    "read", input: ["path": "\(directory)/\(worker)"],
                    output: """
                        Read file \(directory)/\(worker), lines 1-8
                        1: export async function deliver(event: WebhookEvent, endpoint: Endpoint) {
                        2:   const response = await post(endpoint.url, event.body, {
                        3:     timeout: 5_000,
                        4:   })
                        5:   if (!response.ok) {
                        6:     await markFailed(event, response.status)
                        7:   }
                        8: }
                        """),
                .tool(
                    "grep", input: ["pattern": "await deliver"],
                    output: """
                        Found 2 matches
                        \(directory)/src/webhooks/queue.ts:
                          Line 22:     await deliver(event, endpoint)

                        \(directory)/src/webhooks/replay.ts:
                          Line 9:   await deliver(event, endpoint)
                        """),
            ])
            rows.step([
                .text(
                    "Each delivery is sent once and marked failed on any error. I'll retry timeouts and 5xx answers with exponential backoff, and send the event id as an `Idempotency-Key` header so a receiver can drop repeats."
                ),
                patch(
                    at: 1,
                    [
                        " export async function deliver(event: WebhookEvent, endpoint: Endpoint) {",
                        "-  const response = await post(endpoint.url, event.body, {",
                        "-    timeout: 5_000,",
                        "-  })",
                        "-  if (!response.ok) {",
                        "-    await markFailed(event, response.status)",
                        "-  }",
                        "+  for (let attempt = 1; ; attempt++) {",
                        "+    const response = await post(endpoint.url, event.body, {",
                        "+      timeout: 5_000,",
                        "+      headers: { \"Idempotency-Key\": event.id },",
                        "+    })",
                        "+    if (response.ok) return",
                        "+    if (!isRetryable(response) || attempt === MAX_ATTEMPTS) {",
                        "+      await markFailed(event, response.status)",
                        "+      return",
                        "+    }",
                        "+    await sleep(backoff(attempt))",
                        "+  }",
                        " }",
                    ]),
            ])
            rows.step([
                .tool(
                    "shell", input: ["command": "npm test -- webhooks"],
                    output: """
                         ✓ src/webhooks/deliver.test.ts (9 tests) 412ms

                         Test Files  1 passed (1)
                              Tests  9 passed (9)
                        """,
                    metadata: ["exit": 0])
            ])
            rows.step(
                [
                    .text(
                        """
                        Deliveries now retry instead of giving up.

                        - Timeouts and 5xx answers retry up to 5 times, with exponential backoff.
                        - Other 4xx answers still fail at once.
                        - Every attempt sends the event id as `Idempotency-Key`, so a receiver can drop repeats.

                        The webhook tests pass (9 tests).
                        """)
                ], finish: "stop")
            rows.idle()

            rows.compaction(
                summary: """
                    ## Objective
                    - Make webhook deliveries retry safely.

                    ## Work State
                    - `deliver()` retries timeouts and 5xx answers with exponential backoff, up to 5 attempts.
                    - Every attempt sends `Idempotency-Key`, and the webhook tests pass.

                    ## Next Move
                    - Run the full retry matrix against the sandbox receiver.
                    """)
            rows.idle()

            // The running turn, stamped against the live clock so its
            // header reads seconds, not days.
            rows.resume(at: Date().timeIntervalSince1970 - 80)
            rows.prompt("Run the full retry matrix against the sandbox receiver.")
            rows.step([
                .reasoning(
                    "The matrix replays each failure mode: timeouts, dropped connections, 5xx and 429 answers. A case that still fails points at a gap in the retry rules.",
                    seconds: 4),
                .tool(
                    "shell", input: ["command": "npm run test:retry-matrix"],
                    output: """
                        retry matrix: 12 of 16 cases passing
                          ✗ 429 with Retry-After: 30
                          ✗ 429 with an HTTP-date Retry-After
                          ✗ 503 with Retry-After: 120
                          ✗ 503 with an HTTP-date Retry-After
                        """,
                    metadata: ["exit": 1]),
            ])
            rows.step([
                .text(
                    "All four failures answer with `Retry-After`, which the backoff ignores. I'll wait as long as the receiver asks, up to the retry window."
                ),
                patch(
                    at: 9,
                    [
                        "       await markFailed(event, response.status)",
                        "       return",
                        "     }",
                        "-    await sleep(backoff(attempt))",
                        "+    const asked = retryAfter(response)",
                        "+    await sleep(Math.min(asked ?? backoff(attempt), RETRY_WINDOW))",
                        "   }",
                        " }",
                    ]),
            ])
            rows.step([.tool("shell", input: ["command": "npm run test:retry-matrix"], output: nil)], finish: nil)

            let session: [String: Any] = [
                "k": "session", "id": sessionID, "parent": NSNull(), "title": "Harden webhook retries",
                "version": "2.0.32", "revertMessage": NSNull(), "revertFiles": NSNull(), "revertSeq": NSNull(),
                "updated": rows.time,
            ]
            return Conversation(
                rows: rows.rows, sessionLine: OpenCodeRowWriter.line(session), eventSeq: rows.rows.last?.seq ?? 0)
        }

        /// A `patch` call that changed one hunk of the worker, with the
        /// unified patch OpenCode records for it.
        private static func patch(at line: Int, _ hunk: [String]) -> OpenCodeRowWriter.Item {
            let path = "\(directory)/\(worker)"
            let removed = hunk.filter { $0.hasPrefix("-") }.count
            let added = hunk.filter { $0.hasPrefix("+") }.count
            let context = hunk.count - removed - added
            let body = hunk.joined(separator: "\n") + "\n"
            let unified =
                "Index: \(path)\n\(String(repeating: "=", count: 67))\n--- \(path)\n+++ \(path)\n"
                + "@@ -\(line),\(context + removed) +\(line),\(context + added) @@\n\(body)"
            return .tool(
                "patch", input: ["patchText": "*** Begin Patch\n*** Update File: \(path)\n@@\n\(body)*** End Patch"],
                output: "Success. Updated the following files:\nM \(worker)",
                metadata: [
                    "files": [
                        ["file": worker, "status": "modified", "additions": added, "deletions": removed, "patch": unified]
                    ]
                ])
        }
    }

    /// Writes a session's rows as Chat's store query prints them, in the
    /// shapes OpenCode 2.0 stores: one row per prompt, model step,
    /// compaction and idle marker, a few seconds apart.
    private struct OpenCodeRowWriter {
        enum Item {
            case reasoning(String, seconds: Int64)
            case text(String)
            /// A call without output is still running.
            case tool(String, input: [String: Any], output: String?, metadata: [String: Any] = [:])
        }

        private(set) var rows: [OpenCodeRowLine] = []
        /// Milliseconds since 1970.
        private(set) var time: Int64
        private var calls = 0

        init(start: TimeInterval) {
            time = Int64(start * 1_000)
        }

        /// Moves the clock on to `time`, never back.
        mutating func resume(at time: TimeInterval) {
            self.time = max(self.time, Int64(time * 1_000))
        }

        mutating func prompt(_ text: String) {
            add("user", ["text": text, "files": [String](), "agents": [String](), "time": ["created": time]])
            advance(2)
        }

        /// One model step and its items, each stamped as the step runs. A
        /// step without `finish` is still running.
        mutating func step(_ items: [Item], finish: String? = "tool-calls") {
            let created = time
            var content: [[String: Any]] = []
            for (index, item) in items.enumerated() {
                var fields: [String: Any]
                switch item {
                case .reasoning(let text, let seconds):
                    fields = ["type": "reasoning", "text": text, "time": ["created": time, "completed": time + seconds * 1_000]]
                    advance(seconds)
                case .text(let text):
                    fields = ["type": "text", "text": text]
                    advance(2)
                case .tool(let name, let input, let output, let metadata):
                    calls += 1
                    fields = [
                        "type": "tool", "id": "call_Dm\(String(format: "%022ld", calls))", "name": name,
                        "status": output == nil ? "running" : "completed", "input": input, "error": NSNull(),
                        "meta": metadata, "out": output ?? NSNull(),
                    ]
                    advance(3)
                }
                fields["_i"] = index
                content.append(fields)
            }
            var data: [String: Any] = ["agent": "build", "content": content, "time": ["created": created]]
            if let finish {
                data["finish"] = finish
                data["time"] = ["created": created, "completed": time]
            }
            add("assistant", data, created: created, isFinal: finish != nil)
            advance(1)
        }

        mutating func idle() {
            add("idle", ["time": ["created": time], "outcome": "succeeded"])
            advance(30)
        }

        /// A `/compact` the user ran, finished.
        mutating func compaction(summary: String) {
            let created = time
            advance(9)
            add(
                "compaction", ["status": "completed", "reason": "manual", "summary": summary, "time": ["created": created]],
                created: created)
            advance(1)
        }

        /// One JSON object on one line.
        static func line(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        private mutating func add(_ type: String, _ data: [String: Any], created: Int64? = nil, isFinal: Bool = true) {
            let seq = Int64(rows.count + 1)
            let id = "msg_6c1e8f3a9d24Dm\(String(format: "%012lld", seq))"
            let row: [String: Any] = [
                "k": "row", "id": id, "type": type, "seq": seq, "tc": created ?? time, "tu": time, "f": isFinal,
                "d": data,
            ]
            rows.append(OpenCodeRowLine(id: id, seq: seq, timeUpdated: time, isFinal: isFinal, line: Self.line(row)))
        }

        private mutating func advance(_ seconds: Int64) {
            time += seconds * 1_000
        }
    }
#endif
