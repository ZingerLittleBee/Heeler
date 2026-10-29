import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Claude Code Accounts store", .timeLimit(.minutes(1)))
struct ClaudeAccountsStoreTests {
    /// A Host on plugin 0.8.0 whose report is the shared vector: the
    /// Default Account at /Users/u/.claude, claude-2, a missing `work`, and
    /// two suggestions.
    private func readyStore(
        plugin: String = "0.8.0", report: AgentUsageReport? = nil, defaults: UserDefaults = .standard
    ) async throws -> (AgentUsageStore, ScriptedTransport) {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: plugin)))
        await transport.setAgentUsage(.success(try report ?? AgentUsageFixture.report()))
        let store = AgentUsageStore(
            hostID: hostID, transports: ScriptedTransportProvider(transports: [hostID: transport]),
            defaults: defaults)
        await store.refresh()
        return (store, transport)
    }

    private func report(_ store: AgentUsageStore) throws -> AgentUsageReport {
        guard case .available(let report) = store.state else {
            Issue.record("Expected a report, not \(store.state)")
            throw CancellationError()
        }
        return report
    }

    private func suggestion(_ store: AgentUsageStore, _ name: String) throws -> AgentUsageReport.AccountSuggestion {
        try #require(try report(store).claudeProgram?.accountSuggestions?.first { $0.name == name })
    }

    private func account(_ store: AgentUsageStore, _ name: String) throws -> AgentUsageReport.Account {
        try #require(try report(store).claudeProgram?.accounts?.first { $0.displayName == name })
    }

    private func savedFile(_ transport: ScriptedTransport) async throws -> UsageAccountFile {
        let data: Data = try #require(await transport.usageAccountFile)
        return try UsageAccountFile.decode(data)
    }

    @Test func aPluginWithAccountsSupportsThem() async throws {
        let (store, _) = try await readyStore()
        #expect(store.pluginVersion == PluginVersion(0, 8, 0))
        #expect(store.supportsClaudeAccounts)
        #expect(store.claudeAccountsRequirement == nil)
        // A store that only reads learns it from the report.
        let report = try AgentUsageFixture.report()
        let readOnly = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await readOnly.refresh()
        #expect(readOnly.pluginVersion == nil)
        #expect(readOnly.supportsClaudeAccounts)
    }

    @Test func anOlderPluginNamesItsUpdateAndChangesNothing() async throws {
        let (store, transport) = try await readyStore(
            plugin: "0.7.1", report: try AgentUsageFixture.tokenReport(refreshing: false))
        let note = "Claude Code Accounts need plugin 0.8.0 or newer; this Host has 0.7.1."
        #expect(!store.supportsClaudeAccounts)
        #expect(store.claudeAccountsRequirement == note)
        let work = AgentUsageReport.AccountSuggestion(directory: "/Users/u/.claude-work", name: "claude-work", source: .agent)
        #expect(await store.addAccount(work) == false)
        #expect(store.accountChangeFailure?.message == note)
        #expect(await transport.usageAccountFileReads == 0)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func addingASuggestionSavesTheFileThenReadsUsageAgain() async throws {
        let (store, transport) = try await readyStore()
        #expect(await store.addAccount(try suggestion(store, "claude-work")))
        let file = try await savedFile(transport)
        #expect(file.accounts.map(\.directory) == ["/Users/u/.claude-work"])
        #expect(file.accounts.map(\.name) == ["claude-work"])
        #expect(await transport.replacedUsageAccountFiles.count == 1)
        #expect(await transport.agentUsageReads == 2)
        #expect(store.pendingAccountChanges.isEmpty)
        #expect(store.accountChangeFailure == nil)
    }

    @Test func theRowWaitsForTheReadAfterItsChange() async throws {
        let (store, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(gate)
        let adding = Task { await store.addAccount(work) }
        await gate.waitForEntry()
        #expect(await transport.replacedUsageAccountFiles.count == 1)
        #expect(store.isChangingAccount(.directory(work.directory)))
        #expect(store.isLoading)
        await gate.open()
        #expect(await adding.value)
        #expect(!store.isChangingAccount(.directory(work.directory)))
        #expect(!store.isLoading)
    }

    /// The read after a change replaces one already in flight, which may
    /// have started before the file changed.
    @Test func theReadAfterAChangeSupersedesAnEarlierRead() async throws {
        let (store, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let stale = try AgentUsageFixture.tokenReport(refreshing: false)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(gate)
        await transport.setAgentUsage(.success(stale))
        let refresh = Task { await store.refresh() }
        await gate.waitForEntry()
        let fresh = try AgentUsageFixture.report()
        await transport.setAgentUsage(.success(fresh))
        #expect(await store.addAccount(work))
        await gate.open()
        await refresh.value
        #expect(store.state == .available(fresh))
    }

    /// A newer read can replace the one after a change; the row keeps its
    /// spinner until a read started after its write lands, so its old
    /// state is never offered again in between.
    @Test func aChangeWaitsForAReadStartedAfterItsWrite() async throws {
        let (store, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let personal = try suggestion(store, "claude-personal")
        let first = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(first)
        let addingWork = Task { await store.addAccount(work) }
        await first.waitForEntry()
        let second = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(second)
        let addingPersonal = Task { await store.addAccount(personal) }
        await second.waitForEntry()
        // The first read lands after the second began, so it is dropped.
        await first.open()
        var budget = PollBudget(.milliseconds(300))
        while budget.hasTimeLeft, store.isChangingAccount(.directory(work.directory)) {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        #expect(store.isChangingAccount(.directory(work.directory)))
        await second.open()
        #expect(await addingWork.value)
        #expect(await addingPersonal.value)
        #expect(store.pendingAccountChanges.isEmpty)
        #expect(await transport.agentUsageReads == 3)
    }

    /// Turning Claude Code limits on drops the read after a change; the
    /// change reads again rather than leave its row stale or spinning.
    @Test func aChangeWhoseReadWasDroppedReadsAgain() async throws {
        let name = "claude-accounts-dropped-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, transport) = try await readyStore(defaults: defaults)
        let work = try suggestion(store, "claude-work")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(gate)
        let adding = Task { await store.addAccount(work) }
        await gate.waitForEntry()
        store.claudeLimitsEnabled.toggle()
        await gate.open()
        #expect(await adding.value)
        #expect(store.pendingAccountChanges.isEmpty)
        #expect(await transport.agentUsageReads == 3)
        #expect(await transport.agentUsageClaudeLimits.last == store.claudeLimitsEnabled)
    }

    /// A second change to a row that is still saving says why it did
    /// nothing, rather than reporting success.
    @Test func aChangeToARowStillSavingIsRefused() async throws {
        let (store, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"}]}}
            """#.utf8))
        let claude2 = try account(store, "claude-2")
        let renameRead = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(renameRead)
        let renaming = Task { await store.renameAccount(claude2, to: "Max") }
        await renameRead.waitForEntry()
        #expect(await store.removeAccount(claude2) == false)
        #expect(store.accountChangeFailure?.message == ClaudeAccountError.busy.message)
        await renameRead.open()
        #expect(await renaming.value)
        #expect(try await savedFile(transport).accounts.map(\.name) == ["Max"])

        // The browser shows the refusal in place.
        store.accountChangeFailure = nil
        let work = try suggestion(store, "claude-work")
        let addRead = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(addRead)
        let adding = Task { await store.addAccount(work) }
        await addRead.waitForEntry()
        #expect(await store.addAccount(directory: work.directory) == .refused(.busy))
        #expect(store.accountChangeFailure == nil)
        await addRead.open()
        #expect(await adding.value)
        #expect(await transport.replacedUsageAccountFiles.count == 2)
    }

    @Test func renamingAndRemovingEditTheFileTheHostHolds() async throws {
        let (store, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"defaultName": null, "accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"},
              {"id": "c41d07b9", "directory": "/Volumes/x/.claude", "name": "work"}], "ignored": []}}
            """#.utf8))
        #expect(await store.renameAccount(try account(store, "Default"), to: "Personal"))
        #expect(try await savedFile(transport).defaultName == "Personal")
        #expect(await store.renameAccount(try account(store, "claude-2"), to: "Max"))
        #expect(try await savedFile(transport).accounts.map(\.name) == ["Max", "work"])
        #expect(await store.removeAccount(try account(store, "work")))
        #expect(try await savedFile(transport).accounts.map(\.id) == ["7f3c9a2e"])
        #expect(try await savedFile(transport).ignored == ["/Volumes/x/.claude"])
        // The Default Account is never removed.
        #expect(await store.removeAccount(try account(store, "Default")) == false)
        #expect(await transport.replacedUsageAccountFiles.count == 3)
        #expect(await transport.agentUsageReads == 4)
    }

    @Test func aRefusedRenameSaysWhyAndWritesNothing() async throws {
        let (store, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"}]}}
            """#.utf8))
        #expect(await store.renameAccount(try account(store, "claude-2"), to: "Default") == false)
        #expect(store.accountChangeFailure?.message == "Another Account on this Host is named Default.")
        #expect(await transport.replacedUsageAccountFiles.isEmpty)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func ignoringASuggestionAddsItToTheIgnoredList() async throws {
        let (store, transport) = try await readyStore()
        #expect(await store.ignoreSuggestion(try suggestion(store, "claude-personal")))
        let file = try await savedFile(transport)
        #expect(file.ignored == ["/Users/u/.claude-personal"])
        #expect(file.accounts.isEmpty)
    }

    @Test func aFailedWriteKeepsTheListAndReportsWhy() async throws {
        let (store, transport) = try await readyStore()
        let before = store.state
        await transport.setUsageAccountFileWriteFailure(
            NotificationRegistrationError.writeFailed(detail: "rename failed"))
        #expect(await store.addAccount(try suggestion(store, "claude-work")) == false)
        #expect(store.accountChangeFailure?.message == "Heeler could not save this Host’s Accounts. Try again.")
        #expect(store.state == before)
        #expect(store.pendingAccountChanges.isEmpty)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func aNewerAppsFileIsLeftAlone() async throws {
        let (store, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"{"version": 2, "claude": {}}"#.utf8))
        #expect(await store.addAccount(try suggestion(store, "claude-work")) == false)
        #expect(
            store.accountChangeFailure?.message
                == "A newer version of Heeler saved this Host’s Accounts. Update Heeler to change them.")
        #expect(await transport.replacedUsageAccountFiles.isEmpty)
    }

    @Test func aChosenDirectoryMustHoldClaudeCodesFiles() async throws {
        let (store, transport) = try await readyStore()
        await transport.setFileStatuses([
            "/srv/claude-a/.claude.json": RemoteFileStatus(kind: .regular, size: 120),
            "/srv/claude-b/projects": RemoteFileStatus(kind: .directory, size: nil),
            "/srv/empty/projects": RemoteFileStatus(kind: .regular, size: 3),
            "/Users/u/.claude/.claude.json": RemoteFileStatus(kind: .regular, size: 120),
        ])
        #expect(await store.addAccount(directory: "/srv/empty") == .refused(.notClaudeDirectory))
        #expect(await transport.usageAccountFileReads == 0)
        #expect(await store.addAccount(directory: "/srv/claude-a") == .added)
        #expect(await store.addAccount(directory: "/srv/claude-b/") == .added)
        #expect(await store.addAccount(directory: "/srv/claude-a") == .refused(.alreadyListed))
        // The Default Account's directory is listed already.
        #expect(await store.addAccount(directory: "/Users/u/.claude") == .refused(.alreadyListed))
        #expect(store.accountChangeFailure == nil)
        #expect(try await savedFile(transport).accounts.map(\.name) == ["claude-a", "claude-b"])
        // A suggestion's directory is added as that suggestion.
        let checked = await transport.fileStatusPaths.count
        #expect(await store.addAccount(directory: "/Users/u/.claude-work") == .added)
        #expect(await transport.fileStatusPaths.count == checked)
        #expect(try await savedFile(transport).accounts.map(\.name) == ["claude-a", "claude-b", "claude-work"])
        // The Default Account and three more fill the Host.
        #expect(await store.addAccount(directory: "/srv/claude-b-2") == .refused(.notClaudeDirectory))
        await transport.setFileStatuses(["/srv/claude-c/projects": RemoteFileStatus(kind: .directory, size: nil)])
        #expect(await store.addAccount(directory: "/srv/claude-c") == .refused(.limitReached))
    }

    @Test func aChosenDirectoryTheHostCannotCheckIsAFailure() async throws {
        let (store, transport) = try await readyStore()
        #expect(await store.addAccount(directory: "/srv/claude-a") == .failed)
        #expect(
            store.accountChangeFailure?.message == "Claude Code Accounts are not available on this Host.")
        #expect(await transport.replacedUsageAccountFiles.isEmpty)
    }

    /// Two quick Adds each read the file the other wrote, so neither is lost.
    @Test func changesTakeTurnsOnTheAccountFile() async throws {
        let (store, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let personal = try suggestion(store, "claude-personal")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextUsageAccountFileWrite(gate)
        let first = Task { await store.addAccount(work) }
        await gate.waitForEntry()
        let second = Task { await store.addAccount(personal) }
        while !store.isChangingAccount(.directory(personal.directory)) { await Task.yield() }
        #expect(await transport.usageAccountFileReads == 1)
        await gate.open()
        #expect(await first.value)
        #expect(await second.value)
        #expect(try await savedFile(transport).accounts.map(\.name) == ["claude-work", "claude-personal"])
    }

    @Test func renameChecksNamesAgainstTheShownAccounts() async throws {
        let (store, _) = try await readyStore()
        let claude2 = try account(store, "claude-2")
        let defaultAccount = try account(store, "Default")
        #expect(store.isAccountNameTaken("work", renaming: claude2))
        #expect(store.isAccountNameTaken(" Default ", renaming: claude2))
        #expect(!store.isAccountNameTaken("claude-2", renaming: claude2))
        #expect(!store.isAccountNameTaken("Max", renaming: claude2))
        #expect(store.isAccountNameTaken("claude-2", renaming: defaultAccount))
        #expect(!store.isAccountNameTaken("", renaming: defaultAccount))
    }
}
