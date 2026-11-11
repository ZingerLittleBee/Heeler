import Foundation
import Testing

@testable import Heeler

/// Values that are both shown and acted on stay stable tokens, and shown
/// text is built from whole sentences, so a translation never breaks a
/// comparison or reads as a fragment.
@MainActor
@Suite("Usage, widget, Changes and Terminal localization")
struct UsageMiscLocalizationTests {
    // MARK: Usage widget exclusions

    @Test(arguments: [
        AgentUsageExclusion.notConnected, .notReadYet, .usageOff, .needsPlugin, .unsupportedPlatform,
        .needsHostHelper, .updateHostHelper, .waitingForCore, .waitingForTmux, .repairHostHelper,
        .hostHelperNotOnWindows, .noAgentActivity, .updateRequired, .readFailed,
    ])
    func everyExclusionRoundTripsThroughItsToken(_ exclusion: AgentUsageExclusion) throws {
        let token = try #require(exclusion.token)
        #expect(AgentUsageExclusion(token: token) == exclusion)
        // The token is not the shown line, so a translation cannot change it.
        #expect(token != exclusion.reason)
    }

    @Test func snapshotsFromBeforeTheTokensKeepActingOnTheirReason() {
        #expect(AgentUsageExclusion(token: "Not connected") == .notConnected)
        #expect(AgentUsageExclusion(token: "Not read yet") == .notReadYet)
        #expect(AgentUsageExclusion(token: "Usage is off in Settings.") == .usageOff)
        // Any other written reason, or a token from a newer build, shows as written.
        let written = AgentUsageExclusion(token: "接続されていません")
        #expect(written == .written("接続されていません"))
        #expect(written.reason == "接続されていません")
        #expect(written.token == nil)
    }

    @Test func theSnapshotStoresTheTokenAndReadsAnOldReason() throws {
        let id = UUID()
        let host = UsageWidgetSnapshot.Host(
            id: id, name: "Lab", excludedReason: .notConnected, programs: [], limits: [])
        let encoded = try JSONEncoder().encode(host)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["excludedReason"] as? String == "notConnected")
        #expect(try JSONDecoder().decode(UsageWidgetSnapshot.Host.self, from: encoded) == host)

        let legacy = Data("""
            {"id":"\(id.uuidString)","name":"Lab","excludedReason":"Not connected","programs":[],"limits":[]}
            """.utf8)
        let decoded = try JSONDecoder().decode(UsageWidgetSnapshot.Host.self, from: legacy)
        #expect(decoded.excludedReason == .notConnected)
        #expect(!decoded.reports)

        let unknown = Data("""
            {"id":"\(id.uuidString)","name":"Lab","excludedReason":"someNewReason","programs":[],"limits":[]}
            """.utf8)
        #expect(
            try JSONDecoder().decode(UsageWidgetSnapshot.Host.self, from: unknown).excludedReason
                == .written("someNewReason"))
    }

    // MARK: Live Activity copy

    @Test func liveActivityCountsReadKnownStatusesAndKeepUnknownOnesAsSent() {
        #expect(AgentActivityCopy.count(2, status: "blocked") == "2 blocked")
        #expect(AgentActivityCopy.count(1, status: "done") == "1 done")
        #expect(AgentActivityCopy.count(3, status: "paused") == "3 paused")
        #expect(AgentActivityCopy.status("working") == "working")
        #expect(AgentActivityCopy.status("paused") == "paused")
    }

    // MARK: Changes

    @Test func lineCountsReadAsOneSentencePerSingularAndPluralPair() {
        #expect(LineCounts.lines(added: 1, removed: 1).accessibilityLabel == "1 line added, 1 line removed")
        #expect(LineCounts.lines(added: 1, removed: 2).accessibilityLabel == "1 line added, 2 lines removed")
        #expect(LineCounts.lines(added: 2, removed: 1).accessibilityLabel == "2 lines added, 1 line removed")
        #expect(LineCounts.binary.accessibilityLabel == "binary")
    }

    @Test func cappedTotalsSayMoreThanInOneSentence() {
        let incomplete = ChangesTotals(trackedFiles: 1, untrackedItems: 0, added: 3, removed: 0, linesAreComplete: false)
        #expect(incomplete.spokenLines == "At least 3 lines added, 0 lines removed")
        #expect(incomplete.spokenFiles(statusTruncated: true) == "more than 1 file changed")
        #expect(
            incomplete.accessibilitySummary(statusTruncated: true)
                == "more than 1 file changed. At least 3 lines added, 0 lines removed in tracked files. "
                + "untracked items not counted")

        let untracked = ChangesTotals(trackedFiles: 2, untrackedItems: 1)
        #expect(untracked.spokenFiles(statusTruncated: true) == "2 files changed")
        #expect(untracked.spokenUntracked(statusTruncated: true) == "more than 1 untracked item")
        #expect(untracked.spokenUntracked(statusTruncated: false) == "1 untracked item")
    }

    @Test func theListLimitNoticeNamesChangedFiles() {
        #expect(
            CheckoutChanges.limitNotice(shown: 2_000, total: 2_345, isLowerBound: false, noun: .changedFiles)
                == "Showing \(2_000.formatted()) of \(2_345.formatted()) changed files.")
        #expect(
            CheckoutChanges.limitNotice(shown: 2_000, total: 2_345, isLowerBound: true, noun: .changedFiles)
                == "Showing \(2_000.formatted()) of more than \(2_345.formatted()) changed files.")
    }

    @Test func upstreamAndDetachedHeadReadAsWholeSentences() {
        let upstream = CheckoutUpstream(name: "origin/main", state: .tracking(ahead: 1, behind: 3))
        #expect(upstream.accessibilitySummary == "1 commit ahead and 3 commits behind origin/main")
        let unknownCommit = CheckoutHead(branch: .detached, commit: nil, latestCommit: nil)
        #expect(unknownCommit.branchTitle == "Detached at unknown commit")
    }

    @Test func tideFileCountsSpeakTheirCountInOnePhrase() {
        let counts = TideGitItem.fileCounts(TideGitItemTests.changes(
            files: [
                TideGitItemTests.file("a.swift", kind: .conflicted, staging: nil),
                TideGitItemTests.file("b.swift", staging: .both),
            ],
            untracked: 2))
        #expect(counts.map(\.spokenCount) == ["1 conflicted", "1 staged", "1 modified", "2 untracked"])
    }

    @Test func aLineWithoutANumberStillNamesItsChange() {
        let line = DiffLine(id: 0, kind: .removed, oldNumber: nil, newNumber: nil, text: "old", missingNewline: true)
        #expect(line.accessibilityLabel == "Removed: old. No newline at end of file.")
    }

    @Test func aChangedPairDoesNotAddAFullStopAfterAJapaneseOne() {
        let removed = DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: "終わり。")
        let added = DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: "end")
        #expect(
            SideBySideRow(id: 0, left: removed, right: added).accessibilityLabel
                == "Removed, line 1: 終わり。 Added, line 1: end")
        let plain = DiffLine(id: 2, kind: .removed, oldNumber: 1, newNumber: nil, text: "old")
        #expect(
            SideBySideRow(id: 1, left: plain, right: added).accessibilityLabel
                == "Removed, line 1: old. Added, line 1: end")
    }

    // MARK: Terminal keys and Voice Input

    @Test func keyCapLegendsStayAsKeyboardsPrintThem() {
        #expect(AgentQuickKey.tab.title == "Tab")
        #expect(AgentQuickKey.home.title == "Home")
        #expect(AgentQuickKey.end.title == "End")
        #expect(AgentQuickKey.insert.title == "Insert")
        // VoiceOver names the End key through its own entry; English reads the same.
        #expect(AgentQuickKey.end.accessibilityLabel == "End")
        #expect(AgentQuickKey.escape.accessibilityLabel == "Escape")
    }

    @Test func speechServiceStatusFailuresKeepTheStatusInTheSentence() {
        #expect(
            VoiceTranscriptionError.rejected(status: 404, message: nil).message
                == "The speech service refused the recording (HTTP 404).")
        #expect(
            VoiceTranscriptionError.unavailable(status: 503, message: "Try later.").message
                == "The speech service is unavailable (HTTP 503). Try later.")
    }
}
