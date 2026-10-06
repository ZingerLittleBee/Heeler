#if DEBUG && targetEnvironment(simulator)
    import Foundation

    /// Invented Chat conversations for screenshot mode (ADR 0020), one for
    /// each demo Agent whose program Chat reads. Each is written in its
    /// program's own transcript format and served from memory as the Host
    /// files Chat's locators look for, so the production adapters read it.
    /// No Host and no SSH.
    enum DemoChatSample {
        static let home = "/Users/developer"

        private static let docsSession = "5f0c2a8e-3b1d-4c6a-9e27-8d4f1b6a0c35"
        private static let checkoutSession = "c3a9d1f4-7e2b-4a58-b6d0-2f8e5c1a9b47"
        /// A version 7 id created 2026-10-06T09:30:00Z, so the locator's
        /// date search reaches its rollout's directory.
        private static let attachThread = "01a1108c-69c0-7a5e-8d2c-4f6b1e3a9c70"

        /// The session herdr's integration reports for a demo Agent; nil
        /// for the Agents whose program Chat does not read.
        static func session(forPane paneID: String) -> AgentSessionInfo? {
            switch paneID {
            case "mobile:p1":
                AgentSessionInfo(agent: "codex", kind: .id, source: "herdr:codex", value: attachThread)
            case "docs:p2":
                AgentSessionInfo(agent: "claude", kind: .id, source: "herdr:claude", value: docsSession)
            case "checkout:p3":
                AgentSessionInfo(agent: "claude", kind: .id, source: "herdr:claude", value: checkoutSession)
            default:
                nil
            }
        }

        /// The transcripts by absolute Host path.
        static let files: [String: Data] = [
            claudePath(directory: "/workspace/product-docs", session: docsSession): docsConversation(),
            claudePath(directory: "/workspace/storefront", session: checkoutSession): checkoutConversation(),
            home + "/.codex/sessions/2026/10/06/rollout-2026-10-06T09-30-00-\(attachThread).jsonl":
                attachConversation(),
        ]

        /// Chat's Host file operations over `files`.
        static let hostFiles = ChatHostFiles(
            status: { status(atPath: $0) }, list: { list($0) }, read: { read($0) }, home: { home })

        /// Every sample is as old as the demo's day.
        private static let modificationTime: UInt32 = 1_791_320_000

        static func status(atPath path: String) -> RemoteFileStatus? {
            if let data = files[path] {
                return RemoteFileStatus(
                    kind: .regular, size: UInt64(data.count), modificationTime: modificationTime)
            }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            guard files.keys.contains(where: { $0.hasPrefix(prefix) }) else { return nil }
            return RemoteFileStatus(kind: .directory, size: nil, modificationTime: modificationTime)
        }

        /// Lists a directory the way the SFTP transport filters one.
        static func list(_ request: RemoteFileListingRequest) -> RemoteFileListing? {
            guard status(atPath: request.directory)?.kind == .directory else { return nil }
            let prefix = request.directory.hasSuffix("/") ? request.directory : request.directory + "/"
            let names = Set(
                files.keys.compactMap { path -> String? in
                    guard path.hasPrefix(prefix) else { return nil }
                    return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
                })
            let entries = names.sorted().compactMap { name -> RemoteFileEntry? in
                guard let status = status(atPath: prefix + name) else { return nil }
                let entry = RemoteFileEntry(name: name, status: status)
                return matches(entry, request) ? entry : nil
            }
            return RemoteFileListing(
                entries: Array(entries.prefix(request.maximumEntries)),
                truncated: entries.count > request.maximumEntries)
        }

        static func read(_ range: RemoteFileRange) -> RemoteFileSlice {
            guard let data = files[range.path] else { return RemoteFileSlice(data: Data(), length: nil) }
            let start = Int(min(range.offset, UInt64(data.count)))
            let end = min(data.count, start + max(0, range.maxBytes))
            return RemoteFileSlice(data: data.subdata(in: start..<end), length: UInt64(data.count))
        }

        private static func matches(_ entry: RemoteFileEntry, _ request: RemoteFileListingRequest) -> Bool {
            if !request.kinds.isEmpty, !request.kinds.contains(entry.status.kind ?? .other) { return false }
            if let prefix = request.namePrefix, !entry.name.hasPrefix(prefix) { return false }
            if !request.nameSuffixes.isEmpty, !request.nameSuffixes.contains(where: entry.name.hasSuffix) {
                return false
            }
            if let fragment = request.nameContains, !entry.name.contains(fragment) { return false }
            return true
        }

        private static func claudePath(directory: String, session: String) -> String {
            "\(home)/.claude/projects/\(ClaudeProjectKey.key(forDirectory: directory))/\(session).jsonl"
        }

        // MARK: Screens

        /// A demo Agent's screen as `agent.read` returns it with colors, for
        /// Chat's Blocked card; nil where the terminal sample serves.
        static func screen(forPane paneID: String) -> String? {
            paneID == "checkout:p3" ? checkoutApproval : nil
        }

        /// checkout:p3: Claude asking to run the command its transcript ends
        /// on, in Claude Code's colors.
        private static let checkoutApproval: String = {
            let accent = "\u{1B}[38;2;177;185;249m"
            let inactive = "\u{1B}[38;2;153;153;153m"
            let dashes = "\u{1B}[38;2;80;80;80m"
            let bold = "\u{1B}[1m"
            let reset = "\u{1B}[0m"
            let width = 80
            let rule = accent + String(repeating: "─", count: width) + reset
            let dashed = dashes + String(repeating: "╌", count: width) + reset
            return [
                "",
                rule,
                " \(bold)\(accent)Bash command\(reset)",
                " \(inactive)Run the declined card UI test\(reset)",
                dashed,
                " swift test --filter CheckoutUITests/testDeclinedPaymentKeepsTheCart",
                dashed,
                " Do you want to proceed?",
                " \(accent)❯ \(reset)\(inactive)1. \(reset)\(accent)Yes\(reset)",
                "   \(inactive)2. \(reset)Yes, and don't ask again for \(bold)swift test\(reset) commands in "
                    + "\(bold)/workspace/storefront\(reset)",
                "   \(inactive)3. \(reset)No",
                "",
                " \(inactive)Esc to cancel · Tab to amend\(reset)",
            ].joined(separator: "\r\n")
        }()

        // MARK: Conversations

        /// docs:p2, idle: a finished edit, a compaction, then a follow-up
        /// that carried a screenshot.
        private static func docsConversation() -> Data {
            var session = ClaudeSessionWriter(
                sessionID: docsSession, directory: "/workspace/product-docs", start: 1_791_294_000)
            session.prompt(
                "The setup guide still walks through the old manual pairing. Can you update it for the QR code pairing we shipped last week?"
            )
            session.thinking(
                "The guide mentions pairing in more than one place. Find all of them before editing, so the setup page and the troubleshooting page stay consistent."
            )
            session.reply("I'll find every place the guide describes pairing first.")
            session.tool(
                "Grep", ["pattern": "pairing", "path": "docs", "output_mode": "content"],
                result: """
                    docs/setup.md:14:## Pair your phone
                    docs/setup.md:52:If pairing fails, check that both devices share a network.
                    docs/troubleshooting.md:8:### Pairing code expired
                    """)
            session.tool(
                "Read", ["file_path": "/workspace/product-docs/docs/setup.md"],
                result: """
                        14\t## Pair your phone
                        15\t
                        16\t1. Find the host's address in **Settings → Network**.
                        17\t2. Type the address and port into the app.
                        18\t3. Confirm the fingerprint shown on both screens.
                    """)
            session.tool(
                "Edit",
                [
                    "file_path": "/workspace/product-docs/docs/setup.md",
                    "old_string": "1. Find the host's address", "new_string": "1. Open **Settings → Devices**",
                ],
                result: "The file /workspace/product-docs/docs/setup.md has been updated successfully.")
            session.tool(
                "Edit",
                [
                    "file_path": "/workspace/product-docs/docs/troubleshooting.md",
                    "old_string": "### Pairing code expired", "new_string": "### Code expired",
                ],
                result: "The file /workspace/product-docs/docs/troubleshooting.md has been updated successfully.")
            session.tool(
                "Bash", ["command": "npm run docs:check", "description": "Check links and anchors"],
                result: "✓ 42 pages checked\n✓ 0 broken links")
            session.reply(
                """
                I rewrote **Pair your phone** around the QR code and updated the troubleshooting entry to match.

                ## What changed

                The setup page now walks through three steps:

                1. Open **Settings → Devices** on the computer and choose **Show Pairing Code**.
                2. In the app, tap **Add Host** and point the camera at the code.
                3. Check that the fingerprint matches on both screens, then tap **Trust**.

                Manual address entry moved to an *Advanced* note at the end, for hosts without a screen nearby.

                ### Troubleshooting

                - **Code expired** now explains that a code lasts five minutes, and how to show a new one.
                - The firewall entry links to the [network checklist](https://docs.example.com/network-checklist).

                To preview the pages locally:

                ```sh
                npm run docs:dev
                ```

                The link check passes, and nothing else in the guide mentions the old flow.
                """)
            session.turnEnded(seconds: 94)
            session.compaction(
                summary: """
                    The setup guide's pairing section was rewritten for QR code pairing: setup.md lists three steps and keeps manual entry as an Advanced note, and troubleshooting.md explains expired codes and links the network checklist. The docs link check passes.
                    """,
                tokensBefore: 152_000)
            session.prompt("This is the pairing screen on the latest build. Does the guide match it?", imageCount: 1)
            session.thinking("The screenshot labels the button Scan Code, not Add Host. The guide should use the label people see.")
            session.reply("Almost. The screenshot labels the button **Scan Code**, not **Add Host**, so step 2 needs a new label.")
            session.tool(
                "Edit",
                [
                    "file_path": "/workspace/product-docs/docs/setup.md",
                    "old_string": "tap **Add Host**", "new_string": "tap **Scan Code**",
                ],
                result: "The file /workspace/product-docs/docs/setup.md has been updated successfully.")
            session.reply(
                """
                Step 2 now reads:

                > In the app, tap **Scan Code** and point the camera at the code.

                Everything else matches the screenshot.
                """)
            session.turnEnded(seconds: 21)
            return session.data
        }

        /// checkout:p3, blocked: a review that stops on a command waiting for
        /// the user's approval.
        private static func checkoutConversation() -> Data {
            var session = ClaudeSessionWriter(
                sessionID: checkoutSession, directory: "/workspace/storefront", start: 1_791_299_400)
            session.prompt("Review the payment retry change before I commit it. A declined card must never empty the cart.")
            session.reply("I'll read the retry path, then run the checkout tests.")
            session.tool(
                "Read", ["file_path": "/workspace/storefront/Sources/Checkout/PaymentCoordinator.swift"],
                result: """
                        12\tfunc retryPayment() async {
                        13\t    guard let cart = session.cart else { return }
                        14\t    banner = .retrying
                        15\t    await submit(cart, keepingItems: true)
                        16\t}
                    """)
            session.tool(
                "Bash", ["command": "swift test --filter CheckoutFlowTests", "description": "Run the checkout flow tests"],
                result: """
                    Test Suite 'CheckoutFlowTests' passed.
                    \t Executed 18 tests, with 0 failures (0 unexpected) in 4.2 seconds
                    """)
            session.reply(
                """
                The retry keeps the cart. `retryPayment()` submits the same cart with `keepingItems: true`, and the flow tests cover a decline followed by a retry.

                Two small suggestions:

                - Clear the retry banner when the payment sheet closes, so it doesn't flash at the next checkout.
                - Keep the banner state in one place:

                ```swift
                func sheetDidClose() {
                    banner = nil
                }
                ```

                Before you commit, I'd like to run the UI test that covers a declined card.
                """)
            session.tool(
                "Bash",
                [
                    "command": "swift test --filter CheckoutUITests/testDeclinedPaymentKeepsTheCart",
                    "description": "Run the declined card UI test",
                ],
                result: nil)
            return session.data
        }

        /// mobile:p1, working: a finished turn, a compaction, and a turn
        /// still running.
        private static func attachConversation() -> Data {
            var rollout = CodexRolloutWriter(threadID: attachThread, directory: "/workspace/heeler", start: 1_791_279_000)
            rollout.startTurn()
            rollout.prompt(
                "The Attach toolbar feels crowded on small phones. Can you tighten it up without hiding anything people use often?"
            )
            rollout.reasoning(
                "Looking at how the toolbar lays out its controls at compact widths, and which of them people reach for most.",
                seconds: 6)
            rollout.message("I'll look at how the toolbar decides what to show.")
            rollout.command(
                #"rg -n "AttachToolbar" Sources"#,
                parsed: #"{"type":"search","cmd":"rg -n AttachToolbar Sources","query":"AttachToolbar","path":"Sources"}"#,
                output: """
                    Sources/Attach/AttachChrome.swift:18:struct AttachToolbar: View {
                    Sources/Attach/AttachChrome.swift:44:    AttachToolbar(controls: controls)
                    Sources/Attach/AttachView.swift:91:        .toolbar { AttachToolbar.items }
                    """)
            rollout.command(
                "sed -n '18,30p' Sources/Attach/AttachChrome.swift",
                parsed:
                    #"{"type":"read","cmd":"sed -n '18,30p' Sources/Attach/AttachChrome.swift","name":"AttachChrome.swift","path":"Sources/Attach/AttachChrome.swift"}"#,
                output: """
                    struct AttachToolbar: View {
                        let controls: [AttachControl]

                        var body: some View {
                            HStack(spacing: 12) {
                                ForEach(controls) { control in
                                    AttachControlButton(control)
                                }
                            }
                        }
                    }
                    """)
            rollout.message(
                "Every control gets the same width, so five of them leave no room on a narrow screen. I'll keep **Send** and **Keys** in the bar and move the rest into a menu when they don't fit."
            )
            rollout.edit(
                "Sources/Attach/AttachChrome.swift",
                diff: #"""
                    @@ -18,9 +18,15 @@ struct AttachToolbar: View {
                         let controls: [AttachControl]

                         var body: some View {
                    -        HStack(spacing: 12) {
                    -            ForEach(controls) { control in
                    -                AttachControlButton(control)
                    -            }
                    -        }
                    +        ViewThatFits(in: .horizontal) {
                    +            HStack(spacing: 12) {
                    +                ForEach(controls) { AttachControlButton($0) }
                    +            }
                    +            HStack(spacing: 8) {
                    +                ForEach(controls.filter(\.isPinned)) { AttachControlButton($0) }
                    +                Menu("More", systemImage: "ellipsis.circle") {
                    +                    ForEach(controls.filter { !$0.isPinned }) { AttachControlButton($0) }
                    +                }
                    +            }
                    +        }
                         }
                    """#)
            rollout.command(
                "swift test --filter AttachViewTests",
                parsed: #"{"type":"unknown","cmd":"swift test --filter AttachViewTests"}"#,
                output: """
                    Test Suite 'AttachViewTests' passed.
                    \t Executed 24 tests, with 0 failures (0 unexpected) in 1.8 seconds
                    """,
                seconds: 9)
            let answer = """
                The toolbar now fits on the smallest phones.

                - **Send** and **Keys** stay in the bar at every width.
                - **Paste**, **Snippets** and **Clear** move into a **More** menu when the bar runs out of room.
                - Wider screens keep every control in the bar, as before.

                `AttachViewTests` passes (24 tests).
                """
            rollout.message(answer, isFinal: true)
            rollout.endTurn(lastMessage: answer)

            rollout.startTurn()
            rollout.compaction()
            rollout.endTurn(lastMessage: nil)

            rollout.startTurn()
            rollout.prompt("Now check the toolbar at the largest text size.")
            rollout.reasoning(
                "Larger text widens every label, so the menu layout should take over sooner. The snapshot tests cover the accessibility sizes.",
                seconds: 4)
            rollout.command(
                "swift test --filter AttachToolbarSnapshotTests",
                parsed: #"{"type":"unknown","cmd":"swift test --filter AttachToolbarSnapshotTests"}"#,
                output: """
                    AttachToolbarSnapshotTests.testLargestTextSize(): the More button's label wraps onto two lines.
                    \t Executed 6 tests, with 1 failure (0 unexpected) in 3.1 seconds
                    """,
                exitCode: 1, seconds: 12)
            rollout.message(
                "At the largest size the **More** label wraps. I'm switching it to an icon in that layout and running the snapshots again."
            )
            return rollout.data
        }
    }

    /// Writes a Claude Code session file: records chained by `parentUuid`
    /// in the shapes Claude Code 2.1 writes, a few seconds apart.
    private struct ClaudeSessionWriter {
        let sessionID: String
        let directory: String
        private var time: TimeInterval
        private var parent: String?
        private var records = 0
        /// The API response the next assistant block belongs to. A user
        /// record ends it: Claude Code writes each block of one response as
        /// its own record under one message id.
        private var response: String?
        private var responses = 0
        private var tools = 0
        private var lines: [String] = []

        init(sessionID: String, directory: String, start: TimeInterval) {
            self.sessionID = sessionID
            self.directory = directory
            time = start
        }

        var data: Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

        mutating func prompt(_ text: String, imageCount: Int = 0) {
            let content =
                imageCount == 0
                ? sampleJSON(text)
                : "["
                    + Array(
                        repeating: #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":""}}"#,
                        count: imageCount
                    ).joined(separator: ",")
                    + #",{"type":"text","text":\#(sampleJSON(text))}]"#
            user(#""message":{"role":"user","content":\#(content)},"origin":{"kind":"human"},"promptSource":"typed""#)
            advance(4)
        }

        mutating func thinking(_ text: String) {
            assistant(#"{"type":"thinking","thinking":\#(sampleJSON(text)),"signature":"demo"}"#)
            advance(3)
        }

        mutating func reply(_ markdown: String) {
            assistant(#"{"type":"text","text":\#(sampleJSON(markdown))}"#)
            advance(2)
        }

        /// A tool call, and its result unless the call is still waiting.
        mutating func tool(_ name: String, _ input: KeyValuePairs<String, String>, result: String?) {
            tools += 1
            let id = "toolu_demo_\(sessionID.prefix(8))_\(tools)"
            let fields = input.map { #"\#(sampleJSON($0.key)):\#(sampleJSON($0.value))"# }.joined(separator: ",")
            assistant(#"{"type":"tool_use","id":"\#(id)","name":\#(sampleJSON(name)),"input":{\#(fields)}}"#)
            guard let result else { return }
            advance(2)
            let call = parent ?? ""
            let details =
                name == "Bash"
                ? #","toolUseResult":{"stdout":\#(sampleJSON(result)),"stderr":"","interrupted":false,"isImage":false}"#
                : ""
            user(
                #""message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":\#(sampleJSON(result)),"is_error":false}]}\#(details),"sourceToolAssistantUUID":"\#(call)""#
            )
            advance(1)
        }

        /// An automatic compaction: the boundary restarts the chain, linked
        /// to the branch it compacted, and the summary hangs off it.
        mutating func compaction(summary: String, tokensBefore: Int) {
            let compacted = parent.map { "\"\($0)\"" } ?? "null"
            parent = nil
            record(
                #""type":"system","subtype":"compact_boundary","content":"Conversation compacted","isMeta":false,"logicalParentUuid":\#(compacted),"compactMetadata":{"trigger":"auto","preTokens":\#(tokensBefore)}"#
            )
            advance(1)
            user(
                #""message":{"role":"user","content":\#(sampleJSON(summary))},"isCompactSummary":true,"isVisibleInTranscriptOnly":true"#
            )
            advance(5)
        }

        mutating func turnEnded(seconds: Int) {
            record(#""type":"system","subtype":"turn_duration","durationMs":\#(seconds * 1_000),"isMeta":false"#)
            advance(30)
        }

        private mutating func user(_ fields: String) {
            response = nil
            record(#""type":"user",\#(fields)"#)
        }

        private mutating func assistant(_ block: String) {
            if response == nil {
                responses += 1
                response = "msg_demo_\(sessionID.prefix(8))_\(responses)"
            }
            record(
                #""type":"assistant","message":{"id":"\#(response ?? "")","type":"message","role":"assistant","content":[\#(block)]}"#
            )
        }

        /// One record on the chain, under the previous one.
        private mutating func record(_ fields: String) {
            records += 1
            let uuid = String(sessionID.prefix(24)) + String(format: "%012lx", records)
            let parentField = parent.map { "\"\($0)\"" } ?? "null"
            lines.append(
                #"{"parentUuid":\#(parentField),"isSidechain":false,\#(fields),"uuid":"\#(uuid)","timestamp":"\#(sampleTimestamp(time))","cwd":\#(sampleJSON(directory)),"sessionId":"\#(sessionID)"}"#
            )
            parent = uuid
        }

        private mutating func advance(_ seconds: TimeInterval) {
            time += seconds
        }
    }

    /// Writes a Codex rollout in the paginated history mode Codex 0.160
    /// writes: numbered envelopes whose turn items Chat shows.
    private struct CodexRolloutWriter {
        let threadID: String
        let directory: String
        private var time: TimeInterval
        private var ordinal = 0
        private var turn = ""
        private var turns = 0
        private var items = 0
        private var lines: [String] = []

        init(threadID: String, directory: String, start: TimeInterval) {
            self.threadID = threadID
            self.directory = directory
            time = start
            append(
                "session_meta",
                #"{"id":"\#(threadID)","session_id":"\#(threadID)","cwd":\#(sampleJSON(directory)),"cli_version":"0.160.1","source":"cli","timestamp":"\#(sampleTimestamp(start))","thread_source":"user","history_mode":"paginated"}"#
            )
        }

        var data: Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

        mutating func startTurn() {
            turns += 1
            turn = String(threadID.prefix(24)) + String(format: "%012lx", turns)
            append(
                "event_msg",
                #"{"type":"task_started","turn_id":"\#(turn)","started_at":\#(Int(time)),"model_context_window":258400,"collaboration_mode_kind":"default"}"#
            )
            time += 1
        }

        mutating func endTurn(lastMessage: String?) {
            let last = lastMessage.map(sampleJSON) ?? "null"
            append(
                "event_msg",
                #"{"type":"task_complete","turn_id":"\#(turn)","last_agent_message":\#(last),"completed_at":\#(Int(time))}"#
            )
            time += 40
        }

        mutating func prompt(_ text: String) {
            item(#"{"type":"UserMessage","id":"\#(nextID())","content":[{"type":"text","text":\#(sampleJSON(text)),"text_elements":[]}]}"#)
        }

        mutating func reasoning(_ summary: String, seconds: TimeInterval) {
            item(#"{"type":"Reasoning","id":"rs_\#(nextID())","summary_text":[\#(sampleJSON(summary))]}"#, seconds: seconds)
        }

        mutating func message(_ text: String, isFinal: Bool = false) {
            let phase = isFinal ? "final_answer" : "commentary"
            item(
                #"{"type":"AgentMessage","id":"msg_\#(nextID())","content":[{"type":"Text","text":\#(sampleJSON(text))}],"phase":"\#(phase)"}"#,
                seconds: 2)
        }

        mutating func command(
            _ script: String, parsed: String, output: String, exitCode: Int = 0, seconds: TimeInterval = 1
        ) {
            item(
                #"{"type":"CommandExecution","id":"exec-\#(nextID())","command":["/bin/zsh","-lc",\#(sampleJSON(script))],"cwd":\#(sampleJSON("file://" + directory)),"parsed_cmd":[\#(parsed)],"source":"unified_exec_startup","status":"completed","aggregated_output":\#(sampleJSON(output)),"exit_code":\#(exitCode)}"#,
                seconds: seconds)
        }

        mutating func edit(_ path: String, diff: String) {
            let file = sampleJSON(directory + "/" + path)
            item(
                #"{"type":"FileChange","id":"exec-\#(nextID())","changes":{\#(file):{"type":"update","unified_diff":\#(sampleJSON(diff))}},"status":"completed","stdout":"","stderr":""}"#
            )
        }

        mutating func compaction() {
            item(#"{"type":"ContextCompaction","id":"\#(nextID())"}"#, seconds: 8)
        }

        private mutating func item(_ item: String, seconds: TimeInterval = 1) {
            let start = Int(time * 1_000)
            time += seconds
            append(
                "event_msg",
                #"{"type":"item_completed","thread_id":"\#(threadID)","turn_id":"\#(turn)","item":\#(item),"started_at_ms":\#(start),"completed_at_ms":\#(Int(time * 1_000))}"#
            )
        }

        private mutating func nextID() -> String {
            items += 1
            return String(threadID.prefix(24)) + String(format: "%012lx", 0x1000 + items)
        }

        private mutating func append(_ type: String, _ payload: String) {
            lines.append(
                #"{"timestamp":"\#(sampleTimestamp(time))","ordinal":\#(ordinal),"type":"\#(type)","payload":\#(payload)}"#)
            ordinal += 1
        }
    }

    /// A JSON string literal.
    private func sampleJSON(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case let control where control.value < 0x20: quoted += String(format: "\\u%04x", control.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    private func sampleTimestamp(_ time: TimeInterval) -> String {
        Date(timeIntervalSince1970: time).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
#endif
