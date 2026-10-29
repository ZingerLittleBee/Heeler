import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The Claude Code Accounts surfaces: the notice, the Accounts sheet's
/// listing, rename check and directories, and the Usage Limits cards each
/// Account gets.
@MainActor
@Suite("Claude Code Accounts sheet", .serialized, .timeLimit(.minutes(1)))
struct ClaudeAccountsSheetTests {
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

    private func account(_ report: AgentUsageReport, _ name: String) throws -> AgentUsageReport.Account {
        try #require(report.claudeProgram?.accounts?.first { $0.displayName == name })
    }

    // MARK: Notice

    @Test func theNoticeCountsSuggestionsOnAPluginWithAccounts() throws {
        let two = try report()
        #expect(ClaudeAccountsListing.noticeTitle(state: .available(two), supportsAccounts: true)
            == "Found 2 Claude Code directories")
        let one = try report { claude in
            claude["accountSuggestions"] = (claude["accountSuggestions"] as? [Any]).map { Array($0.prefix(1)) }
        }
        #expect(ClaudeAccountsListing.noticeTitle(state: .available(one), supportsAccounts: true)
            == "Found 1 Claude Code directory")
        let none = try report { $0["accountSuggestions"] = [Any]() }
        #expect(ClaudeAccountsListing.noticeTitle(state: .available(none), supportsAccounts: true) == nil)
        #expect(ClaudeAccountsListing.noticeTitle(state: .available(two), supportsAccounts: false) == nil)
        #expect(ClaudeAccountsListing.noticeTitle(state: .loading, supportsAccounts: true) == nil)
    }

    // MARK: Listing

    @Test func aFourthAccountFillsTheHost() throws {
        let three = ClaudeAccountsListing(report: try report())
        #expect(three.accounts.map(\.displayName) == ["Default", "claude-2", "work"])
        #expect(three.suggestions.map(\.name) == ["claude-work", "claude-personal"])
        #expect(!three.isFull)
        let four = ClaudeAccountsListing(report: try report { claude in
            var accounts = try #require(claude["accounts"] as? [[String: Any]])
            accounts.append([
                "id": "5e8a10d2", "isDefault": false, "name": "claude-team",
                "directory": "/Users/u/.claude-team", "state": "ok",
            ])
            claude["accounts"] = accounts
        })
        #expect(four.isFull)
        #expect(ClaudeAccountsListing.fullFooter
            == "A Host can have up to four Claude Code Accounts. Remove one to add another.")
    }

    @Test func rowsNameTheStateAndSourceAndShowTheHomeAsTilde() {
        #expect(ClaudeAccountsListing.stateLine(.ok) == nil)
        #expect(ClaudeAccountsListing.stateLine(.missing) == "Directory not found")
        #expect(ClaudeAccountsListing.stateLine(.duplicate) == "Same directory as another Account")
        #expect(ClaudeAccountsListing.stateLine(.overLimit) == "Not counted")
        #expect(ClaudeAccountsListing.sourceLine(.agent)?.text == "Used by a running Agent")
        #expect(ClaudeAccountsListing.sourceLine(.home)?.symbol == "house")
        #expect(ClaudeAccountsListing.sourceLine(.other("future")) == nil)
        #expect(ClaudeAccountsListing.displayDirectory("/Users/u/.claude-2", home: "/Users/u") == "~/.claude-2")
        #expect(ClaudeAccountsListing.displayDirectory("/Users/u", home: "/Users/u/") == "~")
        #expect(ClaudeAccountsListing.displayDirectory("/Users/uv/.claude", home: "/Users/u") == "/Users/uv/.claude")
        #expect(ClaudeAccountsListing.displayDirectory("/Volumes/x/.claude", home: nil) == "/Volumes/x/.claude")
        #expect(ClaudeAccountsListing.displayDirectory("/srv/.claude", home: "/") == "/srv/.claude")
    }

    @Test func renamingNamesTheAccountThatHasTheName() async throws {
        let report = try report()
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        let work = try account(report, "work")
        let defaultAccount = try account(report, "Default")
        let ordinary = "Names appear in Usage, Usage Limits and widgets. Each Account on studio needs its own."

        let taken = ClaudeAccountsListing.renameCheck(
            " claude-2 ", for: work, hostName: "studio",
            isTaken: store.isAccountNameTaken(" claude-2 ", renaming: work))
        #expect(taken.message == "Another Account on studio is named claude-2.")
        #expect(!taken.canSave)

        let free = ClaudeAccountsListing.renameCheck(
            "archive", for: work, hostName: "studio", isTaken: store.isAccountNameTaken("archive", renaming: work))
        #expect(free.message == ordinary)
        #expect(free.canSave)

        // An added Account needs a name; the Default Account's empty name
        // is "Default" again.
        #expect(!ClaudeAccountsListing.renameCheck("  ", for: work, hostName: "studio", isTaken: false).canSave)
        #expect(ClaudeAccountsListing.renameCheck("", for: defaultAccount, hostName: "studio", isTaken: false).canSave)
        let defaultTaken = ClaudeAccountsListing.renameCheck("", for: defaultAccount, hostName: "studio", isTaken: true)
        #expect(defaultTaken.message == "Another Account on studio is named Default.")
        #expect(!defaultTaken.canSave)
    }

    // MARK: Usage Limits cards

    @Test func eachAccountGetsACardBeforeTheToggleCard() throws {
        let cards = AgentUsageLimitsCard.cards(for: try report())
        #expect(cards.map(\.id)
            == ["claude.default", "claude.7f3c9a2e", "claude.c41d07b9", "claude.toggle", "codex"])
        guard case .limits(_, "claude", let name, let limits) = cards[1] else {
            Issue.record("Expected claude-2's windows, not \(cards[1])")
            return
        }
        #expect(name == "claude-2")
        #expect(limits.plan == "max")
        #expect(cards[2] == .unread(id: "claude.c41d07b9", account: "work", reason: "Directory not found"))
        #expect(AgentUsageProgramTitle.title(program: "claude", account: "claude-2") == "Claude Code · claude-2")
        #expect(AgentUsageProgramTitle.title(program: "codex", account: nil) == "Codex")
    }

    @Test func limitsOffLeaveOnlyTheToggleCard() throws {
        #expect(AgentUsageLimitsCard.cards(for: try report(limits: false)).map(\.id) == ["claude.toggle", "codex"])
    }

    @Test func aLoneDefaultAccountOrAnOlderPluginKeepsTheProgramsCard() throws {
        let lone = try report { claude in
            claude["accounts"] = (claude["accounts"] as? [Any]).map { Array($0.prefix(1)) }
        }
        let older = try report { claude in
            claude.removeValue(forKey: "accounts")
            claude.removeValue(forKey: "accountSuggestions")
        }
        for report in [lone, older] {
            let cards = AgentUsageLimitsCard.cards(for: report)
            #expect(cards.map(\.id) == ["claude", "claude.toggle", "codex"])
            guard case .limits(_, _, let name, let limits) = cards[0] else {
                Issue.record("Expected Claude Code's windows, not \(cards[0])")
                continue
            }
            #expect(name == nil)
            #expect(limits == report.claudeProgram?.usageLimits)
        }
    }

    // MARK: Rendering

    @Test func theAccountsSheetListsAccountsSuggestionsAndTheirNotes() async throws {
        let report = try report()
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        let labels = try await renderedLabels(ClaudeAccountsSheet(hostName: "studio", store: store)) { labels in
            labels.contains { $0.contains("Choose Another Directory…") }
        }
        for expected in [
            "Default", "claude-2", "work", "Directory not found", "/Volumes/x/.claude",
            ClaudeAccountsListing.accountsFooter, ClaudeAccountsListing.suggestionsFooter,
            "Used by a running Agent", "In your home folder", "Add claude-work", "Ignore claude-work",
            "Choose Another Directory…",
        ] {
            #expect(labels.contains { $0.contains(expected) }, "Missing \(expected) in \(labels.sorted())")
        }
        #expect(!labels.contains(ClaudeAccountsListing.fullFooter))
    }

    @Test func theLimitsSheetNamesEachAccountAndLeadsToThem() async throws {
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
        let labels = try await renderedLabels(sheet) { $0.contains { $0.hasPrefix("Claude Code Accounts") } }
        for expected in [
            "Claude Code · Default", "Claude Code · claude-2", "Claude Code · work", "Directory not found",
            "Claude Code limits", "Claude Code Accounts",
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
