import Foundation
import Testing

@testable import Heeler

@Suite("GitProbe failure states")
struct GitProbeFailureStateTests {
    private static func parse(_ recording: (stdout: Data, stderr: Data)) throws -> CheckoutChangesRead {
        try GitProbe.parseChanges(
            stdout: recording.stdout, stderr: recording.stderr, nonce: GitProbeRecordings.nonce)
    }

    private static func failure(_ recording: (stdout: Data, stderr: Data)) -> ChangesReadError? {
        do {
            _ = try parse(recording)
            return nil
        } catch let error as ChangesReadError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    @Test(arguments: [
        "2.17.0", "2.17.1", "2.54.0 (Apple Git-157)", "2.45.2.windows.1",
        "2.43.0.vfs.0.0", "2.50.0.rc1", "3.0.0", "vendor-build",
    ])
    func supportedVersionsAndVendorSuffixesLoad(version: String) throws {
        let recording = GitProbeRecordings.failureReplacingSection(
            "version", in: GitProbeRecordings.clean, body: Data("git version \(version)\n".utf8))
        #expect(try Self.parse(recording).changes.isClean)
    }

    @Test(arguments: ["2.16.6", "2.11.0", "1.9.5", "2.16.6 (Apple Git-95)"])
    func oldVersionsWinOverLaterUnknownOptionErrors(version: String) {
        let recording = GitProbeRecordings.failureReplacingSection(
            "version", in: GitProbeRecordings.failureOldOptions,
            body: Data("git version \(version)\n".utf8))
        #expect(Self.failure(recording) == .gitTooOld(version))
    }

    @Test func gitMissingHasItsOwnState() {
        #expect(Self.failure(GitProbeRecordings.failureGitMissing) == .gitMissing)
    }

    @Test func developerToolsStubsAreGitMissing() {
        #expect(Self.failure(GitProbeRecordings.failureDeveloperToolsStub) == .gitMissing)
        #expect(Self.failure(GitProbeRecordings.failureInvalidDeveloperPath) == .gitMissing)
    }

    @Test func discoveryFailuresKeepTheirDistinctMeanings() {
        #expect(Self.failure(GitProbeRecordings.failureOutsideRepository) == .notAGitWorkingTree)
        #expect(Self.failure(GitProbeRecordings.failureBare) == .notAGitWorkingTree)
        #expect(Self.failure(GitProbeRecordings.gitdir) == .notAGitWorkingTree)
        #expect(Self.failure(GitProbeRecordings.failureOldEmptyTopLevel) == .notAGitWorkingTree)
        #expect(Self.failure(GitProbeRecordings.failureDirectoryMissing) == .directoryMissing)
        #expect(Self.failure(GitProbeRecordings.failureOwnership) == .notOwnedByAccount)
        #expect(Self.failure(GitProbeRecordings.failureLegacyOwnership) == .notOwnedByAccount)
        #expect(Self.failure(GitProbeRecordings.failureBadConfig)
            == .gitFailed("fatal: bad config line 1 in file .git/config"))
    }

    @Test func permissionDeniedDoesNotClaimTheDirectoryIsMissing() {
        let message = "fatal: cannot change to '/home/dev/private': Permission denied"
        let recording = GitProbeRecordings.failureReplacingSection(
            "discover", in: GitProbeRecordings.plain, status: 128,
            messages: "\n\(message)\nhint: more detail\n")
        #expect(Self.failure(recording) == .gitFailed(message))
    }

    @Test(arguments: [
        "No such file or directory", "detected dubious ownership", "not a git repository",
        "unsafe repository is owned by someone else",
        "xcode-select: No developer tools were found",
        "xcrun: invalid active developer path",
    ])
    func diagnosticWordsInsideAPathDoNotChangeTheFailure(path: String) {
        let message = "fatal: cannot change to '/home/dev/\(path)': Permission denied"
        let recording = GitProbeRecordings.failureReplacingSection(
            "discover", in: GitProbeRecordings.plain, status: 128, messages: message + "\n")
        #expect(Self.failure(recording) == .gitFailed(message))
    }

    @Test(arguments: ["discover", "status", "numstat", "head"])
    func laterCommandFailuresAreAlsoClassified(section: String) {
        let missing = GitProbeRecordings.failureReplacingSection(
            section, in: GitProbeRecordings.clean, status: 127,
            messages: "sh: git: not found\n")
        #expect(Self.failure(missing) == .gitMissing)
        let denied = GitProbeRecordings.failureReplacingSection(
            section, in: GitProbeRecordings.clean, status: 128,
            messages: "fatal: unable to read tree object\nhint: ignored second line\n")
        #expect(Self.failure(denied) == .gitFailed("fatal: unable to read tree object"))
    }

    @Test func missingStatusAfterSuccessfulDiscoveryIsIncomplete() {
        let marker = "__HEELER_GIT_F00D__"
        var recording = GitProbeRecordings.clean
        let begin = recording.stdout.range(of: Data("\n\(marker) status begin\n".utf8))!
        let end = recording.stdout.range(of: Data("\n\(marker) status rc=0\n".utf8))!
        recording.stdout.removeSubrange(begin.lowerBound..<end.upperBound)
        #expect(Self.failure(recording) == .incomplete)
    }

    @Test(arguments: ["version", "home", "discover", "status", "numstat", "head"])
    func everyFramedStatusIsRequired(section: String) {
        let stdout = String(decoding: GitProbeRecordings.clean.stdout, as: UTF8.self)
            .replacingOccurrences(of: "\n__HEELER_GIT_F00D__ \(section) rc=0\n", with: "\n")
        #expect(Self.failure((Data(stdout.utf8), GitProbeRecordings.clean.stderr)) == .incomplete)
    }

    @Test func theFinalMarkerIsRequiredEvenAfterSuccessfulCommands() {
        let stdout = String(decoding: GitProbeRecordings.clean.stdout, as: UTF8.self)
            .replacingOccurrences(of: "\n__HEELER_GIT_F00D__ done\n", with: "\n")
        #expect(Self.failure((Data(stdout.utf8), GitProbeRecordings.clean.stderr)) == .incomplete)
    }

    @Test func anEarlierGitErrorDoesNotHideAMissingLaterFramedStatus() {
        let failed = GitProbeRecordings.failureReplacingSection(
            "status", in: GitProbeRecordings.clean, status: 128,
            messages: "fatal: unable to read index\n")
        let stdout = String(decoding: failed.stdout, as: UTF8.self)
            .replacingOccurrences(of: "\n__HEELER_GIT_F00D__ head rc=0\n", with: "\n")
        #expect(Self.failure((Data(stdout.utf8), failed.stderr)) == .incomplete)
    }

    @Test func theDisplayLimitPreservesTheFullModelAndExactTotal() throws {
        let changes = try Self.parse(GitProbeRecordings.failureStatusWithFiles(2_345)).changes
        #expect(changes.files.count == 2_345)
        #expect(changes.listedFiles.count == 2_000)
        #expect(!changes.isStatusTruncated)
        #expect(changes.listedFiles.first?.id == changes.files.first?.id)
        #expect(changes.listedFiles.last?.id == changes.files[1_999].id)
        #expect(changes.listLimitNotice
            == "Showing \(2_000.formatted()) of \(2_345.formatted()) changed files.")
    }

    @Test(arguments: [0, 1, 2_000])
    func completeListsWithinTheLimitNeedNoNotice(count: Int) throws {
        let changes = try Self.parse(GitProbeRecordings.failureStatusWithFiles(count)).changes
        #expect(changes.listedFiles.count == count)
        #expect(changes.listLimitNotice == nil)
    }

    @Test(arguments: [Int32(0), 141, 269])
    func cappedStatusUsesLengthAndReportsALowerBound(status: Int32) throws {
        let changes = try Self.parse(
            GitProbeRecordings.failureStatusWithFiles(2_345, truncated: true, status: status)).changes
        #expect(changes.isStatusTruncated)
        #expect(changes.files.count == 2_345)
        #expect(changes.listedFiles.count == 2_000)
        #expect(changes.files.allSatisfy { !$0.displayPath.hasPrefix("partial-") })
        #expect(changes.listLimitNotice
            == "Showing \(2_000.formatted()) of more than \(2_345.formatted()) changed files.")
    }

    @Test func aTruncatedStatusWithNoCompleteFilesIsNotACleanCheckout() throws {
        let changes = try Self.parse(
            GitProbeRecordings.failureStatusWithFiles(0, truncated: true)).changes
        #expect(changes.files.isEmpty)
        #expect(!changes.isClean)
        #expect(changes.listLimitNotice
            == "The Host's reply was truncated before any files could be listed.")
    }

    @Test func aSignalStatusWithoutExcessBytesIsAFailure() {
        let recording = GitProbeRecordings.failureStatusWithFiles(1, status: 141)
        #expect(Self.failure(recording) == .gitFailed("git exited with status 141."))
    }

    @Test func theSharedLimitNoticeSupportsDirectoryListings() {
        #expect(CheckoutChanges.limitNotice(shown: 2_000, total: 2_345, isLowerBound: false, noun: .files)
            == "Showing \(2_000.formatted()) of \(2_345.formatted()) files.")
        #expect(CheckoutChanges.limitNotice(shown: 2_000, total: 2_345, isLowerBound: true, noun: .files)
            == "Showing \(2_000.formatted()) of more than \(2_345.formatted()) files.")
        #expect(CheckoutChanges.limitNotice(shown: 0, total: 0, isLowerBound: true, noun: .files)
            == "The Host's reply was truncated before any files could be listed.")
    }

    @Test(arguments: ["numstat", "head"])
    func cappedMetadataMarksTheReadWithoutClaimingTheFileTotalIsALowerBound(section: String) throws {
        let cap = section == "head" ? GitProbe.Cap.head : GitProbe.Cap.numstat
        let recording = GitProbeRecordings.failureReplacingSection(
            section, in: GitProbeRecordings.clean, body: Data(repeating: 0x78, count: cap + 1))
        let changes = try Self.parse(recording).changes
        #expect(changes.isMetadataTruncated)
        #expect(!changes.isStatusTruncated)
        #expect(changes.listLimitNotice == nil)
    }

    @Test func changesInsideASubmoduleProduceOneRow() throws {
        let changes = try Self.parse(GitProbeRecordings.failureChangedSubmodule).changes
        #expect(changes.files.count == 1)
        let file = try #require(changes.files.first)
        #expect(file.path == Data("sub".utf8))
        #expect(file.kind == .modified)
        #expect(file.staging == .unstaged)
    }
}
