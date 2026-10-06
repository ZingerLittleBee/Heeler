#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Testing

    @testable import Heeler

    /// The demo's invented conversations, found and read by Chat's own
    /// locators and adapters.
    @Suite("Demo Chat samples", .timeLimit(.minutes(1)))
    struct DemoChatSampleTests {
        private static let agents = DemoScreenshotFixture.profiles.values.flatMap(\.snapshot.agents)

        @Test func onlyTheAgentsChatReadsReportASession() {
            var bound: [String] = []
            for agent in Self.agents {
                let resolution = ConversationReference.resolve(agent.agentSession)
                guard let program = AgentChatAvailability.program(for: Agent(agent), platform: .posix) else {
                    #expect(resolution == .noSession, "\(agent.paneID) reports a session Chat never reads")
                    continue
                }
                guard case .bound(let reference) = resolution else {
                    Issue.record("\(agent.paneID) reports no session Chat can read: \(resolution)")
                    continue
                }
                #expect(reference.program == program)
                bound.append(agent.paneID)
            }
            #expect(bound.sorted() == ["checkout:p3", "docs:p2", "mobile:p1"])
        }

        @Test(arguments: ["mobile:p1", "docs:p2", "checkout:p3"])
        func eachSampleOpensWholeAndClean(paneID: String) async throws {
            let snapshot = try await Self.open(paneID)

            guard case .following(let path) = snapshot.phase else {
                Issue.record("\(paneID) did not open: \(snapshot.phase)")
                return
            }
            #expect(DemoChatSample.files[path] != nil)
            #expect(snapshot.older == .reachedStart)
            #expect(snapshot.transcript.diagnostics == ChatTranscriptDiagnostics())
        }

        @Test func theSamplesShowEveryKindOfRowAScreenshotNeeds() async throws {
            let docs = try await Self.open("docs:p2").transcript.entries
            let checkout = try await Self.open("checkout:p3").transcript.entries
            let attach = try await Self.open("mobile:p1").transcript.entries

            for entries in [docs, attach] {
                #expect(Self.kinds(entries).isSuperset(of: ["user", "assistant", "reasoning", "tool", "compaction"]))
            }
            #expect(docs.contains { if case .user(let user) = $0.content { user.imageCount == 1 } else { false } })
            #expect(attach.contains { if case .tool(let tool) = $0.content { tool.diff != nil } else { false } })
            #expect(attach.contains { if case .tool(let tool) = $0.content { tool.status == .failed } else { false } })
            guard case .tool(let pending) = checkout.last?.content else {
                Issue.record("The blocked sample should end on its pending call")
                return
            }
            #expect(pending.status == .awaitingApproval)
            #expect(pending.kind == .command)
        }

        @Test func samplesUseInventedNamesOnly() async throws {
            let forbidden = [
                "heeler", "herdr", "github", "anthropic", "openai", "stripe",
                "microsoft", "google", "apple", "voiceover", "claude", "codex",
                "gemini", "opencode",
            ]
            for paneID in ["mobile:p1", "docs:p2", "checkout:p3"] {
                for text in try await Self.open(paneID).transcript.entries.flatMap(Self.texts) {
                    let folded = text.lowercased()
                    for name in forbidden {
                        #expect(!folded.contains(name), "\(paneID) shows \(name): \(text)")
                    }
                }
            }
        }

        @MainActor
        @Test func theConsoleReadsEachSampleThroughTheDemoTransport() async throws {
            let composition = DemoScreenshotComposition.make()
            let console = composition.console
            console.setHosts(composition.hosts.hosts)
            await console.resume()
            defer { console.setHosts([]) }
            try await Self.waitUntil("the demo Hosts connect") {
                console.agents.count == 5 && console.hostPlatforms.count == 2
            }

            for paneID in ["mobile:p1", "docs:p2", "checkout:p3"] {
                let agent = try #require(console.agents.first { $0.agent.paneID == paneID })
                let program = try #require(
                    AgentChatAvailability.program(for: agent.agent, platform: console.hostPlatforms[agent.hostID]))
                let store = try #require(console.chatStore(for: agent, program: program))
                store.show()
                try await Self.waitUntil("\(paneID) shows its conversation") {
                    !store.conversation.transcript.entries.isEmpty
                }
                store.hide()
                #expect(store.conversation.readFailure == nil)
            }
        }

        // MARK: Helpers

        private static func open(_ paneID: String) async throws -> ChatConversationSnapshot {
            let agent = try #require(agents.first { $0.paneID == paneID })
            guard case .bound(let reference) = ConversationReference.resolve(agent.agentSession) else {
                throw SampleMissing(paneID: paneID)
            }
            let adapter = try #require(ChatTranscriptAdapter.standard(for: reference.program))
            let engine = ChatConversationEngine(
                reference: reference,
                cacheKey: ChatCacheKey(
                    hostID: UUID(), herdrSession: "", program: reference.program,
                    conversationID: reference.sessionID),
                files: DemoChatSample.hostFiles, cache: VolatileChatTranscriptCache(), adapter: adapter)
            return await engine.open(
                directories: [agent.cwd].compactMap(\.self),
                context: ChatProjectionContext(activity: ChatAgentActivity(agent.agentStatus)))
        }

        private struct SampleMissing: Error {
            let paneID: String
        }

        private static func kinds(_ entries: [ChatEntry]) -> Set<String> {
            Set(
                entries.map { entry in
                    switch entry.content {
                    case .user: "user"
                    case .assistant: "assistant"
                    case .reasoning: "reasoning"
                    case .tool: "tool"
                    case .plan: "plan"
                    case .questions: "questions"
                    case .notice: "notice"
                    case .divider(let divider): divider.kind == .compaction ? "compaction" : "divider"
                    }
                })
        }

        /// Everything an entry puts on screen.
        private static func texts(_ entry: ChatEntry) -> [String] {
            switch entry.content {
            case .user(let user): [user.displayText] + user.attachmentLabels
            case .assistant(let assistant): [assistant.text]
            case .reasoning(let reasoning): [reasoning.text]
            case .tool(let tool):
                [tool.title, tool.subtitle, tool.note, tool.preview?.text].compactMap(\.self)
                    + tool.questions.flatMap(questionTexts)
            case .plan(let plan): [plan.text, plan.note].compactMap(\.self)
            case .questions(let set): set.questions.flatMap(questionTexts)
            case .notice(let notice): [notice.title, notice.detail].compactMap(\.self)
            case .divider(let divider): [divider.detail].compactMap(\.self)
            }
        }

        private static func questionTexts(_ question: ChatQuestion) -> [String] {
            [question.header, question.text, question.answer].compactMap(\.self) + question.options
        }

        @MainActor
        private static func waitUntil(
            _ comment: Comment,
            timeout: Duration = .seconds(10),
            condition: () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(condition(), comment)
        }
    }
#endif
