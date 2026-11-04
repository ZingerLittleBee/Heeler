import Foundation
import Testing

@testable import HeelerSSH

@Test("directory listings drop files and dot entries")
func directoryListingsDropFilesAndDotEntries() {
    let listing = SSHSFTPDirectoryListing(rawEntries: [
        (name: ".", isDirectory: true),
        (name: "..", isDirectory: true),
        (name: "notes.txt", isDirectory: false),
        (name: "photos", isDirectory: true),
        (name: ".config", isDirectory: true),
    ])
    #expect(listing.entries.map(\.name) == [".config", "photos"])
    #expect(!listing.truncated)
}

@Test("directory listings sort by name")
func directoryListingsSortByName() {
    let listing = SSHSFTPDirectoryListing(rawEntries: [
        (name: "bravo", isDirectory: true),
        (name: "alpha", isDirectory: true),
        (name: "charlie", isDirectory: true),
    ])
    #expect(listing.entries.map(\.name) == ["alpha", "bravo", "charlie"])
    #expect(!listing.truncated)
}

@Test("directory listings cap at 500 entries and report truncation")
func directoryListingsCapAtMaximumEntries() {
    #expect(SSHSFTPDirectoryListing.maximumEntries == 500)
    let over = (0..<502).map { (name: "dir-\($0)", isDirectory: true) }
    let truncated = SSHSFTPDirectoryListing(rawEntries: over)
    #expect(truncated.entries.count == 500)
    #expect(truncated.truncated)
    #expect(truncated.entries.map(\.name) == truncated.entries.map(\.name).sorted())

    let exact = (0..<500).map { (name: "dir-\($0)", isDirectory: true) }
    let full = SSHSFTPDirectoryListing(rawEntries: exact)
    #expect(full.entries.count == 500)
    #expect(!full.truncated)
}

@Test("entry queries filter by kind, prefix, suffix and substring")
func entryQueriesFilterNames() {
    func entry(_ name: String, _ kind: SSHSFTPEntryKind?) -> SSHSFTPEntry {
        SSHSFTPEntry(name: name, status: SSHSFTPFileStatus(kind: kind, size: nil, modificationTime: nil))
    }
    let rollouts = SSHSFTPEntryQuery(
        kinds: [.regular, .symlink],
        namePrefix: "rollout-",
        nameSuffixes: [".jsonl", ".jsonl.zst"],
        nameContains: "0199")
    #expect(rollouts.matches(entry("rollout-2026-10-06T09-30-00-0199a.jsonl", .regular)))
    #expect(rollouts.matches(entry("rollout-2026-10-06T09-30-00-0199a.jsonl.zst", .symlink)))
    #expect(!rollouts.matches(entry("rollout-2026-10-06T09-30-00-0199a.json", .regular)))
    #expect(!rollouts.matches(entry("rollout-2026-10-06T09-30-00-0199a.jsonl", .directory)))
    #expect(!rollouts.matches(entry("rollout-2026-10-06T09-30-00-0299a.jsonl", .regular)))
    #expect(!rollouts.matches(entry("other-0199a.jsonl", .regular)))
    // A kind the server did not report matches only an unfiltered query.
    #expect(!rollouts.matches(entry("rollout-0199a.jsonl", nil)))
    #expect(SSHSFTPEntryQuery().matches(entry("rollout-0199a.jsonl", nil)))
    #expect(!SSHSFTPEntryQuery().matches(entry(".", .directory)))
    #expect(!SSHSFTPEntryQuery().matches(entry("..", .directory)))
}

@Test("entry queries clamp their limits")
func entryQueriesClampLimits() {
    let low = SSHSFTPEntryQuery(maximumEntries: 0, maximumScanned: -5)
    #expect(low.maximumEntries == 1)
    #expect(low.maximumScanned == 1)
    let high = SSHSFTPEntryQuery(maximumEntries: 50_000, maximumScanned: 1_000_000)
    #expect(high.maximumEntries == SSHSFTPEntryQuery.entryLimit)
    #expect(high.maximumScanned == SSHSFTPEntryQuery.scanLimit)
}

@Test("entry listings sort matches, cap them and keep the scan flag")
func entryListingsSortAndCap() {
    let matches = ["c", "a", "b"].map {
        SSHSFTPEntry(name: $0, status: SSHSFTPFileStatus(kind: .regular, size: 1, modificationTime: 2))
    }
    let capped = SSHSFTPEntryListing(
        matches: matches, query: SSHSFTPEntryQuery(maximumEntries: 2), scanIncomplete: true)
    #expect(capped.entries.map(\.name) == ["a", "b"])
    #expect(capped.truncated)
    #expect(capped.scanIncomplete)
    let whole = SSHSFTPEntryListing(
        matches: matches, query: SSHSFTPEntryQuery(maximumEntries: 3), scanIncomplete: false)
    #expect(whole.entries.map(\.name) == ["a", "b", "c"])
    #expect(!whole.truncated)
}

@Test("file status reads the type from the permission bits")
func fileStatusReadsTypeBits() {
    func kind(_ permissions: UInt?) -> SSHSFTPEntryKind? {
        SSHSFTPFileStatus(permissions: permissions, size: nil, modificationTime: nil).kind
    }
    #expect(kind(0o100644) == .regular)
    #expect(kind(0o040755) == .directory)
    #expect(kind(0o120777) == .symlink)
    #expect(kind(0o060660) == .other)
    #expect(kind(nil) == nil)
    let status = SSHSFTPFileStatus(permissions: 0o100600, size: 42, modificationTime: 1_791_279_000)
    #expect(status.size == 42)
    #expect(status.modificationTime == 1_791_279_000)
}
