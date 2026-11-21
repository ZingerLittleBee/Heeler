import Foundation
import Testing

@testable import Heeler

/// The Accounts surfaces: the Usage notice, the Accounts screen's listing,
/// rename check and directories, and the Usage Limits cards each Claude
/// Code Account gets.
@MainActor
@Suite("Host Accounts screen", .serialized, .timeLimit(.minutes(1)))
struct HostAccountsViewTests {
    /// The shared vector with its Claude Code program edited by `edit`:
    /// the Default Account and claude-2 with their limits, a missing
    /// `work`, and two suggestions. `limits: false` answers as a query
    /// without `--claude-limits` does.
    private func report(
        limits: Bool = true, _ edit: (inout [String: Any]) throws -> Void = { _ in }
    ) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        if !limits {
            programs[0]["usageLimits"] = ["state": "disabled"]
            if var accounts = programs[0]["accounts"] as? [[String: Any]] {
                for index in accounts.indices where accounts[index]["usageLimits"] != nil {
                    accounts[index]["usageLimits"] = ["state": "disabled"]
                }
                programs[0]["accounts"] = accounts
            }
        }
        try edit(&programs[0])
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    /// The Accounts store over a Usage store showing `report`, with no
    /// connection of its own.
    private func accounts(_ report: AgentUsageReport) async -> (HostAccountsStore, AgentUsageStore) {
        let usage = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await usage.refresh()
        return (HostAccountsStore(hostID: UUID(), onHost: nil, usage: { usage }), usage)
    }

    private func row(_ store: HostAccountsStore, _ name: String) throws -> HostAccountsStore.Row {
        try #require(store.rows(for: .claude).first { $0.displayName == name })
    }

    // MARK: Notice

    @Test func theNoticeCountsSuggestionsOnAPluginWithAccounts() throws {
        let two = try report()
        #expect(AccountsListing.noticeTitle(state: .available(two), supportsAccounts: true) == "Found 2 Account folders")
        let one = try report { claude in
            claude["accountSuggestions"] = (claude["accountSuggestions"] as? [Any]).map { Array($0.prefix(1)) }
        }
        #expect(AccountsListing.noticeTitle(state: .available(one), supportsAccounts: true) == "Found 1 Account folder")
        let none = try report { $0["accountSuggestions"] = [Any]() }
        #expect(AccountsListing.noticeTitle(state: .available(none), supportsAccounts: true) == nil)
        #expect(AccountsListing.noticeTitle(state: .available(two), supportsAccounts: false) == nil)
        #expect(AccountsListing.noticeTitle(state: .loading, supportsAccounts: true) == nil)
    }

    // MARK: Listing

    @Test func aFourthAccountFillsTheHarness() async throws {
        let transport = ScriptedTransport()
        let hostID = UUID()
        await transport.setUsageAccountFile(Data(#"""
            {"version": 1, "claude": {"accounts": [
              {"id": "aaaaaaaa", "directory": "/u/.claude-1", "name": "one"},
              {"id": "bbbbbbbb", "directory": "/u/.claude-2", "name": "two"}]},
             "programs": {"codex": {"accounts": [
              {"id": "cccccccc", "directory": "/u/.codex-1", "name": "one"},
              {"id": "dddddddd", "directory": "/u/.codex-2", "name": "two"},
              {"id": "eeeeeeee", "directory": "/u/.codex-3", "name": "three"}]}}}
            """#.utf8))
        let store = HostAccountsStore(
            hostID: hostID, transports: ScriptedTransportProvider(transports: [hostID: transport]))
        try await store.load()
        #expect(!store.isFull(.claude))
        #expect(store.isFull(.codex))
        #expect(AccountsListing.fullFooter == "A harness can have up to four Accounts on a Host. Remove one to add another.")
    }

    @Test func rowsNameTheStateAndSourceAndShowTheHomeAsTilde() {
        #expect(AccountsListing.stateLine(.ok) == nil)
        #expect(AccountsListing.stateLine(nil) == nil)
        #expect(AccountsListing.stateLine(.missing) == "Directory not found")
        #expect(AccountsListing.stateLine(.duplicate) == "Same directory as another Account")
        #expect(AccountsListing.stateLine(.overLimit) == "Not counted")
        #expect(AccountsListing.sourceLine(.agent)?.text == "Used by a running Agent")
        #expect(AccountsListing.sourceLine(.home)?.symbol == "house")
        #expect(AccountsListing.sourceLine(.other("future")) == nil)
        #expect(AccountsListing.displayDirectory("/Users/u/.claude-2", home: "/Users/u") == "~/.claude-2")
        #expect(AccountsListing.displayDirectory("/Users/u", home: "/Users/u/") == "~")
        #expect(AccountsListing.displayDirectory("/Users/uv/.claude", home: "/Users/u") == "/Users/uv/.claude")
        #expect(AccountsListing.displayDirectory("/Volumes/x/.claude", home: nil) == "/Volumes/x/.claude")
        #expect(AccountsListing.displayDirectory("/srv/.claude", home: "/") == "/srv/.claude")
    }

    /// A harness Heeler knows no variable for says so under its Accounts.
    @Test func theFooterNamesTheVariableAnAccountSets() {
        #expect(AccountsListing.footer(for: .codex, variable: "CODEX_HOME").contains("sets CODEX_HOME to its folder"))
        #expect(AccountsListing.footer(for: .amp, variable: nil).contains("Name the variable Amp"))
    }

    @Test func renamingNamesTheAccountThatHasTheName() async throws {
        let (store, _) = await accounts(try report())
        let work = try row(store, "work")
        let defaultAccount = try row(store, "Default")
        let ordinary =
            "Names appear in Usage, widgets and Launch Presets. Each Account of a harness on studio needs its own."

        let taken = AccountsListing.renameCheck(
            " claude-2 ", for: work, hostName: "studio",
            isTaken: store.isNameTaken(" claude-2 ", renaming: work, for: .claude))
        #expect(taken.message == "Another Account on studio is named claude-2.")
        #expect(!taken.canSave)

        let free = AccountsListing.renameCheck(
            "archive", for: work, hostName: "studio",
            isTaken: store.isNameTaken("archive", renaming: work, for: .claude))
        #expect(free.message == ordinary)
        #expect(free.canSave)

        // An added Account needs a name; the Default Account's empty name
        // is "Default" again.
        #expect(!AccountsListing.renameCheck("  ", for: work, hostName: "studio", isTaken: false).canSave)
        #expect(AccountsListing.renameCheck("", for: defaultAccount, hostName: "studio", isTaken: false).canSave)
        let defaultTaken = AccountsListing.renameCheck("", for: defaultAccount, hostName: "studio", isTaken: true)
        #expect(defaultTaken.message == "Another Account on studio is named Default.")
        #expect(!defaultTaken.canSave)
        #expect(store.isNameTaken("claude-2", renaming: defaultAccount, for: .claude))
        #expect(!store.isNameTaken("", renaming: defaultAccount, for: .claude))
    }

    // MARK: Usage Limits cards

    @Test func eachAccountGetsACardBeforeTheToggleCard() throws {
        let cards = AgentUsageLimitsCard.cards(for: try report())
        #expect(cards.map(\.id)
            == ["claude.default", "claude.7f3c9a2e", "claude.c41d07b9", "claude.toggle", "codex"])
        // The toggle covers every Account, so it has a card of its own.
        #expect(cards.map(\.carriesToggle) == [false, false, false, true, false])
        guard case .limits(_, "claude", let name, let limits) = cards[1] else {
            Issue.record("Expected claude-2's windows, not \(cards[1])")
            return
        }
        #expect(name == "claude-2")
        #expect(limits.plan == "max")
        #expect(cards[2] == .unread(accountID: "c41d07b9", program: "claude", account: "work", reason: "Directory not found"))

        #expect(AgentUsageProgramTitle.title(program: "claude", account: "claude-2") == "Claude Code · claude-2")
        #expect(AgentUsageProgramTitle.title(program: "codex", account: nil) == "Codex")
    }

    /// Codex Accounts (plugin 0.9.0) get a card each before Codex's toggle
    /// card, like Claude Code's, and the Accounts screen lists them with
    /// Codex's suggestions.
    @Test func eachCodexAccountGetsACard() async throws {
        let report = try AgentUsageFixture.codexAccountsReport()
        let cards = AgentUsageLimitsCard.cards(for: report)
        let codexCards = cards.filter { $0.program == "codex" }
        #expect(codexCards.map(\.id) == ["codex.default", "codex.a1b2c3d4", "codex.toggle"])
        #expect(codexCards.map(\.carriesCodexToggle) == [false, false, true])
        #expect(codexCards.map(\.sectionID) == codexCards.map(\.id))
        guard case .limits("a1b2c3d4", "codex", "codex-work", let codexWork) = codexCards[1] else {
            Issue.record("Expected codex-work's card, not \(codexCards[1])")
            return
        }
        #expect(codexWork.state == "unavailable")
        #expect(AgentUsageProgramTitle.title(program: "codex", account: "codex-work") == "Codex · codex-work")
        #expect(AgentUsageLimitsCard.readings(for: report).filter { $0.program == "codex" }.count == 2)
        let (store, _) = await accounts(report)
        #expect(store.rows(for: .codex).map(\.displayName) == ["Default", "codex-work"])
        #expect(store.suggestions(for: .codex).map(\.name) == ["codex-personal"])
        #expect(AccountsListing.noticeTitle(state: .available(report), supportsAccounts: true) == "Found 3 Account folders")
    }

    @Test func limitsOffLeaveOnlyTheToggleCard() throws {
        let cards = AgentUsageLimitsCard.cards(for: try report(limits: false))
        #expect(cards.map(\.id) == ["claude.toggle", "codex"])
        #expect(cards[0].carriesToggle)
        #expect(cards[1].carriesCodexToggle)
        let bothOff = AgentUsageLimitsCard.cards(for: try report(limits: false).hidingCodexLimits())
        #expect(bothOff.map(\.id) == ["claude.toggle", "codex.toggle"])
        #expect(bothOff[1].carriesCodexToggle)
    }

    /// With one Account the limits sheet looks as it did before Accounts:
    /// each program's card ends with its toggle.
    @Test func aLoneDefaultAccountOrAnOlderPluginKeepsTheProgramsCard() throws {
        let lone = try report { claude in
            claude["accounts"] = (claude["accounts"] as? [Any]).map { Array($0.prefix(1)) }
        }
        let older = try report { claude in
            claude.removeValue(forKey: "accounts")
            claude.removeValue(forKey: "accountSuggestions")
        }
        // The toggle's section is the same one the toggle card has with
        // several Accounts, so the Accounts screen its link pushed stays
        // when a second Account is added or removed.
        let several = AgentUsageLimitsCard.cards(for: try report()).filter { $0.program == "claude" }
        #expect(several.map(\.sectionID) == several.map(\.id))
        for report in [lone, older] {
            let cards = AgentUsageLimitsCard.cards(for: report)
            #expect(cards.map(\.id) == ["claude", "codex"])
            #expect(cards.map(\.carriesToggle) == [true, false])
            #expect(cards.map(\.carriesCodexToggle) == [false, true])
            #expect(cards.map(\.sectionID) == ["claude.toggle", "codex.toggle"])
            guard case .limits(_, _, let name, let limits) = cards[0] else {
                Issue.record("Expected Claude Code's windows, not \(cards[0])")
                continue
            }
            #expect(name == nil)
            #expect(limits == report.claudeProgram?.usageLimits)
        }
    }
}
