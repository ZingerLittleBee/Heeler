import Foundation
import SwiftUI
import Testing
import UIKit

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
        await store.load()
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
        #expect(cards[2] == .unread(accountID: "c41d07b9", account: "work", reason: "Directory not found"))
        #expect(AgentUsageProgramTitle.title(program: "claude", account: "claude-2") == "Claude Code · claude-2")
        #expect(AgentUsageProgramTitle.title(program: "codex", account: nil) == "Codex")
    }

    @Test func limitsOffLeaveOnlyTheToggleCard() throws {
        let cards = AgentUsageLimitsCard.cards(for: try report(limits: false))
        #expect(cards.map(\.id) == ["claude.toggle", "codex"])
        #expect(cards[0].carriesToggle)
    }

    /// With one Account the limits sheet looks as it did before Accounts:
    /// Claude Code's card ends with its toggle.
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
        let several = AgentUsageLimitsCard.cards(for: try report())
        #expect(several.map(\.sectionID) == several.map(\.id))
        for report in [lone, older] {
            let cards = AgentUsageLimitsCard.cards(for: report)
            #expect(cards.map(\.id) == ["claude", "codex"])
            #expect(cards.map(\.carriesToggle) == [true, false])
            #expect(cards.map(\.sectionID) == ["claude.toggle", "codex"])
            guard case .limits(_, _, let name, let limits) = cards[0] else {
                Issue.record("Expected Claude Code's windows, not \(cards[0])")
                continue
            }
            #expect(name == nil)
            #expect(limits == report.claudeProgram?.usageLimits)
        }
    }

    // MARK: Rendering

    @Test func theAccountsScreenListsEachHarnesssAccountsAndSuggestions() async throws {
        let (store, usage) = await accounts(try report())
        let labels = try await renderedLabels(HostAccountsView(hostName: "studio", store: store, usage: usage)) {
            labels in labels.contains { $0.contains("Add Accounts for Another Harness") }
        }
        for expected in [
            "Claude Code", "Codex", "Default", "claude-2", "work", "Directory not found", "/Volumes/x/.claude",
            "Used by a running Agent", "In your home folder", "Add claude-work", "Ignore claude-work",
            "Choose a Folder…", "Folder Variable", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
            "Add Accounts for Another Harness",
        ] {
            #expect(labels.contains { $0.contains(expected) }, "Missing \(expected) in \(labels.sorted())")
        }
        #expect(!labels.contains(AccountsListing.fullFooter))
    }

    /// A change that failed after an earlier Accounts screen closed is not
    /// shown when the next one opens.
    @Test func aFailureFromAClosedScreenIsDropped() async throws {
        let (store, usage) = await accounts(try report())
        store.changeFailure = .init(message: "Heeler could not save this Host’s Accounts. Try again.")
        _ = try await renderedLabels(HostAccountsView(hostName: "studio", store: store, usage: usage)) { _ in
            store.changeFailure == nil
        }
        #expect(store.changeFailure == nil)
    }

    /// The Limits sheet names each Account; Accounts themselves are
    /// changed in Settings › Agents & Accounts, not here.
    @Test func theLimitsSheetNamesEachAccount() async throws {
        let name = "claude-accounts-limits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let report = try report()
        let store = AgentUsageStore(hostID: UUID(), defaults: defaults) { _, _ in .available(report) }
        store.claudeLimitsEnabled = true
        await store.refresh()
        let sheet = AgentUsageLimitsSheet(entries: [
            AgentUsageHostEntry(id: UUID(), name: "studio", store: store, isConnected: true),
        ])
        let labels = try await renderedLabels(sheet) { $0.contains { $0.hasPrefix("Claude Code limits") } }
        #expect(!labels.contains { $0.hasPrefix("Claude Code Accounts") })
        for expected in [
            "Claude Code · Default", "Claude Code · claude-2", "Claude Code · work", "Directory not found",
            "Claude Code limits",
        ] {
            #expect(labels.contains { $0.contains(expected) }, "Missing \(expected) in \(labels.sorted())")
        }
    }

    /// The accessibility labels `view` shows on an iPhone-sized window once
    /// `ready` holds, or when the wait runs out.
    private func renderedLabels(
        _ view: some View, until ready: (Set<String>) -> Bool
    ) async throws -> Set<String> {
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 1_800), rootViewController: controller)
        defer { window.isHidden = true }
        var labels: Set<String> = []
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft {
            controller.view.layoutIfNeeded()
            labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
            if ready(labels) { break }
            try await Task.sleep(for: .milliseconds(50))
            budget.charge()
        }
        return labels
    }
}
