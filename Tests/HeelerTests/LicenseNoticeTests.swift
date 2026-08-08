import Foundation
import Testing

@testable import Heeler

/// The audited redistributed-component inventory and the notices it resolves.
///
/// The catalogue is inventory-driven rather than filename-discovered: every
/// shipped dependency must be named in `Notices/inventory.json` and every
/// named entry must resolve to a bundled UTF-8 notice. Filename-only discovery
/// is what made the incomplete set in `230c0e5` self-concealing (#161).
@Suite("License notice inventory")
struct LicenseNoticeInventoryTests {
    /// The complete set of components this package is required to cover. Kept
    /// next to the assertions so omitting any of the licences `230c0e5` missed
    /// (Ghostty stack, libssh2 secondary sources) turns the suite red.
    private static let requiredComponentIDs: Set<String> = [
        "Ghostty",
        "GhosttyTheme",
        "IBMPlexMono",
        "JetBrainsMono",
        "MSDisplayLink",
        "OpenSSL",
        "libghostty-spm",
        "libssh2",
        "libssh2-bcrypt_pbkdf",
        "libssh2-cipher-chachapoly",
    ]

    @Test func inventoryNamesEveryRequiredComponentExactlyOnce() throws {
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let ids = inventory.components.map(\.id)

        #expect(Set(ids) == Self.requiredComponentIDs)
        #expect(ids.count == Self.requiredComponentIDs.count)
    }

    @Test func everyInventoryEntryResolvesToBundledUTF8Notice() throws {
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let notices = try LicenseNoticeCatalog.bundledNotices()

        #expect(notices.map(\.id) == inventory.components.map(\.id))
        for (entry, notice) in zip(inventory.components, notices) {
            #expect(notice.id == entry.id)
            #expect(notice.component == entry.displayName)
            #expect(notice.license == entry.spdx)
            #expect(notice.version == entry.version)
            #expect(notice.source == entry.source)
            #expect(!notice.text.isEmpty)
            #expect(String(data: Data(notice.text.utf8), encoding: .utf8) == notice.text)
        }
    }

    @Test func nativeLibraryNoticesMatchArtifactProvenanceAndUpstreamAnchors() throws {
        let notices = try LicenseNoticeCatalog.bundledNotices()
        let byID = Dictionary(uniqueKeysWithValues: notices.map { ($0.id, $0) })

        let libssh2 = try #require(byID["libssh2"])
        #expect(libssh2.license == "BSD-3-Clause")
        #expect(libssh2.version == "1.11.1")
        #expect(libssh2.text.utf8.count == 1959)
        #expect(libssh2.text.contains("Redistribution and use in source and binary forms"))
        #expect(libssh2.text.contains("Copyright (C) 2015 Microsoft Corp."))
        #expect(libssh2.text.contains("Redistributions in binary form must reproduce the above"))
        try assertMatchesArtifactNotice(
            named: "libssh2-BSD-3-Clause.txt", text: libssh2.text)

        let openSSL = try #require(byID["OpenSSL"])
        #expect(openSSL.license == "Apache-2.0")
        #expect(openSSL.version == "3.6.3")
        #expect(openSSL.text.utf8.count == 10175)
        #expect(openSSL.text.contains("Version 2.0, January 2004"))
        #expect(openSSL.text.contains("4. Redistribution."))
        #expect(openSSL.text.contains("END OF TERMS AND CONDITIONS"))
        try assertMatchesArtifactNotice(
            named: "OpenSSL-Apache-2.0.txt", text: openSSL.text)

        let bcrypt = try #require(byID["libssh2-bcrypt_pbkdf"])
        #expect(bcrypt.license == "MIT")
        #expect(bcrypt.text.contains("Ted Unangst"))
        #expect(bcrypt.text.contains("SPDX-License-Identifier: MIT"))
        #expect(bcrypt.text.contains("appear in all copies"))
        try assertMatchesArtifactNotice(
            named: "libssh2-bcrypt_pbkdf-MIT.txt", text: bcrypt.text)

        let chacha = try #require(byID["libssh2-cipher-chachapoly"])
        #expect(chacha.license == "BSD-2-Clause")
        #expect(chacha.text.contains("Damien Miller"))
        #expect(chacha.text.contains("SPDX-License-Identifier: BSD-2-Clause"))
        #expect(chacha.text.contains("appear in all copies"))
        try assertMatchesArtifactNotice(
            named: "libssh2-cipher-chachapoly-BSD-2-Clause.txt", text: chacha.text)
    }

    @Test func ghosttyStackAndFontNoticesShipVerbatim() throws {
        let notices = try LicenseNoticeCatalog.bundledNotices()
        let byID = Dictionary(uniqueKeysWithValues: notices.map { ($0.id, $0) })

        for id in ["Ghostty", "libghostty-spm", "MSDisplayLink"] {
            let notice = try #require(byID[id])
            #expect(notice.license == "MIT")
            #expect(notice.text.contains("MIT License"))
            #expect(notice.text.contains("Permission is hereby granted"))
            #expect(notice.text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        }

        let theme = try #require(byID["GhosttyTheme"])
        #expect(theme.license == "MIT")
        #expect(theme.text.contains("iTerm2-Color-Schemes"))
        #expect(theme.text.contains("Mark Badolato"))
        #expect(theme.text.contains("MIT License"))

        for id in ["IBMPlexMono", "JetBrainsMono"] {
            let notice = try #require(byID[id])
            #expect(notice.license == "OFL-1.1")
            #expect(notice.text.contains("SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007"))
            #expect(notice.text.contains("PERMISSION & CONDITIONS"))
        }
    }

    @Test func packageResolvedPinsAreCoveredByInventory() throws {
        // Adding a SwiftPM pin without inventory coverage must fail here: the
        // switch is exhaustive over known identities and records an Issue for
        // any new one. Filename discovery cannot do this.
        let inventoryIDs = Set(try LicenseNoticeCatalog.loadInventory().components.map(\.id))
        let pins = try loadPackageResolvedIdentities()

        #expect(!pins.isEmpty)
        for identity in pins {
            switch identity {
            case "libghostty-spm":
                #expect(
                    inventoryIDs.isSuperset(of: ["libghostty-spm", "Ghostty", "GhosttyTheme"]))
            case "msdisplaylink":
                #expect(inventoryIDs.contains("MSDisplayLink"))
            default:
                Issue.record(
                    "Package.resolved pin '\(identity)' has no inventory coverage mapping — add a notice entry and a case here")
            }
        }

        // Local native artifacts are not Package.resolved pins but are still
        // redistributed; pin them explicitly so they cannot be dropped quietly.
        #expect(
            inventoryIDs.isSuperset(of: [
                "libssh2",
                "libssh2-bcrypt_pbkdf",
                "libssh2-cipher-chachapoly",
                "OpenSSL",
            ]))
        #expect(inventoryIDs.isSuperset(of: ["IBMPlexMono", "JetBrainsMono"]))
    }

    @Test func missingNoticeResourceFailsLoudly() throws {
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let entry = try #require(inventory.components.first)
        let missing = LicenseInventory.Entry(
            id: entry.id,
            displayName: entry.displayName,
            version: entry.version,
            source: entry.source,
            spdx: entry.spdx,
            notice: "does-not-exist-for-tests.txt")

        let directory = try makeTemporaryBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try #require(Bundle(url: directory))
        #expect(throws: LicenseNoticeCatalogError.noticeMissing(
            componentID: entry.id, fileName: "does-not-exist-for-tests.txt")
        ) {
            _ = try LicenseNoticeCatalog.notice(for: missing, in: bundle)
        }
    }

    @Test func noticeAtBundleRootInsteadOfNoticesSubdirectoryFails() throws {
        // A notice that lands at the bundle root (or any other path) must not
        // be discovered by accident — that was the silent-vanishing case the
        // misnaming test in 230c0e5 never covered.
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let entry = try #require(inventory.components.first)
        let directory = try makeTemporaryBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "licence text".write(
            to: directory.appendingPathComponent(entry.notice),
            atomically: true,
            encoding: .utf8)
        let bundle = try #require(Bundle(url: directory))

        #expect(throws: LicenseNoticeCatalogError.noticeMissing(
            componentID: entry.id, fileName: entry.notice)
        ) {
            _ = try LicenseNoticeCatalog.notice(for: entry, in: bundle)
        }
    }

    @Test func nonUTF8NoticeFailsLoudly() throws {
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let entry = try #require(inventory.components.first)
        let directory = try makeTemporaryBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notices = directory.appendingPathComponent(
            LicenseNoticeCatalog.noticesSubdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        // Invalid UTF-8: lone continuation byte.
        try Data([0x80]).write(to: notices.appendingPathComponent(entry.notice))
        let bundle = try #require(Bundle(url: directory))

        #expect(throws: LicenseNoticeCatalogError.noticeNotUTF8(
            componentID: entry.id, fileName: entry.notice)
        ) {
            _ = try LicenseNoticeCatalog.notice(for: entry, in: bundle)
        }
    }

    @Test func emptyNoticeFailsLoudly() throws {
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let entry = try #require(inventory.components.first)
        let directory = try makeTemporaryBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notices = directory.appendingPathComponent(
            LicenseNoticeCatalog.noticesSubdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        try Data().write(to: notices.appendingPathComponent(entry.notice))
        let bundle = try #require(Bundle(url: directory))

        #expect(throws: LicenseNoticeCatalogError.noticeEmpty(
            componentID: entry.id, fileName: entry.notice)
        ) {
            _ = try LicenseNoticeCatalog.notice(for: entry, in: bundle)
        }
    }

    @Test func malformedInventoryFailsLoudly() throws {
        let directory = try makeTemporaryBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notices = directory.appendingPathComponent(
            LicenseNoticeCatalog.noticesSubdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        try "{not json".write(
            to: notices.appendingPathComponent("inventory.json"),
            atomically: true,
            encoding: .utf8)
        let bundle = try #require(Bundle(url: directory))

        #expect(throws: LicenseNoticeCatalogError.self) {
            _ = try LicenseNoticeCatalog.loadInventory(in: bundle)
        }
    }

    @Test func missingInventoryFailsLoudly() throws {
        let directory = try makeTemporaryBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try #require(Bundle(url: directory))

        #expect(throws: LicenseNoticeCatalogError.inventoryMissing) {
            _ = try LicenseNoticeCatalog.loadInventory(in: bundle)
        }
    }

    // MARK: - Helpers

    private func makeTemporaryBundleDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertMatchesArtifactNotice(named fileName: String, text: String) throws {
        let url = try artifactNoticeURL(named: fileName)
        let artifact = try String(contentsOf: url, encoding: .utf8)
        #expect(artifact == text)
    }

    private func artifactNoticeURL(named fileName: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            directory.deleteLastPathComponent()
        }
        return directory
            .appendingPathComponent("Packages/HeelerSSH/Artifacts/Notices", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private func loadPackageResolvedIdentities() throws -> [String] {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            directory.deleteLastPathComponent()
        }
        let url = directory
            .appendingPathComponent("Heeler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm")
            .appendingPathComponent("Package.resolved")
        let data = try Data(contentsOf: url)
        let resolved = try JSONDecoder().decode(PackageResolved.self, from: data)
        return resolved.pins.map(\.identity).sorted()
    }
}

/// Settings → About → Acknowledgements is a real route, asserted by identity.
///
/// A row-count guard is decorative: deleting the NavigationLink and adding a
/// decoy `LabeledContent` keeps the count green while the app has no path to
/// the notices. The About section is driven by `SettingsView.aboutRows`, and
/// the Acknowledgements case carries `acknowledgementsRouteID` (#161).
@Suite("Acknowledgements route identity")
struct AcknowledgementsRouteIdentityTests {
    @Test func aboutSectionOffersAcknowledgementsByIdentity() {
        #expect(SettingsView.aboutRows.contains(.acknowledgements))
        #expect(
            SettingsView.AboutRow.acknowledgements.id
                == SettingsView.acknowledgementsRouteID)
        #expect(SettingsView.acknowledgementsRouteID == "settings.about.acknowledgements")
    }

    @Test func acknowledgementsIdentityIsNotSatisfiedByADecoyLabel() {
        // A decoy row would be some other AboutRow case (or an unrelated
        // string). Only `.acknowledgements` matches the route id.
        let decoyIDs = SettingsView.aboutRows
            .filter { $0 != .acknowledgements }
            .map(\.id)

        #expect(!decoyIDs.contains(SettingsView.acknowledgementsRouteID))
        #expect(SettingsView.AboutRow.version.id != SettingsView.acknowledgementsRouteID)
        #expect(SettingsView.AboutRow.repository.id != SettingsView.acknowledgementsRouteID)
        #expect(SettingsView.AboutRow.privacyPolicy.id != SettingsView.acknowledgementsRouteID)
    }

    @Test func aboutRowsKeepAcknowledgementsWhenSiblingLinksVary() {
        // Version + Acknowledgements are unconditional; repository/privacy
        // depend on URL availability. Acknowledgements must not be gated.
        #expect(SettingsView.aboutRows.first == .version)
        #expect(SettingsView.aboutRows.contains(.acknowledgements))
        #expect(SettingsView.aboutRows.contains(.repository))
        #expect(SettingsView.aboutRows.contains(.privacyPolicy))
    }
}

/// Font faces still register after the licence files left `Resources/Fonts`.
@Suite("Terminal fonts after notice relocation")
struct TerminalFontNoticeRelocationTests {
    @Test func bundledFacesStillRegisterUnderTheNamesGhosttyLooksUp() {
        let families = TerminalFontCatalog.registerBundledFonts()

        #expect(families.contains("JetBrains Mono"))
        #expect(families.contains("IBM Plex Mono"))
    }

    @Test func fontFaceResourcesRemainAtTheBundleRoot() {
        // Registration looks up faces by bare resource name with no
        // subdirectory. Licence files moved under Notices/; the faces must not
        // have followed them.
        for face in [
            "JetBrainsMono-Regular",
            "JetBrainsMono-Bold",
            "IBMPlexMono-Regular",
            "IBMPlexMono-Bold",
        ] {
            #expect(Bundle.main.url(forResource: face, withExtension: "ttf") != nil)
        }

        #expect(
            Bundle.main.url(
                forResource: "IBMPlexMono-OFL-1.1",
                withExtension: "txt",
                subdirectory: LicenseNoticeCatalog.noticesSubdirectory) != nil)
        #expect(
            Bundle.main.url(
                forResource: "JetBrainsMono-OFL-1.1",
                withExtension: "txt",
                subdirectory: LicenseNoticeCatalog.noticesSubdirectory) != nil)
    }
}

// MARK: - Package.resolved

private struct PackageResolved: Decodable {
    struct Pin: Decodable {
        let identity: String
    }

    let pins: [Pin]
}
