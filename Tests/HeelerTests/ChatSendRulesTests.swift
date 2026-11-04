import Foundation
import Testing

@testable import Heeler

@Suite("Chat send rules")
struct ChatSendRulesTests {
    private static let skills = [
        AgentSkill(scope: .project, name: "review", description: "Review the diff"),
        AgentSkill(scope: .global, name: "compact", description: "A skill named like the command"),
        AgentSkill(scope: .global, name: "deploy", description: nil),
    ]

    /// How each program invokes a skill: Pi and Oh My Pi skills are
    /// `/skill:name`. OpenCode's menu offers none, whatever the prefix.
    private static func skillPrefix(_ program: ChatProgram) -> String {
        switch program {
        case .claude, .opencode: "/"
        case .codex: "$"
        case .pi, .omp: "/skill:"
        case .grok: "/"
        }
    }

    private static func rules(
        _ program: ChatProgram, idle: Bool = true, prefix: String? = nil
    ) -> ChatSendRules {
        let skills = Self.skills.map {
            AgentSkill(
                scope: $0.scope, name: $0.name, description: $0.description,
                commandPrefix: prefix ?? skillPrefix(program))
        }
        return ChatSendRules(
            program: program,
            commands: ChatCommandMenu.commands(skills: skills, agentIsIdle: idle, program: program))
    }

    /// `program`'s rules and menu with a synthetic profile in place of its own.
    private static func rules(_ program: ChatProgram, profile: ChatSendProfile) -> ChatSendRules {
        ChatSendRules(program: program, commands: rules(program).commands, profile: profile)
    }

    // MARK: Not sent

    @Test(arguments: ChatProgram.allCases, ["!ls", "  !rm -rf build", "!"])
    func aShellEscapeIsNeverSent(program: ChatProgram, draft: String) {
        guard case .unsafeText = Self.rules(program).validate(draft) else {
            Issue.record("\(draft) was not refused for \(program)")
            return
        }
    }

    @Test(arguments: ["exit", "quit", ":q", ":q!", ":wq", ":wq!", "  exit\n", "Quit"])
    func claudeExitWordsAreNeverSent(draft: String) {
        guard case .unsafeText = Self.rules(.claude).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: ["exit", ":q"])
    func codexTakesExitWordsAsText(draft: String) {
        #expect(Self.rules(.codex).validate(draft) == nil)
    }

    @Test func claudeExitWordsInsideASentenceAreText() {
        #expect(Self.rules(.claude).validate("please exit the loop") == nil)
    }

    @Test(arguments: ["exit", " QUIT \n", "q", "Exit"])
    func ompRefusesBareExitWords(draft: String) {
        guard case .unsafeText = Self.rules(.omp).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: ["$ ls", "$$ print(1)", "$\tx", "  $ import os\nos.listdir()"])
    func ompRefusesPythonPrefix(draft: String) {
        guard case .unsafeText = Self.rules(.omp).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: [".", " c ", "C", "-> x", "=> after this", "->"])
    func ompRefusesContinueAndQueueShorthand(draft: String) {
        guard case .unsafeText = Self.rules(.omp).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: ["quit smoking", "q?", "$HOME is set", "$5 total", "c'est", "..", "a -> b", "exit the loop"])
    func ompTakesLookalikesAsText(draft: String) {
        #expect(Self.rules(.omp).read(draft) == .text)
    }

    @Test func ompRefusesHundredLinePastes() {
        let rules = Self.rules(.omp)
        let lines = { (count: Int) in (1...count).map { "line \($0)" }.joined(separator: "\n") }

        #expect(rules.validate(lines(99)) == nil)
        #expect(rules.validate(lines(99) + "\n\n  \n") == nil)
        guard case .unsafeText = rules.validate(lines(100)) else {
            Issue.record("a 100-line paste was not refused")
            return
        }
        guard case .unsafeText = rules.validate(lines(100).replacingOccurrences(of: "\n", with: "\r\n")) else {
            Issue.record("a 100-line paste with CRLF breaks was not refused")
            return
        }
    }

    @Test(
        arguments: [
            "exit", "q", "$ ls", "$$ print(1)", ".", "c", "-> x", "=> x",
            (1...150).map { "line \($0)" }.joined(separator: "\n"),
        ])
    func piAcceptsWhatOMPRefuses(draft: String) {
        #expect(Self.rules(.pi).validate(draft) == nil)
    }

    @Test(arguments: ["q", "$ ls", ".", "-> x"])
    func claudeAndCodexTakeOMPShorthandsAsText(draft: String) {
        #expect(Self.rules(.claude).validate(draft) == nil)
        #expect(Self.rules(.codex).validate(draft) == nil)
    }

    @Test func claudeExitWordsUnchanged() {
        #expect(
            Self.rules(.claude).validate(":wq")
                == .unsafeText("Sending this would exit Claude Code. Open the terminal to exit."))
        #expect(Self.rules(.claude).validate("q") == nil)
    }

    @Test func controlBytesAreNeverSent() {
        guard case .unsafeText = Self.rules(.claude).validate("a\u{1B}[201~b") else {
            Issue.record("an escape sequence was not refused")
            return
        }
    }

    /// One draft for each refusal, with the sentence Chat shows for it.
    private static let wordedRefusals: [(ChatProgram, String, ComposerRefusal)] = [
        (.claude, ":wq", .unsafeText("Sending this would exit Claude Code. Open the terminal to exit.")),
        (.omp, " QUIT \n", .unsafeText("Sending this would exit Oh My Pi. Open the terminal to exit.")),
        (.omp, "$ ls", .unsafeText("A message starting with $ runs Python in Oh My Pi. Open the terminal to run it.")),
        (.omp, "c", .unsafeText("Oh My Pi reads this as Continue. Open the terminal to continue.")),
        (
            .omp, "-> x",
            .unsafeText("Oh My Pi queues a message starting with -> or => for later. Open the terminal to queue one.")
        ),
        (
            .omp, (1...100).map { "line \($0)" }.joined(separator: "\n"),
            .unsafeText(
                "Oh My Pi opens a menu for pastes of 100 lines or more. Shorten the message or paste it in the terminal."
            )
        ),
        (.omp, "/compact keep the API notes", .commandUnavailable("Add compaction focus in the Agent terminal.")),
        (.codex, "!ls", .unsafeText("A message starting with ! runs a shell command. Open the terminal to run one.")),
        (.pi, "a\u{1B}[201~b", .unsafeText("The message contains terminal control characters.")),
    ]

    @Test(arguments: wordedRefusals)
    func refusalsKeepTheirWording(program: ChatProgram, draft: String, refusal: ComposerRefusal) {
        #expect(Self.rules(program).validate(draft) == refusal)
    }

    // MARK: Profiles

    @Test func aProfilesExitWordsRefuseInTheProgramsName() {
        let rules = Self.rules(.codex, profile: ChatSendProfile(exitWords: ["bye"]))

        #expect(
            rules.validate("  BYE \n") == .unsafeText("Sending this would exit Codex. Open the terminal to exit."))
        #expect(rules.validate("bye now") == nil)
    }

    @Test func aProfileRefusalComesAfterTheSharedRules() {
        let profile = ChatSendProfile(
            exitWords: [],
            refusal: { clean, _ in
                clean.contains("/btw") ? .unsafeText("Side questions stay in the terminal.") : nil
            })
        let rules = Self.rules(.codex, profile: profile)

        #expect(rules.validate("ask /btw why") == .unsafeText("Side questions stay in the terminal."))
        #expect(
            rules.validate("!ls /btw")
                == .unsafeText("A message starting with ! runs a shell command. Open the terminal to run one."))
        #expect(rules.validate("plain") == nil)
    }

    @Test func aBareCommandGoesAloneAndRefusesArguments() {
        let profile = ChatSendProfile(
            exitWords: [],
            submission: { $0.kind == .compact ? .bare(argumentsRefusal: "No focus here.") : .trailingSpace })
        let rules = Self.rules(.codex, profile: profile)

        #expect(rules.outgoingText("  /compact \n") == "/compact")
        #expect(rules.validate("/compact keep notes") == .commandUnavailable("No focus here."))
        #expect(rules.outgoingText("/review the diff") == "$review the diff ")
    }

    // MARK: Commands

    @Test func claudeSkillsAreSentAsTyped() {
        let rules = Self.rules(.claude)

        #expect(rules.validate("/review the diff") == nil)
        #expect(rules.outgoingText("/review the diff") == "/review the diff ")
        #expect(rules.outgoingText("  /deploy") == "/deploy ")
    }

    @Test func codexSkillsAreSentWithTheirDollarPrefix() {
        let rules = Self.rules(.codex)

        #expect(rules.outgoingText("/review the diff") == "$review the diff ")
        #expect(rules.outgoingText("/deploy") == "$deploy ")
    }

    @Test(arguments: ChatProgram.allCases)
    func aPickedSkillSendsInTheProgramsOwnForm(program: ChatProgram) {
        let skill = AgentSkill(
            scope: .project, name: "review", description: nil,
            commandPrefix: Self.skillPrefix(program))

        #expect(skill.chatInsertionText == "/review ")
        #expect(
            Self.rules(program).outgoingText(skill.chatInsertionText + "the diff")
                == "\(skill.command) the diff ")
    }

    @Test func compactIsOfferedOnlyWhileIdleAndBeatsASkillOfTheSameName() {
        let idle = Self.rules(.codex)
        let busy = Self.rules(.codex, idle: false)

        #expect(idle.commands.filter { $0.name == "compact" }.map(\.kind) == [.compact])
        #expect(idle.outgoingText("/compact") == "/compact ")
        guard case .commandAwaitsIdle = busy.validate("/compact") else {
            Issue.record("/compact was sent while the Agent worked")
            return
        }
    }

    @Test func ompCompactIsSentWithoutATrailingSpace() {
        let rules = Self.rules(.omp)

        #expect(rules.outgoingText("/compact") == "/compact")
        #expect(rules.outgoingText("  /compact \n") == "/compact")
    }

    @Test func ompCompactWithFocusIsRefused() {
        guard case .commandUnavailable = Self.rules(.omp).validate("/compact keep the API notes") else {
            Issue.record("/compact with a focus was sent to Oh My Pi")
            return
        }
    }

    /// Claude Code, Codex and Pi take `/compact` like any message: with a
    /// focus, and with the trailing space.
    @Test(arguments: [ChatProgram.claude, .codex, .pi])
    func compactKeepsTrailingSpaceAndArguments(program: ChatProgram) {
        let rules = Self.rules(program)

        #expect(rules.validate("/compact") == nil)
        #expect(rules.outgoingText("/compact") == "/compact ")
        #expect(rules.validate("/compact keep the API notes") == nil)
        #expect(rules.outgoingText("/compact keep the API notes") == "/compact keep the API notes ")
    }

    @Test(arguments: ["/usr/bin/env python3", "/tmp/a.txt is missing"])
    func aLeadingPathIsText(draft: String) {
        let rules = Self.rules(.claude)

        #expect(rules.read(draft) == .text)
        #expect(rules.outgoingText(draft) == draft + " ")
    }

    @Test(arguments: ["/model", "/", "/ review", "/Review"])
    func aCommandOutsideTheMenuIsNotSent(draft: String) {
        guard case .unknownCommand = Self.rules(.claude).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test func aSlashWordMidMessageIsText() {
        let rules = Self.rules(.codex)

        #expect(rules.read("please run /review later") == .text)
        #expect(rules.outgoingText("please run /review later") == "please run /review later ")
    }

    // MARK: Text

    @Test func exactlyOneTrailingSpaceIsSent() {
        let rules = Self.rules(.claude)

        #expect(rules.outgoingText("hello") == "hello ")
        #expect(rules.outgoingText("hello   \n\n") == "hello ")
        #expect(rules.outgoingText("line one\nline two") == "line one\nline two ")
    }

    @Test func invisibleCharactersAreRemoved() {
        let rules = Self.rules(.claude)
        let draft = "a\u{200B}b\u{202E}c\u{FE0F}d\u{E0041}e\u{FEFF}"

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == "abcde ")
    }

    @Test(arguments: ChatProgram.allCases, ["@src/main.swift fix it", "$deploy now", "café ☕"])
    func mentionsAndDollarWordsPassThrough(program: ChatProgram, draft: String) {
        let rules = Self.rules(program)

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == draft + " ")
    }

    @Test func carriageReturnsBecomeLineFeeds() {
        #expect(Self.rules(.claude).outgoingText("a\r\nb\rc") == "a\nb\nc ")
    }

    // MARK: Menu

    /// A Pi Host's catalog: prompt templates, one named like a built-in
    /// and one like a skill listed after it, and `/skill:` skills.
    private static let piCatalog = [
        AgentSkill(scope: .project, name: "share", description: "A template named like a built-in"),
        AgentSkill(scope: .project, name: "pdf", description: "A template named like a skill"),
        AgentSkill(scope: .global, name: "pdf", description: "Read PDFs", commandPrefix: "/skill:"),
        AgentSkill(scope: .global, name: "deploy", description: nil, commandPrefix: "/skill:"),
    ]

    private static func catalogRules(_ program: ChatProgram) -> ChatSendRules {
        ChatSendRules(
            program: program,
            commands: ChatCommandMenu.commands(skills: piCatalog, agentIsIdle: true, program: program))
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func piAndOmpOfferOnlySkillCommands(program: ChatProgram) {
        let commands = Self.catalogRules(program).commands

        #expect(commands.map(\.name) == ["compact", "pdf", "deploy"])
        #expect(commands.first { $0.name == "pdf" }?.kind == .skill(prefix: "/skill:"))
    }

    @Test(arguments: [ChatProgram.claude, .codex])
    func claudeAndCodexOfferEverySkill(program: ChatProgram) {
        #expect(Self.catalogRules(program).commands.map(\.name) == ["compact", "share", "pdf", "deploy"])
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func aPiTemplateNamedLikeABuiltinIsRefused(program: ChatProgram) {
        #expect(Self.catalogRules(program).validate("/share") == .unknownCommand("share"))
    }

    @Test func piSkillSendsInSkillForm() {
        let rules = Self.catalogRules(.pi)

        #expect(rules.outgoingText("/pdf x") == "/skill:pdf x ")
        #expect(rules.outgoingText("/deploy") == "/skill:deploy ")
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func aSkillTypedInSkillFormIsFound(program: ChatProgram) {
        let rules = Self.catalogRules(program)

        #expect(rules.outgoingText("/skill:pdf x") == "/skill:pdf x ")
        #expect(ChatCommandMenu.suggestions(for: "/skill:", in: rules.commands)?.map(\.name) == ["pdf", "deploy"])
        #expect(ChatCommandMenu.suggestions(for: "/skill:p", in: rules.commands)?.map(\.name) == ["pdf"])
        #expect(rules.validate("/skill:share") == .unknownCommand("skill:share"))
        #expect(rules.validate("/skill:compact") == .unknownCommand("skill:compact"))
    }

    /// Claude Code answers "Unknown command" for a `user-invocable: false`
    /// skill, and Grok Build doesn't offer one as a command; Codex, Pi and
    /// Oh My Pi have no such key and take every skill. OpenCode is offered
    /// none.
    @Test(arguments: ChatProgram.allCases)
    func onlyClaudeAndGrokHideASkillNotUserInvocable(program: ChatProgram) {
        let prefix = Self.skillPrefix(program)
        let catalog = [
            AgentSkill(scope: .project, name: "review", description: nil, commandPrefix: prefix),
            AgentSkill(
                scope: .project, name: "e2e-hidden", description: nil, commandPrefix: prefix,
                isUserInvocable: false),
        ]
        let rules = ChatSendRules(
            program: program,
            commands: ChatCommandMenu.commands(skills: catalog, agentIsIdle: true, program: program))
        let names = rules.commands.map(\.name)

        switch program {
        case .claude, .grok:
            #expect(names == ["compact", "review"])
            #expect(rules.validate("/e2e-hidden") == .unknownCommand("e2e-hidden"))
        case .codex, .pi, .omp:
            #expect(names == ["compact", "review", "e2e-hidden"])
        case .opencode:
            #expect(names == ["compact"])
        }
    }

    @Test func aSkillFormIsOnlyReadForSkillCommands() {
        let rules = Self.rules(.claude)

        #expect(rules.validate("/skill:review") == .unknownCommand("skill:review"))
        #expect(ChatCommandMenu.suggestions(for: "/skill:", in: rules.commands)?.isEmpty == true)
    }

    @Test func theMenuOpensOnlyOnALeadingSlashBeforeASpace() {
        let commands = Self.rules(.claude).commands

        #expect(ChatCommandMenu.suggestions(for: "/", in: commands)?.map(\.name) == ["compact", "review", "deploy"])
        #expect(ChatCommandMenu.suggestions(for: "/re", in: commands)?.map(\.name) == ["review"])
        #expect(ChatCommandMenu.suggestions(for: "/review ", in: commands) == nil)
        #expect(ChatCommandMenu.suggestions(for: " /re", in: commands) == nil)
        #expect(ChatCommandMenu.suggestions(for: "/usr/", in: commands) == nil)
        #expect(ChatCommandMenu.suggestions(for: "hello", in: commands) == nil)
    }

    // MARK: Grok Build

    private static let grokSideQuestion = ComposerRefusal.unsafeText(
        "Grok Build would treat this as a /btw side question and keep it out of the conversation. "
            + "Rephrase it, or ask in the terminal.")
    private static let grokMidTextGoal = ComposerRefusal.unsafeText(
        "Grok Build runs /goal only at the start of a message and wouldn't send this. Set goals in the terminal.")

    @Test(arguments: ["exit", "quit", ":q", ":q!", ":wq", ":wq!", "  Exit\n", "QUIT"])
    func grokRefusesItsExitWords(text: String) {
        #expect(
            Self.rules(.grok).validate(text)
                == .unsafeText("Sending this would exit Grok Build. Open the terminal to exit."))
    }

    /// Grok Build reads a `/` token after whitespace anywhere in a message:
    /// it asks `/btw` as a side question that stays out of the conversation,
    /// and refuses `/goal` there, leaving the message in its input box.
    @Test(arguments: ["what next /btw ok", "a\n/goal b", "fix it /GOAL", "ask\t/BTW why"])
    func grokRefusesMidTextBtwAndGoal(text: String) throws {
        let refusals = [
            "what next /btw ok": Self.grokSideQuestion, "a\n/goal b": Self.grokMidTextGoal,
            "fix it /GOAL": Self.grokMidTextGoal, "ask\t/BTW why": Self.grokSideQuestion,
        ]
        let refusal = try #require(refusals[text])

        #expect(Self.rules(.grok).validate(text) == refusal)
        #expect(Self.rules(.codex).validate(text) == nil, "only Grok Build reads them mid-text")
    }

    /// A leading command is the menu's to read, as for any program.
    @Test func grokLeavesALeadingGoalToTheMenuRule() {
        let rules = Self.rules(.grok)

        #expect(rules.validate("/goal x") == .unknownCommand("goal"))
        #expect(rules.validate("  /btw why") == .unknownCommand("btw"))
    }

    /// A token starts at `/` after whitespace and runs to the next
    /// whitespace, so these name other commands, or none.
    @Test(arguments: ["/btw,", "a/btw", "/btwx", "/goals"])
    func grokSendsLookalikes(text: String) {
        let draft = "what next \(text) ok"
        let rules = Self.rules(.grok)

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == draft + " ")
    }

    @Test func grokOffersSkillsAndCompact() {
        let commands = Self.rules(.grok).commands

        #expect(commands.map(\.name) == ["compact", "review", "deploy"])
        #expect(commands.first { $0.name == "compact" }?.kind == .compact)
        #expect(commands.first { $0.name == "review" }?.kind == .skill(prefix: "/"))
        #expect(ChatCommandMenu.suggestions(for: "/re", in: commands)?.map(\.name) == ["review"])
    }

    /// Grok Build keeps a built-in command's bare name, in any case, and
    /// offers a skill named like one only under a qualified name.
    @Test(arguments: ["quit", "delete", "new", "undo", "always-approve", "plan", "logout"])
    func grokLeavesOutSkillsNamedLikeBuiltIns(name: String) {
        let catalog = [
            AgentSkill(scope: .project, name: name, description: nil),
            AgentSkill(scope: .global, name: name.uppercased(), description: nil),
            AgentSkill(scope: .global, name: "review", description: nil),
        ]
        let rules = ChatSendRules(
            program: .grok, commands: ChatCommandMenu.commands(skills: catalog, agentIsIdle: true, program: .grok))

        #expect(rules.commands.map(\.name) == ["compact", "review"])
        #expect(rules.validate("/\(name)") == .unknownCommand(name))
    }

    /// Grok Build 1.0.62 answers `/compact` with text after it with the
    /// toast "/compact takes no arguments." and sends nothing, so a focus is
    /// refused before the idle rule, without pointing at the terminal.
    @Test func grokRefusesCompactWithAFocus() {
        let focus = ComposerRefusal.commandUnavailable(
            "Grok Build's /compact takes no focus. Send /compact on its own.")
        let idle = Self.rules(.grok)
        let busy = Self.rules(.grok, idle: false)

        #expect(idle.validate("/compact keep the API notes") == focus)
        #expect(busy.validate("/compact keep the API notes") == focus)
        #expect(idle.validate("  /compact \n") == nil)
        #expect(busy.validate("/compact") == .commandAwaitsIdle("compact"))
    }

    /// Grok Build trims the space before it parses a command.
    @Test func grokSendsEveryCommandWithATrailingSpace() {
        let rules = Self.rules(.grok)

        #expect(rules.outgoingText("/compact") == "/compact ")
        #expect(rules.outgoingText("  /compact \n") == "/compact ")
        #expect(rules.outgoingText("/review the diff") == "/review the diff ")
        #expect(rules.outgoingText("/deploy") == "/deploy ")
        #expect(rules.commands.allSatisfy { rules.profile.submission($0) == .trailingSpace })
    }

    // MARK: OpenCode

    @Test(arguments: ["exit", "quit", ":q", "  QUIT \n", ":wq!"])
    func openCodeExitWordsAreNeverSent(draft: String) {
        #expect(
            Self.rules(.opencode).validate(draft)
                == .unsafeText("Sending this would exit OpenCode. Open the terminal to exit."))
    }

    /// OpenCode runs `/compact` from its popup when Enter follows the name;
    /// after a space, the popup closes and the text goes to the model.
    @Test func openCodeSendsCompactBareAndRefusesInstructions() {
        let rules = Self.rules(.opencode)

        #expect(rules.validate("/compact") == nil)
        #expect(rules.outgoingText("/compact") == "/compact")
        #expect(rules.outgoingText("  /compact \n") == "/compact")
        #expect(
            rules.validate("/compact keep the API notes")
                == .commandUnavailable("OpenCode's /compact takes no instructions. Send /compact alone."))
    }

    /// The menu holds only `/compact`: OpenCode's skills have no form a
    /// message invokes, and its other commands stay in the terminal.
    @Test func openCodeOffersNoSkillsOrCommands() {
        let rules = Self.rules(.opencode)

        #expect(rules.commands.map(\.name) == ["compact"])
        #expect(rules.validate("/review the diff") == .unknownCommand("review"))
        for name in ["new", "sessions", "undo", "btw", "cd", "rename"] {
            #expect(rules.validate("/\(name)") == .unknownCommand(name))
        }
    }

    /// OpenCode attaches the files a paste of paths alone names, rather
    /// than sending the text: a quoted or escaped path with spaces, a
    /// `file://` URL, several paths, or one with spaces left unquoted. The
    /// refusal says to put words first, as words after a staged file's
    /// absolute path would leave a command path leading.
    @Test(arguments: [
        "/home/dev/shot.png", "'/home/dev/My Shots/a.JPG'", "file:///home/dev/doc.pdf", "a.png b.webp", "shot.svg",
        "~/notes.txt", "./build.log", "../README.md", "/home/dev/notes.txt", "/home/dev/My\\ Shots/a.png",
        "/home/dev/My Great Shots/a.png",
    ])
    func openCodeRefusesADraftOfOnlyPaths(draft: String) {
        let rules = Self.rules(.opencode)

        #expect(
            rules.validate(draft)
                == .unsafeText(
                    "OpenCode can take a message that is only a file path as an attachment instead of text. "
                        + "Start with a few words, such as what to do with the file, and OpenCode's agent can read "
                        + "it from its path."))
        #expect(rules.validate("what is in " + draft) == nil)
    }

    /// OpenCode names a command by its file's path under `commands/` and
    /// runs a message whose first word names one, so a leading `/name` with
    /// a slash in it is no path in prose there. A bare one is refused as a
    /// path first.
    @Test(arguments: [
        ("/git/commit fix the typo", "git/commit"), ("/usr/bin/env python3 is missing", "usr/bin/env"),
        ("/review/pr\n12", "review/pr"),
    ])
    func openCodeRefusesALeadingCommandPath(draft: String, name: String) {
        let rules = Self.rules(.opencode)

        #expect(
            rules.validate(draft)
                == .unsafeText(
                    "OpenCode can run a message starting with /\(name) as one of its commands. "
                        + "Start with another word, or open the terminal to run it."))
        #expect(rules.validate("/git/commit") != nil)
    }

    @Test(arguments: ["look at /home/dev/shot.png", "a.png is broken", "https://example.invalid/a.png", "notes.txt"])
    func openCodeSendsPathsInsideText(draft: String) {
        let rules = Self.rules(.opencode)

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == draft + " ")
    }

    /// A typed space closes OpenCode's `@` popup, so a message that ends in
    /// a mention is submitted rather than completed.
    @Test(arguments: ["add @MainActor", "cc @alice", "mail a@b.c"])
    func openCodeSendsEndWithOneSpace(draft: String) {
        let rules = Self.rules(.opencode)

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == draft + " ")
    }
}
