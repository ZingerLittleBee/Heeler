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
