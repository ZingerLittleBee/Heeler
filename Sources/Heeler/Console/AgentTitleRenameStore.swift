import Foundation
import Observation

/// Native conversation titles, separate from herdr's restricted Agent aliases.
enum AgentTitleNaming {
    static func supportsRename(_ program: ChatProgram) -> Bool {
        switch program {
        case .claude, .codex, .pi, .omp, .grok, .opencode, .agy: true
        case .amp: false
        }
    }

    static func supportsGeneration(_ program: ChatProgram) -> Bool {
        switch program {
        case .claude, .codex, .omp: true
        case .pi, .grok, .opencode, .agy, .amp: false
        }
    }

    static func title(of agent: Agent, program: ChatProgram) -> String {
        var title = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (agent.foregroundCwd ?? agent.cwd).split(separator: "/").last.map(String.init) ?? ""
        switch program {
        case .claude, .agy, .amp: break
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
            return String(localized: "Enter a title.")
        }
        guard title.count <= 120 else { return String(localized: "Use 120 characters or fewer.") }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !title.unicodeScalars.contains(where: { forbidden.contains($0) }) else {
            return String(localized: "Use a single line without control characters.")
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

/// A manual conversation title saved on this device while the Agent is running,
/// to be sent through the native rename path once the same Agent and session stop.
struct PendingAgentTitleRename: Codable, Equatable, Sendable {
    let hostID: Host.ID
    let paneID: String
    let terminalID: String
    let workspaceID: String
    let tabID: String
    let program: ChatProgram
    var session: AgentSessionInfo?
    let title: String

    var agentID: ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: hostID, paneID: paneID)
    }

    func matchesIdentity(of agent: Agent) -> Bool {
        agent.terminalID == terminalID
            && agent.paneID == paneID
            && agent.workspaceID == workspaceID
            && agent.tabID == tabID
            && agent.kind == program.rawValue
            && (session == nil || agent.agentSession == session)
    }
}

@MainActor
final class PendingAgentTitleRenameStore {
    static let storageKey = "heeler.console.pendingTitleRenames.v1"
    static let suppressBusyNoticeKey = "heeler.console.suppressBusyTitleRenameNotice.v1"

    private let defaults: UserDefaults?
    private var inMemorySuppressBusyNotice = false
    private(set) var entries: [ConsoleAgent.ID: PendingAgentTitleRename]
    /// Entries whose native rename command has begun dispatching; removed from
    /// persistent storage immediately so an unconfirmed write never replays.
    private var dispatchedIDs: Set<ConsoleAgent.ID> = []
    /// Entries whose dispatch succeeded and stay in memory only until the Host
    /// projection catches up with the confirmed title.
    private var completedIDs: Set<ConsoleAgent.ID> = []

    /// With no `defaults`, entries last only for the lifetime of the store so
    /// demo mode and tests never sweep the real app container.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        entries = defaults.map(Self.load(from:)) ?? [:]
    }

    var suppressBusyNotice: Bool {
        get { defaults?.bool(forKey: Self.suppressBusyNoticeKey) ?? inMemorySuppressBusyNotice }
        set {
            inMemorySuppressBusyNotice = newValue
            defaults?.set(newValue, forKey: Self.suppressBusyNoticeKey)
        }
    }

    func enqueue(_ item: PendingAgentTitleRename) {
        dispatchedIDs.remove(item.agentID)
        completedIDs.remove(item.agentID)
        entries[item.agentID] = item
        persist()
    }

    @discardableResult
    func remove(_ id: ConsoleAgent.ID) -> Bool {
        let hadDispatched = dispatchedIDs.remove(id) != nil
        completedIDs.remove(id)
        let removed = entries.removeValue(forKey: id) != nil
        if removed, !hadDispatched { persist() }
        return removed
    }

    func markDispatched(_ id: ConsoleAgent.ID) {
        guard entries[id] != nil else { return }
        if dispatchedIDs.insert(id).inserted {
            persist()
        }
    }

    func markCompleted(_ id: ConsoleAgent.ID) {
        guard entries[id] != nil else { return }
        let newlyDispatched = dispatchedIDs.insert(id).inserted
        completedIDs.insert(id)
        if newlyDispatched {
            persist()
        }
    }

    func isDispatched(_ id: ConsoleAgent.ID) -> Bool {
        dispatchedIDs.contains(id)
    }

    func isCompleted(_ id: ConsoleAgent.ID) -> Bool {
        completedIDs.contains(id)
    }

    func hasUndispatched(for row: ConsoleAgent) -> Bool {
        guard let item = entries[row.id], !dispatchedIDs.contains(row.id) else { return false }
        return item.matchesIdentity(of: row.agent)
    }

    func noteObservedSession(_ session: AgentSessionInfo, for id: ConsoleAgent.ID) {
        guard var item = entries[id], item.session == nil else { return }
        item.session = session
        entries[id] = item
        if !dispatchedIDs.contains(id) {
            persist()
        }
    }

    func retainHosts(_ hostIDs: Set<Host.ID>) {
        let before = entries.count
        entries = entries.filter { hostIDs.contains($0.key.hostID) }
        dispatchedIDs = dispatchedIDs.filter { hostIDs.contains($0.hostID) }
        completedIDs = completedIDs.filter { hostIDs.contains($0.hostID) }
        if entries.count != before {
            persist()
        }
    }

    func applying(to row: ConsoleAgent) -> ConsoleAgent {
        guard let item = entries[row.id], item.matchesIdentity(of: row.agent) else { return row }
        var copy = row
        copy.agent = copy.agent.applyingConversationTitle(item.title)
        return copy
    }

    private func persist() {
        guard let defaults else { return }
        let persisted = entries.values
            .filter { !dispatchedIDs.contains($0.agentID) }
            .sorted { ($0.hostID.uuidString, $0.paneID) < ($1.hostID.uuidString, $1.paneID) }
        if persisted.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [ConsoleAgent.ID: PendingAgentTitleRename] {
        guard let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([PendingAgentTitleRename].self, from: data)
        else { return [:] }
        var result: [ConsoleAgent.ID: PendingAgentTitleRename] = [:]
        for item in decoded where AgentTitleNaming.validation(item.title) == nil {
            result[item.agentID] = item
        }
        return result
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
    var initialTitle: (() async -> String?)? = nil
    var isBusyInConsole: () -> Bool = { false }
    var queueWhenIdle: ((Agent, String) -> Void)? = nil
    var clearQueued: (() -> Void)? = nil
    var hasQueuedRename: () -> Bool = { false }
    var shouldSuppressBusyNotice: () -> Bool = { false }
    var setSuppressBusyNotice: (Bool) -> Void = { _ in }
    var onWillDispatch: () -> Void = {}
    var waitForSendableScreen: Bool = false
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

    struct DeferredSaveConfirmation: Equatable {
        let agent: Agent
        let title: String
    }

    let program: ChatProgram
    var input: String
    private(set) var state: State = .editing
    private(set) var deferredSaveConfirmation: DeferredSaveConfirmation?

    private let expected: Agent
    private let io: AgentTitleRenameIO
    private var initialInput: String
    /// A timeout or interrupted write requires reopening and checking the terminal.
    private(set) var outcomeUncertain = false
    private var dispatched = false

    init(agent: Agent, program: ChatProgram, io: AgentTitleRenameIO) {
        expected = agent
        self.program = program
        self.io = io
        let seeded = AgentTitleNaming.title(of: agent, program: program)
        input = seeded
        initialInput = seeded
    }

    var isBusy: Bool { state == .saving || state == .generating }
    var hasQueuedRename: Bool { io.hasQueuedRename() }
    var canSave: Bool {
        !isBusy && deferredSaveConfirmation == nil && !outcomeUncertain
            && AgentTitleNaming.validation(input) == nil
    }
    var canGenerate: Bool {
        !isBusy && deferredSaveConfirmation == nil && !outcomeUncertain
            && AgentTitleNaming.supportsGeneration(program)
    }
    var generationUnavailable: String? {
        AgentTitleNaming.supportsGeneration(program) ? nil
            : String(localized: "Automatic title generation isn't available for \(program.chatName) here.")
    }

    /// Refreshes the seeded title when the sheet opens unless the user already edited,
    /// started saving, or already has a pending title queued on this device.
    func refreshInitialTitle() async {
        guard state == .editing, !dispatched, !io.hasQueuedRename(), input == initialInput,
            let refreshed = await io.initialTitle?()
        else { return }
        guard state == .editing, !dispatched, !io.hasQueuedRename(), input == initialInput else { return }
        input = refreshed
        initialInput = refreshed
    }

    func save() async {
        guard canSave else { return }
        await perform(generating: false)
    }

    func generate() async {
        guard canGenerate else { return }
        await perform(generating: true)
    }

    func confirmDeferredSave(
        _ confirmation: DeferredSaveConfirmation? = nil, suppressNextTime: Bool
    ) {
        guard let pending = confirmation ?? deferredSaveConfirmation else { return }
        if suppressNextTime {
            io.setSuppressBusyNotice(true)
        }
        deferredSaveConfirmation = nil
        io.queueWhenIdle?(pending.agent, pending.title)
        state = .renamed
    }

    func cancelDeferredSave() {
        deferredSaveConfirmation = nil
    }

    private func perform(generating: Bool) async {
        guard io.acquire() else {
            state = .failed(String(localized: "A rename is already in progress for this Agent."))
            return
        }
        state = generating ? .generating : .saving
        dispatched = false
        defer { io.release() }
        do {
            let initial = try await checkedAgent()
            let target = input.trimmingCharacters(in: .whitespacesAndNewlines)
            var resultTarget: String? = generating ? nil : target
            if !generating, AgentTitleNaming.matches(initial, program: program, title: target) {
                io.clearQueued?()
                state = .renamed
                return
            }
            let agentIsRunning =
                initial.status == .working || initial.status == .blocked || io.isBusyInConsole()
            if !generating, agentIsRunning, let queueWhenIdle = io.queueWhenIdle {
                if io.shouldSuppressBusyNotice() {
                    queueWhenIdle(initial, target)
                    state = .renamed
                } else {
                    deferredSaveConfirmation = DeferredSaveConfirmation(agent: initial, title: target)
                    state = .editing
                }
                return
            }
            guard (initial.status == .idle || initial.status == .done) && !io.isBusyInConsole() else {
                throw failure(String(localized: "Wait until the Agent is idle before renaming."))
            }
            guard initial.agentSession != nil else {
                throw failure(String(localized: "The Agent hasn't reported its conversation. Open Chat and check its session before renaming."))
            }
            let screen = try await readyScreen(session: initial.agentSession)
            if program == .opencode {
                try await renameOpenCode(target, initial: initial)
            } else {
                let command = program == .pi ? "/name" : "/rename"
                _ = try await checkedAgent(session: initial.agentSession, idle: true)
                guard InputBoxStateDetector.detect(try await io.screen(), program: program).isSendable else {
                    throw failure(String(localized: "The Agent's input changed. Nothing was sent."))
                }
                io.onWillDispatch()
                io.clearQueued?()
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
                ?? String(localized: "The Host did not confirm the rename.")
            state = .failed(outcomeUncertain
                ? String(localized: "\(reason) Check the title in Terminal before trying again.")
                : reason)
            if dispatched { await io.refresh() }
        }
    }

    private func readyScreen(session: AgentSessionInfo?) async throws -> ANSIScreen {
        var screen = try await io.screen()
        if InputBoxStateDetector.detect(screen, program: program).isSendable {
            return screen
        }
        if io.waitForSendableScreen {
            for _ in 0..<6 {
                try await io.sleep(.milliseconds(250))
                _ = try await checkedAgent(session: session, idle: true)
                screen = try await io.screen()
                if InputBoxStateDetector.detect(screen, program: program).isSendable {
                    return screen
                }
            }
        }
        throw failure(String(localized: "The Agent's input is not empty or ready. Finish the draft or dialog in Terminal first."))
    }

    private func checkedAgent(session: AgentSessionInfo? = nil, idle: Bool = false) async throws -> Agent {
        try Task.checkCancellation()
        let fresh = try await io.agent()
        guard fresh.terminalID == expected.terminalID, fresh.paneID == expected.paneID,
            fresh.kind == expected.kind, fresh.workspaceID == expected.workspaceID,
            fresh.tabID == expected.tabID,
            expected.agentSession == nil || fresh.agentSession == expected.agentSession,
            session == nil || fresh.agentSession == session else {
            throw failure(String(localized: "The Agent or conversation changed. Reopen Rename for the current conversation."))
        }
        if idle, (fresh.status != .idle && fresh.status != .done) || io.isBusyInConsole() {
            throw failure(String(localized: "The Agent is no longer idle."))
        }
        return fresh
    }

    private func renameOpenCode(_ title: String, initial: Agent) async throws {
        _ = try await checkedAgent(session: initial.agentSession, idle: true)
        io.onWillDispatch()
        io.clearQueued?()
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
            throw failure(String(localized: "OpenCode did not show the expected Rename session dialog."))
        }
        _ = try await checkedAgent(session: initial.agentSession)
        guard Self.openCodeField(try await io.screen()) == field else {
            throw failure(String(localized: "OpenCode's rename dialog changed."))
        }
        try await io.keys(["ctrl+e", "ctrl+u"])
        try await io.sleep(.milliseconds(150))
        _ = try await checkedAgent(session: initial.agentSession)
        guard Self.openCodeField(try await io.screen()) == "" else {
            throw failure(String(localized: "OpenCode's title field could not be cleared."))
        }
        try await io.paste(title)
        try await io.sleep(.milliseconds(150))
        _ = try await checkedAgent(session: initial.agentSession)
        guard Self.openCodeField(try await io.screen()) == title else {
            throw failure(String(localized: "OpenCode did not receive the complete title."))
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
                throw failure(String(localized: "Codex's title suggestion changed before confirmation."))
            }
            try await io.keys(["enter"])
            return suggestion
        }
        throw failure(String(localized: "Codex did not produce a title suggestion in time."))
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
            if (target == nil || program == .agy), fresh.status == .idle || fresh.status == .done,
                let acknowledgement = Self.nativeAcknowledgement(program: program, title: target ?? fresh.title),
                Self.acknowledgementCount(acknowledgement, program: program, in: text)
                    > Self.acknowledgementCount(acknowledgement, program: program, in: oldText) {
                // Generating again can legitimately produce the current title, and
                // Antigravity CLI confirms a rename on screen without setting a
                // terminal title by default.
                return
            }
            if ["Could not generate a session title", "Rename failed:", "Failed to rename conversation:"].contains(where: {
                text.contains($0) && !oldText.contains($0)
            }) {
                throw AgentTitleRenameError(message: String(localized: "The Agent could not generate or save the title."), confirmedFailure: true)
            }
        }
        throw failure(String(localized: "The Agent did not confirm the new title in time."))
    }

    /// The line the Agent's own TUI prints after a rename. It is matched
    /// against screen text, so it stays in the Agent's language, never the app's.
    static func nativeAcknowledgement(program: ChatProgram, title: String) -> String? {
        switch program {
        case .claude:
            return "Session renamed to: " + title
        case .omp:
            let card = title.hasPrefix("π > ") ? String(title.dropFirst(4)) : title
            return "Session renamed to \"" + card + "\"."
        case .agy:
            return "Conversation renamed to: " + title
        default: return nil
        }
    }

    static func acknowledgementCount(
        _ acknowledgement: String, program: ChatProgram = .claude, in text: String
    ) -> Int {
        let rows = text.components(separatedBy: "\n")
        var count = 0
        var index = 0
        while index < rows.count {
            let trimmed = rows[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(acknowledgement) {
                count += 1
                index += 1
                continue
            }
            if program == .agy, acknowledgement.hasPrefix("Conversation renamed to: "),
                let head = agyAcknowledgementStart(of: trimmed)
            {
                var candidates: Set<String> = [head]
                var matchedOffset: Int?
                for offset in 1...4 {
                    let nextIndex = index + offset
                    guard nextIndex < rows.count else { break }
                    let rawNext = rows[nextIndex]
                    guard rawNext.hasPrefix("  ") else { break }
                    let nextTrimmed = rawNext.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty,
                        !["⎿", "●", "⏺", "❯", ">", "─"].contains(where: nextTrimmed.hasPrefix)
                    else { break }
                    candidates = Set(candidates.flatMap { [$0 + nextTrimmed, $0 + " " + nextTrimmed] })
                    if candidates.contains(acknowledgement) {
                        matchedOffset = offset
                        break
                    }
                }
                if let matchedOffset {
                    count += 1
                    index += matchedOffset + 1
                    continue
                }
            }
            index += 1
        }
        return count
    }

    private static func agyAcknowledgementStart(of trimmedLine: String) -> String? {
        var text = trimmedLine
        if text.hasPrefix("⎿") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text.hasPrefix("Conversation renamed to: ") ? text : nil
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
