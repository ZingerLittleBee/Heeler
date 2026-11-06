import Foundation
import Observation

/// Native conversation titles, separate from herdr's restricted Agent aliases.
enum AgentTitleNaming {
    static func supportsGeneration(_ program: ChatProgram) -> Bool {
        switch program {
        case .claude, .codex, .omp: true
        case .pi, .grok, .opencode: false
        }
    }

    static func title(of agent: Agent, program: ChatProgram) -> String {
        var title = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (agent.foregroundCwd ?? agent.cwd).split(separator: "/").last.map(String.init) ?? ""
        switch program {
        case .claude: break
        case .codex:
            if !directory.isEmpty, let separator = title.range(of: " | ", options: .backwards) {
                let suffix = String(title[separator.upperBound...])
                let shortened = suffix.hasSuffix("...") ? String(suffix.dropLast(3)) : nil
                if suffix == directory || shortened.map({ !$0.isEmpty && directory.hasPrefix($0) }) == true {
                    title = String(title[..<separator.lowerBound])
                }
            }
        case .pi:
            if title.hasPrefix("π - ") { title.removeFirst(4) }
            let suffix = " - " + directory
            if !directory.isEmpty, title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        case .omp:
            if title.hasPrefix("π > ") { title.removeFirst(4) }
            // OMP's title card (icon + uppercase code) is presentation, not the name.
            title = title.replacingOccurrences(
                of: #"^\S+ [A-Z][A-Z0-9_-]*: "#, with: "", options: .regularExpression)
        case .grok:
            if title.hasSuffix(" - grok") { title.removeLast(7) }
        case .opencode:
            if title.hasPrefix("OC | ") { title.removeFirst(5) }
        }
        return title
    }

    static func validation(_ title: String) -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a title."
        }
        guard title.count <= 120 else { return "Use 120 characters or fewer." }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !title.unicodeScalars.contains(where: { forbidden.contains($0) }) else {
            return "Use a single line without control characters."
        }
        return nil
    }

    static func matches(_ agent: Agent, program: ChatProgram, title: String) -> Bool {
        if program == .opencode {
            return agent.terminalTitleStripped == OpenCodeTerminalTitle.expected(sessionTitle: title)
                || agent.title == OpenCodeTerminalTitle.expected(sessionTitle: title)
        }
        return self.title(of: agent, program: program) == title
    }
}

/// One-shot native input with explicit read-back. No operation retries a mutation.
@MainActor
struct AgentTitleRenameIO {
    var agent: () async throws -> Agent
    var screen: () async throws -> ANSIScreen
    var prompt: (String) async throws -> Void
    var keys: ([String]) async throws -> Void
    var paste: (String) async throws -> Void
    var refresh: () async -> Void
    var acquire: () -> Bool = { true }
    var release: () -> Void = {}
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

struct AgentTitleRenameError: LocalizedError {
    let message: String
    var confirmedFailure = false
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class AgentTitleRenameStore: Identifiable {
    let id = UUID()
    enum State: Equatable {
        case editing, saving, generating, renamed
        case failed(String)
    }

    let program: ChatProgram
    var input: String
    private(set) var state: State = .editing
    private let expected: Agent
    private let io: AgentTitleRenameIO
    /// A timeout or interrupted write requires reopening and checking the terminal.
    private(set) var outcomeUncertain = false
    private var dispatched = false

    init(agent: Agent, program: ChatProgram, io: AgentTitleRenameIO) {
        expected = agent
        self.program = program
        self.io = io
        input = AgentTitleNaming.title(of: agent, program: program)
    }

    var isBusy: Bool { state == .saving || state == .generating }
    var canSave: Bool { !isBusy && !outcomeUncertain && AgentTitleNaming.validation(input) == nil }
    var canGenerate: Bool { !isBusy && !outcomeUncertain && AgentTitleNaming.supportsGeneration(program) }
    var generationUnavailable: String? {
        AgentTitleNaming.supportsGeneration(program) ? nil
            : "Automatic title generation isn't available for \(program.chatName) here."
    }

    func save() async {
        guard canSave else { return }
        await perform(generating: false)
    }

    func generate() async {
        guard canGenerate else { return }
        await perform(generating: true)
    }

    private func perform(generating: Bool) async {
        guard io.acquire() else {
            state = .failed("A rename is already in progress for this Agent.")
            return
        }
        state = generating ? .generating : .saving
        dispatched = false
        defer { io.release() }
        do {
            let initial = try await checkedAgent()
            guard initial.status == .idle || initial.status == .done else {
                throw failure("Wait until the Agent is idle before renaming.")
            }
            guard initial.agentSession != nil else {
                throw failure("The Agent hasn't reported its conversation. Open Chat and check its session before renaming.")
            }
            let screen = try await io.screen()
            guard InputBoxStateDetector.detect(screen, program: program).isSendable else {
                throw failure("The Agent's input is not empty or ready. Finish the draft or dialog in Terminal first.")
            }
            let target = input.trimmingCharacters(in: .whitespacesAndNewlines)
            var resultTarget: String? = generating ? nil : target
            if !generating, AgentTitleNaming.matches(initial, program: program, title: target) {
                state = .renamed
                return
            }
            if program == .opencode {
                try await renameOpenCode(target, initial: initial)
            } else {
                let command = program == .pi ? "/name" : "/rename"
                _ = try await checkedAgent(session: initial.agentSession, idle: true)
                guard InputBoxStateDetector.detect(try await io.screen(), program: program).isSendable else {
                    throw failure("The Agent's input changed. Nothing was sent.")
                }
                dispatched = true
                try await io.prompt(generating ? command : command + " " + target)
            }
            if generating, program == .codex {
                resultTarget = try await confirmCodexSuggestion(initial: initial)
            }
            try await awaitResult(initial: initial, target: resultTarget, before: screen)
            await io.refresh()
            state = .renamed
        } catch {
            outcomeUncertain = dispatched && (error as? AgentTitleRenameError)?.confirmedFailure != true
            let reason = (error as? AgentTitleRenameError)?.message
                ?? "The Host did not confirm the rename."
            state = .failed(outcomeUncertain
                ? reason + " Check the title in Terminal before trying again."
                : reason)
            if dispatched { await io.refresh() }
        }
    }

    private func checkedAgent(session: AgentSessionInfo? = nil, idle: Bool = false) async throws -> Agent {
        try Task.checkCancellation()
        let fresh = try await io.agent()
        guard fresh.terminalID == expected.terminalID, fresh.paneID == expected.paneID,
            fresh.kind == expected.kind, fresh.workspaceID == expected.workspaceID,
            fresh.tabID == expected.tabID,
            expected.agentSession == nil || fresh.agentSession == expected.agentSession,
            session == nil || fresh.agentSession == session else {
            throw failure("The Agent or conversation changed. Reopen Rename for the current conversation.")
        }
        if idle, fresh.status != .idle && fresh.status != .done {
            throw failure("The Agent is no longer idle.")
        }
        return fresh
    }

    private func renameOpenCode(_ title: String, initial: Agent) async throws {
        _ = try await checkedAgent(session: initial.agentSession, idle: true)
        dispatched = true
        try await io.keys(["ctrl+r"])
        var dialog: ANSIScreen?
        for _ in 0..<10 {
            try await io.sleep(.milliseconds(200))
            _ = try await checkedAgent(session: initial.agentSession)
            let read = try await io.screen()
            if Self.openCodeField(read) != nil { dialog = read; break }
        }
        guard let dialog, let field = Self.openCodeField(dialog),
            AgentTitleNaming.matches(initial, program: .opencode, title: field) else {
            throw failure("OpenCode did not show the expected Rename session dialog.")
        }
        _ = try await checkedAgent(session: initial.agentSession)
        guard Self.openCodeField(try await io.screen()) == field else {
            throw failure("OpenCode's rename dialog changed.")
        }
        try await io.keys(["ctrl+e", "ctrl+u"])
        try await io.sleep(.milliseconds(150))
        _ = try await checkedAgent(session: initial.agentSession)
        guard Self.openCodeField(try await io.screen()) == "" else {
            throw failure("OpenCode's title field could not be cleared.")
        }
        try await io.paste(title)
        try await io.sleep(.milliseconds(150))
        _ = try await checkedAgent(session: initial.agentSession)
        guard Self.openCodeField(try await io.screen()) == title else {
            throw failure("OpenCode did not receive the complete title.")
        }
        try await io.keys(["enter"])
    }

    private func confirmCodexSuggestion(initial: Agent) async throws -> String {
        for _ in 0..<60 {
            try await io.sleep(.milliseconds(500))
            _ = try await checkedAgent(session: initial.agentSession)
            let screen = try await io.screen()
            guard let suggestion = Self.codexSuggestion(screen) else { continue }
            _ = try await checkedAgent(session: initial.agentSession)
            guard Self.codexSuggestion(try await io.screen()) == suggestion else {
                throw failure("Codex's title suggestion changed before confirmation.")
            }
            try await io.keys(["enter"])
            return suggestion
        }
        throw failure("Codex did not produce a title suggestion in time.")
    }

    private func awaitResult(initial: Agent, target: String?, before: ANSIScreen) async throws {
        let oldText = before.rows.map(\.text).joined(separator: "\n")
        for _ in 0..<60 {
            try await io.sleep(.milliseconds(500))
            let fresh = try await checkedAgent(session: initial.agentSession)
            if let target {
                if AgentTitleNaming.matches(fresh, program: program, title: target) { return }
            } else if fresh.title != initial.title,
                !AgentTitleNaming.title(of: fresh, program: program).isEmpty,
                fresh.status == .idle || fresh.status == .done { return }
            let text = try await io.screen().rows.map(\.text).joined(separator: "\n")
            if target == nil, fresh.status == .idle || fresh.status == .done,
                let acknowledgement = nativeAcknowledgement(for: fresh),
                acknowledgementCount(acknowledgement, in: text)
                    > acknowledgementCount(acknowledgement, in: oldText) {
                // Generating again can legitimately produce the current title.
                return
            }
            if ["Could not generate a session title", "Rename failed:"].contains(where: {
                text.contains($0) && !oldText.contains($0)
            }) {
                throw AgentTitleRenameError(message: "The Agent could not generate or save the title.", confirmedFailure: true)
            }
        }
        throw failure("The Agent did not confirm the new title in time.")
    }

    private func nativeAcknowledgement(for agent: Agent) -> String? {
        switch program {
        case .claude:
            return "Session renamed to: " + agent.title
        case .omp:
            let card = agent.title.hasPrefix("π > ") ? String(agent.title.dropFirst(4)) : agent.title
            return "Session renamed to \"" + card + "\"."
        default: return nil
        }
    }

    private func acknowledgementCount(_ acknowledgement: String, in text: String) -> Int {
        text.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasSuffix(acknowledgement)
        }.count
    }

    /// A bounded native dialog, not a matching phrase anywhere in the transcript.
    static func openCodeField(_ screen: ANSIScreen) -> String? {
        let lines = screen.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Rename session") && $0.hasSuffix("esc") }),
            let end = lines.indices.dropFirst(start + 1).first(where: { lines[$0] == "submit enter" }),
            end - start <= 6 else { return nil }
        let values = ((start + 1)..<end).filter { !lines[$0].isEmpty }
        guard values.count <= 1 else { return nil }
        guard let field = values.first else { return "" }
        // OpenCode paints its empty placeholder in the same muted color as
        // the Escape hint. A real title with this spelling uses input color.
        if lines[field] == "Session title",
            let hint = screen.rows[start].runs.first(where: {
                $0.text.trimmingCharacters(in: .whitespaces) == "esc"
            })?.style.foreground,
            let placeholder = screen.rows[field].runs.first(where: {
                $0.text.trimmingCharacters(in: .whitespaces) == "Session title"
            })?.style.foreground,
            placeholder == hint { return "" }
        return lines[field]
    }

    static func codexSuggestion(_ screen: ANSIScreen) -> String? {
        let lines = screen.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(of: "Rename thread"),
            let end = lines.indices.dropFirst(start + 1).first(where: { lines[$0] == "enter submit · esc back" }),
            end - start <= 8,
            lines[(start + 1)..<end].contains("Suggested from this conversation"),
            let field = lines[(start + 1)..<end].first(where: { $0.hasPrefix("› ") }) else { return nil }
        let title = String(field.dropFirst(2))
        return AgentTitleNaming.validation(title) == nil ? title : nil
    }

    private func failure(_ message: String) -> AgentTitleRenameError { .init(message: message) }
}
