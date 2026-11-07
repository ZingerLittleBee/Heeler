import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Native Agent title rename")
struct AgentTitleRenameTests {
    @Test(arguments: ChatProgram.allCases)
    func savesNativeTitleAndRefreshes(program: ChatProgram) async throws {
        let rig = try Rig(program)
        let store = rig.store()
        store.input = "  Updated guide ✅  "
        await store.save()
        #expect(store.state == .renamed)
        #expect(rig.refreshes == 1)
        if program == .opencode {
            #expect(rig.commands.isEmpty)
            #expect(rig.pastes == ["Updated guide ✅"])
            #expect(rig.keys == [["ctrl+r"], ["ctrl+e", "ctrl+u"], ["enter"]])
        } else {
            #expect(rig.commands == [(program == .pi ? "/name " : "/rename ") + "Updated guide ✅"])
        }
    }

    @Test(arguments: [ChatProgram.claude, .codex, .omp])
    func regeneratesThroughNativeCommand(program: ChatProgram) async throws {
        let rig = try Rig(program)
        let store = rig.store()
        await store.generate()
        #expect(store.state == .renamed)
        #expect(rig.commands == ["/rename"])
        #expect(rig.keys == (program == .codex ? [["enter"]] : []))
        #expect(rig.refreshes == 1)
    }

    @Test(arguments: [ChatProgram.pi, .grok, .opencode])
    func unsupportedGenerationSendsNothing(program: ChatProgram) async throws {
        let rig = try Rig(program)
        let store = rig.store()
        #expect(store.generationUnavailable != nil)
        await store.generate()
        #expect(rig.commands.isEmpty)
        #expect(rig.keys.isEmpty)
    }

    @Test(arguments: ["", "   ", "hello\n/exit", "title\u{2028}/exit", "title\u{1b}[A", String(repeating: "x", count: 121)])
    func invalidInputSendsNothing(value: String) async throws {
        let rig = try Rig(.claude)
        let store = rig.store()
        store.input = value
        await store.save()
        #expect(!store.canSave)
        #expect(rig.commands.isEmpty)
    }

    @Test(arguments: [AgentStatus.working, .blocked, .unknown])
    func busyAgentSendsNothing(status: AgentStatus) async throws {
        let rig = try Rig(.claude)
        rig.status = status
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(rig.commands.isEmpty)
        #expect(!store.outcomeUncertain)
    }

    @Test func refusesDraftAndChangedSession() async throws {
        let rig = try Rig(.claude)
        let store = rig.store()
        store.input = "New title"
        rig.screenOverride = ANSIScreenDecoder.decode("❯ unfinished draft")
        await store.save()
        #expect(rig.commands.isEmpty)
        rig.screenOverride = nil
        rig.session = "another-conversation"
        await store.save()
        #expect(rig.commands.isEmpty)
    }

    @Test func refusesMissingSession() async throws {
        let rig = try Rig(.pi)
        rig.session = nil
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(rig.commands.isEmpty)
    }

    @Test func noAcknowledgementDoesNotReplay() async throws {
        let rig = try Rig(.claude)
        rig.apply = false
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(store.outcomeUncertain)
        await store.save()
        await store.generate()
        #expect(rig.commands == ["/rename New title"])
        #expect(store.input == "New title")
    }

    @Test func generationFailureKeepsManualDraft() async throws {
        let rig = try Rig(.omp)
        rig.apply = false
        let store = rig.store()
        store.input = "Keep my draft"
        rig.afterCommand = { rig.screenOverride = ANSIScreenDecoder.decode("Could not generate a session title. Use /rename <title> to set one.") }
        await store.generate()
        #expect(store.input == "Keep my draft")
        #expect(!store.outcomeUncertain)
        #expect(store.canSave)
        #expect(rig.title == "Original")
    }

    @Test(arguments: [ChatProgram.claude, .omp])
    func generationMayConfirmTheSameTitle(program: ChatProgram) async throws {
        let rig = try Rig(program)
        rig.apply = false
        rig.afterCommand = {
            rig.screenOverride = ANSIScreenDecoder.decode(program == .claude
                ? "Session renamed to: Original"
                : "Session renamed to \"📝 MANUAL: Original\".")
        }
        let store = rig.store()
        await store.generate()
        #expect(store.state == .renamed)
    }

    @Test func sessionChangeAfterPromptNeverConfirmsDialog() async throws {
        let rig = try Rig(.codex)
        rig.afterCommand = { rig.session = "changed" }
        let store = rig.store()
        await store.generate()
        #expect(store.outcomeUncertain)
        #expect(rig.keys.isEmpty)
    }

    @Test func duplicateOperationsShareOneLease() async throws {
        let rig = try Rig(.claude)
        let first = rig.store()
        let second = rig.store()
        first.input = "First"
        second.input = "Second"
        rig.afterCommand = { await second.save() }
        await first.save()
        #expect(first.state == .renamed)
        #expect(rig.commands == ["/rename First"])
        if case .failed = second.state {} else { Issue.record("second rename should be refused") }
    }

    @Test func openCodeFullTitleMatchesTruncatedTerminalTitle() async throws {
        let rig = try Rig(.opencode)
        rig.title = String(repeating: "Long title ", count: 6)
        rig.openCodeInitial = rig.title
        let store = rig.store()
        store.input = "Short replacement"
        await store.save()
        #expect(store.state == .renamed)
        #expect(rig.pastes == ["Short replacement"])
    }

    @Test func openCodeDialogChangeNeverClearsUserInput() async throws {
        let rig = try Rig(.opencode)
        rig.openCodeInitial = "Different conversation"
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(rig.keys == [["ctrl+r"]])
        #expect(rig.pastes.isEmpty)
    }

    @Test func nativeDialogParsersRequireTheirBoundedShape() {
        #expect(AgentTitleRenameStore.codexSuggestion(ANSIScreenDecoder.decode("Rename thread\nGenerating a title suggestion…\n› Old\nenter submit · esc back")) == nil)
        #expect(AgentTitleRenameStore.codexSuggestion(ANSIScreenDecoder.decode("Rename thread\nSuggested from this conversation\n› New\nenter submit · esc back")) == "New")
        #expect(AgentTitleRenameStore.openCodeField(ANSIScreenDecoder.decode("Rename session esc\n\nNew\n\nsubmit enter")) == "New")
        #expect(AgentTitleRenameStore.openCodeField(ANSIScreenDecoder.decode("Rename session\nSome transcript text")) == nil)
    }

    @Test func openCodeEmptyPlaceholderIsNotAnEnteredTitle() {
        let muted = SGR.fg(128, 128, 128)
        let input = SGR.fg(238, 238, 238)
        let header = input + "Rename session    " + muted + "esc" + SGR.reset
        let placeholder = ANSIScreenDecoder.decode(header + "\n\n" + muted + "Session title" + SGR.reset + "\n\nsubmit enter")
        let literal = ANSIScreenDecoder.decode(header + "\n\n" + input + "Session title" + SGR.reset + "\n\nsubmit enter")
        #expect(AgentTitleRenameStore.openCodeField(placeholder) == "")
        #expect(AgentTitleRenameStore.openCodeField(literal) == "Session title")
    }

    @Test func codexShortenedDirectoryDoesNotBecomePartOfTheTitle() {
        let agent = Agent(terminalID: "term", kind: "codex", title: "Guide | worktree-silver-cloud...",
            status: .idle, workspaceID: "w", tabID: "t", paneID: "p",
            cwd: "/worktree-silver-cloud-364f", revision: 1)
        #expect(AgentTitleNaming.title(of: agent, program: .codex) == "Guide")
        #expect(AgentTitleNaming.matches(agent, program: .codex, title: "Guide"))
    }

    @MainActor
    private final class Rig {
        let program: ChatProgram
        let empty: ANSIScreen
        var title = "Original"
        var session: String? = "session-one"
        var status: AgentStatus = .idle
        var commands: [String] = []
        var keys: [[String]] = []
        var pastes: [String] = []
        var refreshes = 0
        var held = false
        var apply = true
        var field: String?
        var openCodeInitial = "Original"
        var screenOverride: ANSIScreen?
        var afterCommand: (() async -> Void)?

        init(_ program: ChatProgram) throws {
            self.program = program
            let fixture: String = switch program {
            case .claude: "claude-01-ready"
            case .codex: "codex-00-ready"
            case .pi: "pi-16-empty-editor-120-attached"
            case .omp: "omp-08-empty-120-after-first"
            case .grok: "grok-01-idle-empty"
            case .opencode: "opencode-02-session-empty-180"
            }
            empty = try ScreenFixture.screen(fixture)
        }

        func agent() -> Agent {
            let displayed: String = switch program {
            case .claude: title
            case .codex: title + " | project"
            case .pi: "π - " + title + " - project"
            case .omp: "π > 📝 MANUAL: " + title
            case .grok: title + " - grok"
            case .opencode: OpenCodeTerminalTitle.expected(sessionTitle: title)
            }
            return Agent(terminalID: "term-one", kind: program.rawValue, title: displayed, status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/project", revision: 1,
                terminalTitleStripped: displayed,
                agentSession: session.map { AgentSessionInfo(agent: program.rawValue, kind: .id, source: "test", value: $0) })
        }

        func store() -> AgentTitleRenameStore {
            AgentTitleRenameStore(agent: agent(), program: program, io: AgentTitleRenameIO(
                agent: { self.agent() },
                screen: {
                    if let override = self.screenOverride { return override }
                    if let field = self.field {
                        return ANSIScreenDecoder.decode(self.program == .opencode
                            ? "Rename session esc\n\n\(field)\n\nsubmit enter"
                            : "Rename thread\nSuggested from this conversation\n\n› \(field)\n\nenter submit · esc back")
                    }
                    return self.empty
                },
                prompt: { command in
                    self.commands.append(command)
                    if self.apply {
                        if command == "/rename", self.program == .codex { self.field = "Generated title" }
                        else { self.title = command == "/rename" ? "Generated title" : String(command.dropFirst(command.hasPrefix("/name ") ? 6 : 8)) }
                    }
                    await self.afterCommand?()
                },
                keys: { keys in
                    self.keys.append(keys)
                    if keys == ["ctrl+r"] { self.field = self.openCodeInitial }
                    if keys == ["ctrl+e", "ctrl+u"] { self.field = "" }
                    if keys == ["enter"], let field = self.field { self.title = field; self.field = nil }
                },
                paste: { self.pastes.append($0); self.field = $0 },
                refresh: { self.refreshes += 1 },
                acquire: { if self.held { return false }; self.held = true; return true },
                release: { self.held = false },
                sleep: { _ in }))
        }
    }
}
