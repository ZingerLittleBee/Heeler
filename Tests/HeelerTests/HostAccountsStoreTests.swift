import Foundation
import Testing

@testable import Heeler

/// One Host's Accounts for every harness (#621): the Account file is the
/// list, Usage's report adds suggestions and each Account's state for the
/// harnesses it reads.
@MainActor
@Suite("Host Accounts store", .timeLimit(.minutes(1)))
struct HostAccountsStoreTests {
    /// A Host on plugin 0.8.0 whose Usage report is the shared vector: the
    /// Default Account at /Users/u/.claude, claude-2, a missing `work`, and
    /// two suggestions.
    private func readyStore(
        report: AgentUsageReport? = nil, withUsage: Bool = true, defaults: UserDefaults = .standard,
        matchingFile: Bool = false
    ) async throws -> (HostAccountsStore, AgentUsageStore, ScriptedTransport) {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.8.0")))
        await transport.setAgentUsage(.success(try report ?? AgentUsageFixture.report()))
        if matchingFile {
            // The Account file the vector's Accounts come from.
            await transport.setUsageAccountFile(Data(#"""
                {"version": 1, "claude": {"defaultName": null, "accounts": [
                  {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"},
                  {"id": "c41d07b9", "directory": "/Volumes/x/.claude", "name": "work"}], "ignored": []}}
                """#.utf8))
        }
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let usage = AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults)
        if withUsage { await usage.refresh() }
        let accounts = HostAccountsStore(hostID: hostID, transports: provider, usage: { withUsage ? usage : nil })
        await accounts.load()
        return (accounts, usage, transport)
    }

    private func suggestion(_ store: HostAccountsStore, _ name: String, for kind: SupportedAgentKind = .claude)
        throws -> AgentUsageReport.AccountSuggestion
    {
        try #require(store.suggestions(for: kind).first { $0.name == name })
    }

    private func account(_ store: HostAccountsStore, _ name: String, for kind: SupportedAgentKind = .claude)
        throws -> HostAccountsStore.Row
    {
        try #require(store.rows(for: kind).first { $0.displayName == name })
    }

    private func savedFile(_ transport: ScriptedTransport) async throws -> UsageAccountFile {
        let data: Data = try #require(await transport.usageAccountFile)
        return try UsageAccountFile.decode(data)
    }

    // MARK: Listing

    @Test func usagesReportGivesClaudeCodesRowsAndSuggestions() async throws {
        let (store, _, _) = try await readyStore(matchingFile: true)
        #expect(store.rows(for: .claude).map(\.displayName) == ["Default", "claude-2", "work"])
        #expect(store.rows(for: .claude).first?.directory == "/Users/u/.claude")
        #expect(store.rows(for: .claude).last?.state == .missing)
        #expect(store.suggestions(for: .claude).map(\.name) == ["claude-work", "claude-personal"])
    }

    /// A harness Usage does not read lists the file's Accounts after its
    /// own Default Account, whose directory the harness decides.
    @Test func aHarnessUsageDoesNotReadListsTheFilesAccounts() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": []}, "programs": {"amp": {"variable": "AMP_HOME",
              "accounts": [{"id": "a1b2c3d4", "directory": "/Users/u/.amp-work", "name": "Work"}]}}}
            """#.utf8))
        await store.load()
        #expect(store.rows(for: .amp).map(\.displayName) == ["Default", "Work"])
        #expect(store.rows(for: .amp).first?.directory == nil)
        #expect(store.rows(for: .amp).last?.directory == "/Users/u/.amp-work")
        #expect(store.suggestions(for: .amp).isEmpty)
        #expect(store.variable(for: .amp) == "AMP_HOME")
        // Harnesses with Accounts come after the ones Usage reads.
        #expect(store.shownKinds == [.claude, .codex, .amp])
    }

    /// The Host's file is the list: another device's rename, addition or
    /// removal shows on the next load, Usage adding only each Account's
    /// state and the Default Account's folder.
    @Test func theLoadedFileOutranksUsagesListOfAccounts() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "Renamed"},
              {"id": "aaaaaaaa", "directory": "/Users/u/.claude-work", "name": "claude-work"}]}}
            """#.utf8))
        await store.load()
        let rows = store.rows(for: .claude)
        #expect(rows.map(\.displayName) == ["Default", "Renamed", "claude-work"])
        #expect(rows.map(\.state) == [.ok, .ok, nil])
        #expect(rows.first?.directory == "/Users/u/.claude")
        // A suggestion the file now lists is no longer offered.
        #expect(store.suggestions(for: .claude).map(\.name) == ["claude-personal"])
    }

    /// A saved rename shows even when the Usage read after it fails and
    /// Usage keeps its earlier report.
    @Test func aSavedChangeShowsWhenUsagesReadFails() async throws {
        let (store, usage, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"}]}}
            """#.utf8))
        await store.load()
        await transport.setAgentUsage(.failure(TransportError.sshUnreachable(detail: "gone")))
        #expect(await store.rename(try account(store, "claude-2"), to: "Max", for: .claude))
        #expect(usage.refreshFailure != nil)
        #expect(store.rows(for: .claude).map(\.displayName) == ["Default", "Max"])
        #expect(store.pendingChanges.isEmpty)
    }

    // MARK: Changes

    @Test func addingASuggestionSavesTheFileThenReadsUsageAgain() async throws {
        let (store, usage, transport) = try await readyStore()
        #expect(await store.add(try suggestion(store, "claude-work"), for: .claude))
        let file = try await savedFile(transport)
        #expect(file.accounts.map(\.directory) == ["/Users/u/.claude-work"])
        #expect(file.accounts.map(\.name) == ["claude-work"])
        #expect(await transport.replacedUsageAccountFiles.count == 1)
        #expect(await transport.agentUsageReads == 2)
        #expect(store.pendingChanges.isEmpty)
        #expect(store.changeFailure == nil)
        #expect(!usage.isLoading)
    }

    @Test func theRowWaitsForTheUsageReadAfterItsChange() async throws {
        let (store, usage, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(gate)
        let adding = Task { await store.add(work, for: .claude) }
        await gate.waitForEntry()
        #expect(await transport.replacedUsageAccountFiles.count == 1)
        #expect(store.isChanging(.directory(.claude, work.directory)))
        #expect(usage.isLoading)
        await gate.open()
        #expect(await adding.value)
        #expect(!store.isChanging(.directory(.claude, work.directory)))
    }

    /// A newer read can replace the one after a change; the row keeps its
    /// spinner until a read started after its write lands.
    @Test func aChangeWaitsForAReadStartedAfterItsWrite() async throws {
        let (store, _, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let personal = try suggestion(store, "claude-personal")
        let first = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(first)
        let addingWork = Task { await store.add(work, for: .claude) }
        await first.waitForEntry()
        let second = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(second)
        let addingPersonal = Task { await store.add(personal, for: .claude) }
        await second.waitForEntry()
        await first.open()
        var budget = PollBudget(.milliseconds(300))
        while budget.hasTimeLeft, store.isChanging(.directory(.claude, work.directory)) {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        #expect(store.isChanging(.directory(.claude, work.directory)))
        await second.open()
        #expect(await addingWork.value)
        #expect(await addingPersonal.value)
        #expect(store.pendingChanges.isEmpty)
        #expect(await transport.agentUsageReads == 3)
    }

    /// Turning Claude Code limits on drops the read after a change; the
    /// change reads again rather than leave its row spinning.
    @Test func aChangeWhoseReadWasDroppedReadsAgain() async throws {
        let name = "host-accounts-dropped-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, usage, transport) = try await readyStore(defaults: defaults)
        let work = try suggestion(store, "claude-work")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(gate)
        let adding = Task { await store.add(work, for: .claude) }
        await gate.waitForEntry()
        usage.claudeLimitsEnabled.toggle()
        await gate.open()
        #expect(await adding.value)
        #expect(store.pendingChanges.isEmpty)
        #expect(await transport.agentUsageReads == 3)
    }

    @Test func aChangeToARowStillSavingIsRefused() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"}]}}
            """#.utf8))
        await store.load()
        let claude2 = try account(store, "claude-2")
        let renameRead = ScriptedTransportCallGate()
        await transport.gateNextAgentUsageRead(renameRead)
        let renaming = Task { await store.rename(claude2, to: "Max", for: .claude) }
        await renameRead.waitForEntry()
        #expect(await store.remove(claude2, for: .claude) == false)
        #expect(store.changeFailure?.message == AgentAccountError.busy.message)
        await renameRead.open()
        #expect(await renaming.value)
        #expect(try await savedFile(transport).accounts.map(\.name) == ["Max"])
    }

    @Test func renamingAndRemovingEditTheFileTheHostHolds() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"defaultName": null, "accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"},
              {"id": "c41d07b9", "directory": "/Volumes/x/.claude", "name": "work"}], "ignored": []}}
            """#.utf8))
        await store.load()
        #expect(await store.rename(try account(store, "Default"), to: "Personal", for: .claude))
        #expect(try await savedFile(transport).defaultName == "Personal")
        #expect(await store.rename(try account(store, "claude-2"), to: "Max", for: .claude))
        #expect(try await savedFile(transport).accounts.map(\.name) == ["Max", "work"])
        #expect(await store.remove(try account(store, "work"), for: .claude))
        #expect(try await savedFile(transport).accounts.map(\.id) == ["7f3c9a2e"])
        #expect(try await savedFile(transport).ignored == ["/Volumes/x/.claude"])
        // The Default Account, renamed from the file at once, is never removed.
        #expect(await store.remove(try account(store, "Personal"), for: .claude) == false)
        #expect(await transport.replacedUsageAccountFiles.count == 3)
    }

    @Test func aRefusedRenameSaysWhyAndWritesNothing() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "7f3c9a2e", "directory": "/Users/u/.claude-2", "name": "claude-2"}]}}
            """#.utf8))
        await store.load()
        #expect(await store.rename(try account(store, "claude-2"), to: "Default", for: .claude) == false)
        #expect(store.changeFailure?.message == "Another Account on this Host is named Default.")
        #expect(await transport.replacedUsageAccountFiles.isEmpty)
    }

    @Test func ignoringASuggestionAddsItToTheIgnoredList() async throws {
        let (store, _, transport) = try await readyStore()
        #expect(await store.ignore(try suggestion(store, "claude-personal"), for: .claude))
        let file = try await savedFile(transport)
        #expect(file.ignored == ["/Users/u/.claude-personal"])
        #expect(file.accounts.isEmpty)
    }

    @Test func aFailedWriteKeepsTheListAndReportsWhy() async throws {
        let (store, _, transport) = try await readyStore()
        let before = store.rows(for: .claude)
        await transport.setUsageAccountFileWriteFailure(
            NotificationRegistrationError.writeFailed(detail: "rename failed"))
        #expect(await store.add(try suggestion(store, "claude-work"), for: .claude) == false)
        #expect(store.changeFailure?.message == "Heeler could not save this Host’s Accounts. Try again.")
        #expect(store.rows(for: .claude) == before)
        #expect(store.pendingChanges.isEmpty)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func aNewerAppsFileIsLeftAlone() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setUsageAccountFile(Data(#"{"version": 2, "claude": {}}"#.utf8))
        #expect(await store.add(try suggestion(store, "claude-work"), for: .claude) == false)
        #expect(
            store.changeFailure?.message
                == "A newer version of Heeler saved this Host’s Accounts. Update Heeler to change them.")
        #expect(await transport.replacedUsageAccountFiles.isEmpty)
    }

    /// Two quick Adds each read the file the other wrote, so neither is lost.
    @Test func changesTakeTurnsOnTheAccountFile() async throws {
        let (store, _, transport) = try await readyStore()
        let work = try suggestion(store, "claude-work")
        let personal = try suggestion(store, "claude-personal")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextUsageAccountFileWrite(gate)
        let first = Task { await store.add(work, for: .claude) }
        await gate.waitForEntry()
        let second = Task { await store.add(personal, for: .claude) }
        while !store.isChanging(.directory(.claude, personal.directory)) { await Task.yield() }
        await gate.open()
        #expect(await first.value)
        #expect(await second.value)
        #expect(try await savedFile(transport).accounts.map(\.name) == ["claude-work", "claude-personal"])
    }

    // MARK: Chosen directories

    @Test func aChosenDirectoryMustHoldTheHarnesssFiles() async throws {
        let (store, _, transport) = try await readyStore()
        await transport.setFileStatuses([
            "/srv/claude-a/.claude.json": RemoteFileStatus(kind: .regular, size: 120),
            "/srv/empty/projects": RemoteFileStatus(kind: .regular, size: 3),
            "/srv/codex-a/auth.json": RemoteFileStatus(kind: .regular, size: 12),
            "/srv/amp-a": RemoteFileStatus(kind: .directory, size: nil),
        ])
        #expect(await store.add(directory: "/srv/empty", for: .claude) == .refused(.notHarnessDirectory(.claude)))
        #expect(await store.add(directory: "/srv/claude-a", for: .claude) == .added)
        #expect(await store.add(directory: "/srv/claude-a", for: .claude) == .refused(.alreadyListed))
        // The Default Account's directory is listed already.
        #expect(await store.add(directory: "/Users/u/.claude", for: .claude) == .refused(.alreadyListed))
        #expect(await store.add(directory: "/srv/claude-a", for: .codex) == .refused(.notHarnessDirectory(.codex)))
        #expect(await store.add(directory: "/srv/codex-a", for: .codex) == .added)
        // A harness Heeler knows no files of needs only a directory.
        #expect(await store.add(directory: "/srv/amp-b", for: .amp) == .refused(.notHarnessDirectory(.amp)))
        #expect(await store.add(directory: "/srv/amp-a", for: .amp) == .added)
        let file = try await savedFile(transport)
        #expect(file.directories(for: .claude) == ["/srv/claude-a"])
        #expect(file.directories(for: .codex) == ["/srv/codex-a"])
        #expect(file.directories(for: .amp) == ["/srv/amp-a"])
    }

    /// A harness Usage does not read saves its Accounts without a Usage
    /// read, and with Usage off every harness does.
    @Test(arguments: [true, false])
    func aHarnessUsageDoesNotReadSavesWithoutReadingUsage(withUsage: Bool) async throws {
        let (store, _, transport) = try await readyStore(withUsage: withUsage)
        await transport.setFileStatuses(["/srv/grok-a/sessions": RemoteFileStatus(kind: .directory, size: nil)])
        let readsBefore = await transport.agentUsageReads
        #expect(await store.add(directory: "/srv/grok-a", for: .grok) == .added)
        #expect(await transport.agentUsageReads == readsBefore)
        #expect(store.rows(for: .grok).map(\.displayName) == ["Default", "grok-a"])
        #expect(store.pendingChanges.isEmpty)
    }

    @Test func aHarnessesVariableIsSavedOnTheHost() async throws {
        let (store, _, transport) = try await readyStore()
        #expect(store.variable(for: .codex) == "CODEX_HOME")
        #expect(store.variable(for: .amp) == nil)
        #expect(await store.setVariable("AMP_HOME", for: .amp))
        #expect(try await savedFile(transport).variable(for: .amp) == "AMP_HOME")
        #expect(store.variable(for: .amp) == "AMP_HOME")
        #expect(await store.setVariable("not valid", for: .amp) == false)
        #expect(store.changeFailure?.message == AgentAccountError.invalidVariable.message)
    }
}
