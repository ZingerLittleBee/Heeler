import Foundation
import Testing

@testable import Heeler

/// The untracked-directory script and the bytes it gets back. Nothing here
/// runs a shell; the fixture test does.
@Suite("GitProbe untracked directory")
struct GitProbeUntrackedDirectoryTests {
    private typealias Recording = (stdout: Data, stderr: Data)

    private static func text(_ script: Data) -> String {
        String(decoding: script, as: UTF8.self)
    }

    private static func parse(
        _ recording: Recording,
        directory: String,
        nonce: String = GitProbeRecordings.nonce,
        displayLimit: Int? = nil,
        cap: Int = GitProbe.Cap.status
    ) throws -> UntrackedDirectoryListing {
        if let displayLimit {
            return try GitProbe.parseUntrackedDirectory(
                stdout: recording.stdout, stderr: recording.stderr, nonce: nonce,
                directory: Data(directory.utf8), displayLimit: displayLimit, cap: cap)
        }
        return try GitProbe.parseUntrackedDirectory(
            stdout: recording.stdout, stderr: recording.stderr, nonce: nonce,
            directory: Data(directory.utf8), cap: cap)
    }

    private static func failure(
        _ recording: Recording,
        directory: String = "newdir/",
        nonce: String = GitProbeRecordings.nonce,
        cap: Int = GitProbe.Cap.status
    ) -> ChangesReadError? {
        do {
            _ = try parse(recording, directory: directory, nonce: nonce, cap: cap)
            return nil
        } catch let error as ChangesReadError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// A section body wrapped in the listing's markers. Built here, not recorded.
    private static func framed(_ body: Data, status: Int) -> Recording {
        let marker = GitProbe.marker(nonce: GitProbeRecordings.nonce)
        var stdout = Data("\n\(marker) untracked begin\n".utf8)
        stdout.append(body)
        stdout.append(Data("\n\(marker) untracked rc=\(status)\n\n\(marker) done\n".utf8))
        let stderr = Data("\n\(marker) untracked begin\n\n\(marker) untracked end\n".utf8)
        return (stdout, stderr)
    }

    private static func paths(_ listing: UntrackedDirectoryListing) -> [String] {
        listing.entries.map { String(decoding: $0.path, as: UTF8.self) }
    }

    @Test func theScriptIsOneBraceGroupReadingTheNullDevice() {
        let script = Self.text(
            GitProbe.untrackedDirectoryScript(
                topLevel: Data("/home/dev/src/app".utf8),
                directory: Data("newdir/".utf8),
                nonce: "F00D"))
        #expect(script.hasPrefix("{\n"))
        #expect(script.hasSuffix("\n} </dev/null 3>&1\n"))
        #expect(script.contains("\nprintf '\\n%s done\\n' \"$N\"\n"))
        #expect(script.contains("N='__HEELER_GIT_F00D__'\n"))
        #expect(script.contains("top='/home/dev/src/app'\n"))
        #expect(script.contains(" -- 'newdir/'\n"))
        #expect(!script.contains("newdir//"))
    }

    @Test func itListsUntrackedFilesFromTheTopLevelUnderTheStatusCap() throws {
        let script = Self.text(
            GitProbe.untrackedDirectoryScript(
                topLevel: Data("/home/dev/src/app".utf8),
                directory: Data("newdir/".utf8),
                nonce: "F00D"))
        #expect(GitProbe.Cap.status == 524_288)
        #expect(GitProbe.SectionName.untracked == "untracked")
        #expect(
            script.contains(
                "sec \(GitProbe.Cap.status) untracked g -C \"$top\" status --porcelain=v2 -z --untracked-files=all -- "
            ))
        #expect(!script.contains("--branch"))
        #expect(!script.contains("git --version"))
        #expect(!script.contains("discover"))
        #expect(!script.contains("--show-toplevel"))
        #expect(!script.contains("--untracked-files=normal"))
        #expect(script.contains("--literal-pathspecs"))
        #expect(script.contains("core.fsmonitor="))
        #expect(!script.contains("core.fsmonitor=false"))
        #expect(script.contains("diff.autoRefreshIndex=false"))
        #expect(script.contains("status.renames=true"))

        let lines = script.split(separator: "\n").map(String.init)
        let definition = try #require(lines.first { $0.hasPrefix("g() { git ") })
        let direct = lines.filter {
            $0.range(of: #"(^|[ ;({])git "#, options: .regularExpression) != nil
        }
        #expect(direct == [definition])
    }

    @Test(arguments: GitProbeScriptTests.hostileNames)
    func aHostileTopLevelAndDirectoryAppearOnlyInsideSingleQuotes(name: String) throws {
        let top = "/home/dev/src/\(name)"
        let directory = "\(name)/"
        let script = Self.text(
            GitProbe.untrackedDirectoryScript(
                topLevel: Data(top.utf8), directory: Data(directory.utf8), nonce: "F00D"))
        let topAssignment = try #require(script.range(of: "\ntop="))
        let topWord = try #require(ShellWord.parse(script[topAssignment.upperBound...]))
        #expect(topWord.value == top)
        #expect(topWord.isQuotedOnly)

        let separator = try #require(script.range(of: " -- ", options: .backwards))
        let pathWord = try #require(ShellWord.parse(script[separator.upperBound...]))
        #expect(pathWord.value == directory)
        #expect(pathWord.isQuotedOnly)

        var rest = script
        rest.removeSubrange(separator.upperBound..<pathWord.end)
        rest.removeSubrange(topAssignment.upperBound..<topWord.end)
        #expect(!rest.contains(top))
        #expect(!rest.contains(directory))
    }

    @Test func singleQuotingKeepsANonUTF8TopLevelInsideOneWord() throws {
        var top = Data("/home/dev/".utf8)
        top.append(contentsOf: [0x80, 0xFF, 0x27])
        let directory = Data("a'b/\n".utf8)
        let script = GitProbe.untrackedDirectoryScript(
            topLevel: top, directory: directory, nonce: "F00D")
        let quotedTop = GitProbe.singleQuoted(top)
        let quotedDirectory = GitProbe.singleQuoted(directory)
        let topAt = try #require(script.range(of: quotedTop))
        let directoryAt = try #require(script.range(of: quotedDirectory))
        var rest = script
        rest.removeSubrange(directoryAt)
        rest.removeSubrange(topAt)
        #expect(rest.range(of: top) == nil)
        #expect(rest.range(of: directory) == nil)
    }

    @Test func aRecordedListingKeepsUntrackedBytesAndDropsTrackedRows() throws {
        let changes = try GitProbe.parseChanges(
            stdout: GitProbeRecordings.hostile.stdout,
            stderr: GitProbeRecordings.hostile.stderr,
            nonce: GitProbeRecordings.nonce)
        #expect(
            changes.changes.files.first { $0.path == Data("newdir/".utf8) }?.isUntrackedDirectory
                == true)
        #expect(
            changes.changes.files.first { $0.path == Data("untracked.txt".utf8) }?
                .isUntrackedDirectory == false)

        let listing = try Self.parse(GitProbeRecordings.untrackedListing, directory: "newdir/")
        let expected = [
            "newdir/$HOME.txt",
            "newdir/*.txt",
            "newdir/--",
            "newdir/-dash.txt",
            "newdir/[ab].txt",
            "newdir/a.txt",
            "newdir/bang!.txt",
            "newdir/deep/b.txt",
            "newdir/inner/",
            "newdir/line\nbreak.txt",
            "newdir/quo\"te.txt",
            "newdir/sp ace.txt",
            "newdir/sq'uote.txt",
            "newdir/tab\tname.txt",
            "newdir/trail\\",
            #"newdir/two\\bs.txt"#,
            "newdir/ünï.txt",
            "newdir/中文.txt",
        ]
        #expect(Self.paths(listing) == expected)
        #expect(listing.total == expected.count)
        #expect(!listing.isTruncated)
        #expect(!listing.isSeparateRepository)
        #expect(listing.limitNotice == nil)
        #expect(listing.directory == Data("newdir/".utf8))
        #expect(listing.repositoryNotice == nil)
        #expect(
            listing.entries.allSatisfy {
                $0.kind == .untracked && $0.staging == nil && $0.originalPath == nil
            })
        let nested = try #require(listing.entries.first { $0.path == Data("newdir/inner/".utf8) })
        #expect(nested.isUntrackedDirectory)
        #expect(
            listing.entries.first { $0.path == Data("newdir/a.txt".utf8) }?.isUntrackedDirectory
                == false)
        let absent = [
            "newdir/staged.txt", "newdir/tracked-inside.txt", "newdir/skip.log",
            "newdir/inner/secret.txt",
        ]
        #expect(Self.paths(listing).allSatisfy { !absent.contains($0) })
    }

    /// Apple Git 2.54.0, pathspec `? dir/`: a type-2 rename, then its original
    /// path as the next NUL field, then the real untracked records.
    @Test func aRenameOriginalPathIsNotAnUntrackedFile() throws {
        let listing = try Self.parse(
            GitProbeRecordings.untrackedListingRename, directory: "? dir/")
        #expect(Self.paths(listing) == ["? dir/plain.txt", "? dir/untracked"])
        #expect(listing.total == 2)
        #expect(!listing.isTruncated)
        #expect(!listing.isSeparateRepository)
        #expect(listing.limitNotice == nil)
        #expect(
            listing.entries.allSatisfy {
                $0.kind == .untracked && $0.staging == nil && $0.originalPath == nil
            })
        let absent = ["dir/original", "? dir/original", "? dir/renamed", "? dir/added.txt"]
        #expect(Self.paths(listing).allSatisfy { !absent.contains($0) })
    }

    /// The original path was cut off the end of the status cap, so the rename
    /// is dropped and the untracked record before it stays.
    @Test func aRenameCutOffBeforeItsOriginalPathIsDropped() throws {
        let header =
            "2 R. N... 100644 100644 100644 "
            + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa R100 dir/renamed"
        let body = Data("? kept.txt\0\(header)\0dir/orig".utf8)
        let listing = try Self.parse(Self.framed(body, status: 0), directory: "dir/")
        #expect(Self.paths(listing) == ["kept.txt"])
        #expect(listing.total == 1)
        #expect(!listing.isTruncated)
    }

    @Test func aLiteralDirectoryNameListsOnlyItsOwnFile() throws {
        let listing = try Self.parse(GitProbeRecordings.untrackedListingLiteral, directory: "[ab]/")
        #expect(Self.paths(listing) == ["[ab]/c.txt"])
        #expect(listing.total == 1)
        #expect(!listing.isSeparateRepository)
        #expect(!listing.isTruncated)
    }

    @Test func aDirectoryThatIsItsOwnRepositoryIsNotAChildRow() throws {
        let listing = try Self.parse(
            GitProbeRecordings.untrackedListingSeparateRepository, directory: "nested/")
        #expect(listing.isSeparateRepository)
        #expect(listing.entries.isEmpty)
        #expect(listing.total == 0)
        #expect(listing.limitNotice == nil)
        #expect(!listing.isTruncated)
        #expect(listing.repositoryNotice == "This directory is a separate Git repository.")
    }

    @Test func anEmptyStatusIsAnEmptyListing() throws {
        var noisy = Data("welcome\n".utf8)
        noisy.append(GitProbeRecordings.untrackedListingEmpty.stdout)
        let listing = try Self.parse(
            (noisy, GitProbeRecordings.untrackedListingEmpty.stderr), directory: "gone/")
        #expect(listing.entries.isEmpty)
        #expect(listing.total == 0)
        #expect(!listing.isTruncated)
        #expect(!listing.isSeparateRepository)
        #expect(listing.limitNotice == nil)
    }

    @Test func entriesSortByRawPathAndTheDisplayLimitKeepsTheFirst() throws {
        let listing = try Self.parse(
            Self.framed(Data("? b.txt\0? a.txt\0? c.txt\0".utf8), status: 0),
            directory: "dir/",
            displayLimit: 1)
        #expect(Self.paths(listing) == ["a.txt"])
        #expect(listing.total == 3)
        #expect(!listing.isTruncated)
        #expect(
            listing.limitNotice
                == "Showing \(1.formatted()) of \(3.formatted()) files.")
    }

    @Test func moreThanTheDisplayLimitShowsTheCeilingAndTheTotal() throws {
        var body = Data()
        for index in 0..<2_001 {
            var record = Data("? f".utf8)
            record.append(Data(String(format: "%04d", index).utf8))
            record.append(Data(".txt\0".utf8))
            body.append(record)
        }
        let listing = try Self.parse(Self.framed(body, status: 0), directory: "dir/")
        #expect(listing.entries.count == 2_000)
        #expect(listing.total == 2_001)
        #expect(!listing.isTruncated)
        #expect(Self.paths(listing).first == "f0000.txt")
        #expect(Self.paths(listing).last == "f1999.txt")
        #expect(
            listing.limitNotice
                == CheckoutChanges.limitNotice(
                    shown: 2_000, total: 2_001, isLowerBound: false, noun: .files))
    }

    @Test(arguments: [141, 0])
    func outputOverTheCapDropsThePartialRecord(status: Int) throws {
        let body = Data("? kept.txt\0? cut-off".utf8)
        let cap = Data("? kept.txt\0? c".utf8).count
        let listing = try Self.parse(
            Self.framed(body, status: status), directory: "dir/", cap: cap)
        #expect(Self.paths(listing) == ["kept.txt"])
        #expect(listing.total == 1)
        #expect(listing.isTruncated)
        #expect(
            listing.limitNotice
                == "Showing \(1.formatted()) of more than \(1.formatted()) files.")
    }

    @Test func aMissingFinalMarkerIsIncomplete() {
        let stdout = Data(
            String(decoding: GitProbeRecordings.untrackedListingEmpty.stdout, as: UTF8.self)
                .replacingOccurrences(of: "\n__HEELER_GIT_F00D__ done\n", with: "\n").utf8)
        #expect(
            Self.failure(
                (stdout, GitProbeRecordings.untrackedListingEmpty.stderr), directory: "gone/")
                == .incomplete)
    }

    @Test func aMissingFramedStatusIsIncomplete() {
        let stdout = Data(
            String(decoding: GitProbeRecordings.untrackedListing.stdout, as: UTF8.self)
                .replacingOccurrences(
                    of: "__HEELER_GIT_F00D__ untracked rc=0\n",
                    with: "__HEELER_GIT_F00D__ untracked rc=\n"
                ).utf8)
        #expect(Self.failure((stdout, GitProbeRecordings.untrackedListing.stderr)) == .incomplete)
    }

    @Test func aMarkerCarryingAnotherNonceIsIgnored() {
        #expect(Self.failure(GitProbeRecordings.untrackedListing, nonce: "BEEF") == .incomplete)
    }

    @Test func aMissingTopLevelIsDirectoryMissing() {
        #expect(
            Self.failure(GitProbeRecordings.untrackedListingMissingTopLevel) == .directoryMissing)
    }

    @Test func anUnclassifiedListingFailureCarriesGitsFirstLine() {
        let message = "fatal: cannot change to '/home/dev/app': Permission denied"
        let recording = GitProbeRecordings.failureReplacingSection(
            "untracked", in: GitProbeRecordings.untrackedListing, status: 128,
            messages: "\n\(message)\nhint: more detail\n")
        #expect(Self.failure(recording) == .gitFailed(message))
    }
}
