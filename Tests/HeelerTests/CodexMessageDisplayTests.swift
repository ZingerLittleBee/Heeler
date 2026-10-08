import Foundation
import Testing

@testable import Heeler

/// How recorded user messages read in Chat
/// (docs/research/codex-rollout-format.md, "User message display" and
/// "Skill prompts").
@Suite("Codex message display")
struct CodexMessageDisplayTests {
    private let idle = ChatProjectionContext(activity: .idle)

    @Test("Image rows retain the Host path separately from their display title", arguments: [false, true])
    func imageHostPath(legacy: Bool) throws {
        var builder = CodexRolloutBuilder(legacy ? .legacy : .paginated, cwd: "/work")
        builder.turnStarted("t1")
        if legacy {
            builder.legacyCall("view_image", callID: "image-1", arguments: ["path": "/work/screenshots/shot.png"])
            builder.legacyOutput(callID: "image-1", output: "Image displayed")
        } else {
            builder.item("t1", ["type": "ImageView", "id": "image-1", "path": "/work/screenshots/shot.png"])
        }
        let tool = try #require(builder.reducer().transcript(idle).entries.first?.tool)
        #expect(tool.title == "screenshots/shot.png")
        #expect(tool.imagePath == "/work/screenshots/shot.png")
        #expect(tool.kind == .image)
        #expect(tool.status == .succeeded)
        #expect(tool.output != nil)
        if legacy { #expect(tool.preview?.text == "Image displayed") }
    }

    @Test("Image paths resolve from recorded context without guessing", arguments: [false, true])
    func imagePathResolution(legacy: Bool) throws {
        let cases: [(path: String, cwd: String, expected: String?)] = [
            ("screenshots/shot.png", "/work", "/work/screenshots/shot.png"),
            ("./shot.png", "/work", "/work/./shot.png"),
            ("../shot.png", "/work/symlink", "/work/symlink/../shot.png"),
            ("screenshots/shot.png", "", nil),
            ("screenshots/shot.png", "relative", nil),
            ("file:///tmp/my%20shot.png", "/work", "/tmp/my shot.png"),
            ("file://localhost/tmp/shot.png", "/work", "/tmp/shot.png"),
            ("file://another-host/tmp/shot.png", "/work", nil),
            ("file:///tmp/shot.png?download=yes", "/work", nil),
            ("https://example.com/shot.png", "/work", nil),
            ("data:image/png;base64,AAAA", "/work", nil),
            ("~/shot.png", "/work", nil),
            ("", "/work", nil),
        ]
        for sample in cases {
            var builder = CodexRolloutBuilder(legacy ? .legacy : .paginated, cwd: sample.cwd)
            builder.turnStarted("t1")
            if legacy {
                builder.legacyCall("view_image", callID: "image-1", arguments: ["path": .string(sample.path)])
                builder.legacyOutput(callID: "image-1", output: "Image displayed")
            } else {
                builder.item("t1", ["type": "ImageView", "id": "image-1", "path": .string(sample.path)])
            }
            let tool = try #require(builder.reducer().transcript(idle).entries.first?.tool)
            #expect(tool.imagePath == sample.expected, "Recorded path: \(sample.path), cwd: \(sample.cwd)")
        }
    }

    @Test("Generated images retain a recorded saved path", arguments: [false, true])
    func generatedImagePath(legacy: Bool) throws {
        var builder = CodexRolloutBuilder(legacy ? .legacy : .paginated, cwd: "/work")
        builder.turnStarted("t1")
        if legacy {
            builder.legacyCall("image_generation", callID: "image-1", arguments: [:])
            builder.event("image_generation_end", [
                ("call_id", "image-1"), ("saved_path", "generated/shot.png"), ("status", "completed"),
            ])
        } else {
            builder.item("t1", [
                "type": "ImageGeneration", "id": "image-1", "savedPath": "generated/shot.png", "status": "completed",
            ])
        }
        let tools = builder.reducer().transcript(idle).entries.compactMap(\.tool)
        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool.imagePath == "/work/generated/shot.png")
        #expect(tool.status == .succeeded)
        #expect(tool.output != nil)
    }

    @Test func imagesWithoutRecordedPathsRemainTextOnly() throws {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.item("t1", ["type": "ImageView", "id": "image-1"])
        builder.item("t1", ["type": "ImageGeneration", "id": "image-2", "status": "completed"])
        let tools = builder.reducer().transcript(idle).entries.compactMap(\.tool)
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0.imagePath == nil })
    }

    @Test("Subagent events preserve identity without treating every update as success", arguments: [false, true])
    func subagentActivity(legacy: Bool) throws {
        var builder = CodexRolloutBuilder(legacy ? .legacy : .paginated)
        builder.turnStarted("t1")
        let kinds = ["started", "interacted", "completed", "interrupted", "future_event"]
        for (index, kind) in kinds.enumerated() {
            if legacy {
                builder.event("sub_agent_activity", [
                    ("event_id", .string("e\(index)")), ("agent_path", "/root/task"), ("kind", .string(kind)),
                ])
            } else {
                builder.item("t1", [
                    "type": "SubAgentActivity", "id": .string("e\(index)"),
                    "agent_path": "/root/task", "kind": .string(kind),
                ])
            }
        }
        let transcript = builder.reducer().transcript(ChatProjectionContext(activity: .working))
        let tools = transcript.entries.compactMap(\.tool)
        #expect(tools.count == kinds.count)
        #expect(tools.map(\.status) == [.noResult, .noResult, .succeeded, .interrupted, .noResult])
        #expect(tools.map(\.title) == Array(repeating: "Subagent: task", count: kinds.count))
        #expect(tools.compactMap(\.subagentActivity) == kinds.map {
            ChatSubagentActivity(agentPath: "/root/task", events: [$0])
        })
        #expect(tools.allSatisfy { $0.output == nil && $0.preview == nil })
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test func subagentActivityWithoutIdentityOrKindRemainsExplicitlyUnknown() throws {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.item("t1", ["type": "SubAgentActivity", "id": "e1"])
        let tool = try #require(builder.reducer().transcript(idle).entries.first?.tool)
        #expect(tool.title == "Subagent")
        #expect(tool.subagentActivity == ChatSubagentActivity(agentPath: nil, events: ["unknown"]))
        #expect(tool.status == .noResult)
    }

    @Test("A recognized $skill prompt reads as a slash command", arguments: CodexSkillCase.allCases)
    func skillDisplay(_ skill: CodexSkillCase) throws {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: skill.text, extraParts: skill.parts)
        let context = ChatProjectionContext(activity: .idle, skillNames: skill.catalog)

        let user = try #require(builder.reducer().transcript(context).entries.first?.user)
        #expect(user.text == skill.text)
        #expect(user.command == skill.command)
        #expect(user.displayText == skill.display)
    }

    @Test("A legacy prompt reads as a command only through the Host's skills")
    func legacySkill() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.legacyUser("$review-pr 12")
        let reducer = builder.reducer()

        #expect(reducer.transcript(idle).entries.first?.user?.displayText == "$review-pr 12")
        let context = ChatProjectionContext(activity: .idle, skillNames: ["review-pr"])
        #expect(reducer.transcript(context).entries.first?.user?.displayText == "/review-pr 12")
    }

    @Test("An IDE preamble folds into a chip and the request after the last marker shows")
    func idePreamble() {
        let text = """
            # Context from my IDE setup:

            ## Active file: Sources/App.swift

            ## My request for Codex:
            not this

            ## My request for Codex:
            fix the build

            """
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: text)

        let transcript = builder.reducer().transcript(idle)
        #expect(
            transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "fix the build", attachmentLabels: ["IDE context"]))
            ])
        // Echo matching compares the text as Codex recorded it.
        #expect(transcript.recordedPrompts.map(\.text) == [text])
    }

    @Test("An async reply behind an IDE preamble is still an Answered row")
    func ideWrappedReply() {
        let questionID = CodexMessageFormatter.asyncQuestionID(itemID: "call-q", index: 0)
        let reply: CodexJSON = [["questionItemId": .string(questionID), "question": "Pick a fruit", "answer": "Apple"]]
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "ask me")
        builder.agentMessage(
            "t1", id: "call-q", text: "", phase: "commentary", delivery: "async",
            questions: [(title: "Pick a fruit", options: ["Apple", "Banana"])])
        builder.userMessage(
            "t1", id: "u2",
            text: "# Context from my IDE setup:\n\n## Active file: a.swift\n\n## My request for Codex:\n"
                + "<send_user_message_question_reply>\(reply.text)</send_user_message_question_reply>\n")
        builder.turnComplete("t1")

        let transcript = builder.reducer().transcript(idle)
        #expect(
            transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "ask me")),
                .questions(
                    ChatQuestionSet(questions: [
                        ChatQuestion(id: questionID, text: "Pick a fruit", options: ["Apple", "Banana"], answer: "Apple")
                    ])),
                .notice(
                    ChatNotice(
                        kind: .answered, title: "Answered",
                        questions: [ChatQuestion(id: questionID, text: "Pick a fruit", answer: "Apple")])),
            ])
        #expect(transcript.pendingRequests.isEmpty)
        #expect(transcript.recordedPrompts.map(\.text) == ["ask me"])
    }

    @Test("A reply that names only the message settles every question in it")
    func bareItemReply() {
        let reply: CodexJSON = ["questionItemId": "call-q", "question": "Pick a fruit", "answer": "Apple"]
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.agentMessage(
            "t1", id: "call-q", text: "", delivery: "async",
            questions: [(title: "Pick a fruit", options: ["Apple"]), (title: "Pick a drink", options: ["Tea"])])
        builder.userMessage(
            "t1", id: "u1", text: "<send_user_message_question_reply>\(reply.text)</send_user_message_question_reply>")

        let transcript = builder.reducer().transcript(ChatProjectionContext(activity: .working))
        #expect(
            transcript.entries.first?.questionSet
                == ChatQuestionSet(questions: [
                    ChatQuestion(
                        id: CodexMessageFormatter.asyncQuestionID(itemID: "call-q", index: 0), text: "Pick a fruit",
                        options: ["Apple"], answer: "Apple"),
                    ChatQuestion(
                        id: CodexMessageFormatter.asyncQuestionID(itemID: "call-q", index: 1), text: "Pick a drink",
                        options: ["Tea"]),
                ]))
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test("Images count, skills and mentions hide, other parts become chips")
    func attachments() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.item(
            "t1",
            [
                "type": "UserMessage", "id": "u1",
                "content": [
                    ["type": "local_image", "path": "/tmp/shot.png"],
                    ["type": "image", "image_url": "data:image/png;base64,AAAA"],
                    ["type": "text", "text": "compare [Image #1] with ", "text_elements": []],
                    ["type": "text", "text": "this", "text_elements": []],
                    ["type": "skill", "name": "review-pr", "path": "/skills/review-pr/SKILL.md"],
                    ["type": "mention", "name": "repo", "path": "app://repo"],
                    ["type": "local_audio", "path": "/tmp/note.wav"],
                    ["type": "future_part"],
                ],
            ])

        let projection = builder.reducer().projection(idle)
        #expect(
            projection.transcript.entries.map(\.content) == [
                .user(
                    ChatUserMessage(
                        text: "compare [Image #1] with this", imageCount: 2, attachmentLabels: ["Audio", "Attachment"]))
            ])
        #expect(
            projection.echoCandidates.map(\.kind) == [
                .prompt(text: "compare [Image #1] with this", localImagePaths: ["/tmp/shot.png"])
            ])
    }

    @Test("A prompt steered into a running turn is marked queued")
    func steeredPrompt() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "start")
        builder.agentMessage("t1", id: "a1", text: "on it", phase: "commentary")
        builder.userMessage("t1", id: "u2", text: "also this")
        builder.agentMessage("t1", id: "a2", text: "done")
        builder.turnComplete("t1")

        #expect(
            builder.reducer().transcript(idle).entries.compactMap(\.user) == [
                ChatUserMessage(text: "start"), ChatUserMessage(text: "also this", wasQueued: true),
            ])
    }
}

/// `$name` prompts and whether they read as `/name`
/// (docs/research/codex-rollout-format.md, "Skill prompts").
enum CodexSkillCase: CaseIterable, CustomTestStringConvertible {
    case skillPart
    case pluginInCatalog
    case environmentVariable
    case bareName
    case multilineArguments
    case gluedToText

    var testDescription: String {
        switch self {
        case .skillPart: "$review-pr 12 with a skill part"
        case .pluginInCatalog: "$plug:sk x from the Host's skills"
        case .environmentVariable: "$HOME x"
        case .bareName: "$review-pr alone"
        case .multilineArguments: "arguments over two lines"
        case .gluedToText: "$review-pr/x"
        }
    }

    var text: String {
        switch self {
        case .skillPart: "$review-pr 12"
        case .pluginInCatalog: "$plug:sk x"
        case .environmentVariable: "$HOME x"
        case .bareName: "$review-pr"
        case .multilineArguments: "$review-pr 12\nfocus on tests"
        case .gluedToText: "$review-pr/x"
        }
    }

    /// The skill part the TUI records when it recognizes the name. It stops
    /// at `:`, so plugin skills never get one.
    var parts: [CodexJSON] {
        switch self {
        case .pluginInCatalog, .environmentVariable: []
        default: [["type": "skill", "name": "review-pr", "path": "/skills/review-pr/SKILL.md"]]
        }
    }

    var catalog: Set<String> {
        switch self {
        case .pluginInCatalog, .environmentVariable: ["plug:sk", "review-pr"]
        default: []
        }
    }

    var command: ChatCommandInvocation? {
        switch self {
        case .skillPart: ChatCommandInvocation(name: "review-pr", arguments: "12")
        case .pluginInCatalog: ChatCommandInvocation(name: "plug:sk", arguments: "x")
        case .bareName: ChatCommandInvocation(name: "review-pr")
        case .multilineArguments: ChatCommandInvocation(name: "review-pr", arguments: "12\nfocus on tests")
        case .environmentVariable, .gluedToText: nil
        }
    }

    var display: String {
        switch self {
        case .skillPart: "/review-pr 12"
        case .pluginInCatalog: "/plug:sk x"
        case .environmentVariable: "$HOME x"
        case .bareName: "/review-pr"
        case .multilineArguments: "/review-pr 12\nfocus on tests"
        case .gluedToText: "$review-pr/x"
        }
    }
}
