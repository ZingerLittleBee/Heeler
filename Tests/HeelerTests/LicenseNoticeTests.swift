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

    @Test func everyDiscoveredDependencyDeclarationIsCoveredByInventory() throws {
        // Completeness is two-way and declaration-driven (#161 review finding 2):
        // discover Package.resolved pins, HeelerSSH binary targets, Heeler app
        // package links, and bundled font families from the repo, then require
        // each key to appear in inventory.dependencyCoverage with component ids
        // that exist. A new binary target / pin / package / font family without
        // a coverage entry fails here — fixed ID lists alone cannot do this.
        let inventory = try LicenseNoticeCatalog.loadInventory()
        let coverage = inventory.dependencyCoverage
        let inventoryIDs = Set(inventory.components.map(\.id))

        try assertCoverage(
            discovered: Set(try loadPackageResolvedIdentities()),
            mapped: coverage.packageResolved,
            inventoryIDs: inventoryIDs,
            source: "Package.resolved pin")

        try assertCoverage(
            discovered: Set(try loadHeelerSSHBinaryTargetNames()),
            mapped: coverage.heelerSSHBinaryTargets,
            inventoryIDs: inventoryIDs,
            source: "HeelerSSH binaryTarget")

        try assertCoverage(
            discovered: Set(try loadHeelerAppProjectPackageNames()),
            mapped: coverage.projectPackages,
            inventoryIDs: inventoryIDs,
            source: "project.yml Heeler package dependency")

        try assertCoverage(
            discovered: Set(try loadBundledFontFamilyStems()),
            mapped: coverage.bundledFontFamilies,
            inventoryIDs: inventoryIDs,
            source: "bundled font family")

        // Binary-target paths must also resolve to on-disk XCFrameworks so a
        // renamed artifact cannot leave the inventory mapping orphaned.
        let binaryTargets = try loadHeelerSSHBinaryTargets()
        #expect(!binaryTargets.isEmpty)
        for target in binaryTargets {
            let url = repositoryRoot
                .appendingPathComponent("Packages/HeelerSSH")
                .appendingPathComponent(target.path)
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "binaryTarget \(target.name) path missing: \(target.path)")
            #expect(
                coverage.heelerSSHBinaryTargets[target.name] != nil,
                "binaryTarget \(target.name) has no dependencyCoverage entry")
        }
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

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HeelerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func makeTemporaryBundleDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertMatchesArtifactNotice(named fileName: String, text: String) throws {
        let url = artifactNoticeURL(named: fileName)
        let artifact = try String(contentsOf: url, encoding: .utf8)
        #expect(artifact == text)
    }

    private func artifactNoticeURL(named fileName: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Packages/HeelerSSH/Artifacts/Notices", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Discovered keys must equal coverage map keys; every mapped id must
    /// exist in the inventory. Extra coverage keys (stale after a removal)
    /// also fail so the join stays two-way.
    private func assertCoverage(
        discovered: Set<String>,
        mapped: [String: [String]],
        inventoryIDs: Set<String>,
        source: String
    ) throws {
        #expect(!discovered.isEmpty, "\(source): discovery returned nothing")
        let mappedKeys = Set(mapped.keys)

        let missing = discovered.subtracting(mappedKeys).sorted()
        #expect(
            missing.isEmpty,
            "\(source) without dependencyCoverage entry: \(missing.joined(separator: ", "))")

        let stale = mappedKeys.subtracting(discovered).sorted()
        #expect(
            stale.isEmpty,
            "\(source) coverage keys no longer declared in the repo: \(stale.joined(separator: ", "))")

        for key in discovered.sorted() {
            let ids = try #require(mapped[key])
            #expect(!ids.isEmpty, "\(source) '\(key)' maps to zero inventory ids")
            let unknown = Set(ids).subtracting(inventoryIDs).sorted()
            #expect(
                unknown.isEmpty,
                "\(source) '\(key)' references unknown inventory ids: \(unknown.joined(separator: ", "))")
        }
    }

    private func loadPackageResolvedIdentities() throws -> [String] {
        let url = repositoryRoot
            .appendingPathComponent("Heeler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm")
            .appendingPathComponent("Package.resolved")
        let data = try Data(contentsOf: url)
        let resolved = try JSONDecoder().decode(PackageResolved.self, from: data)
        return resolved.pins.map(\.identity).sorted()
    }

    private struct BinaryTarget: Equatable {
        let name: String
        let path: String
    }

    private func loadHeelerSSHBinaryTargetNames() throws -> [String] {
        try loadHeelerSSHBinaryTargets().map(\.name).sorted()
    }

    private func loadHeelerSSHBinaryTargets() throws -> [BinaryTarget] {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/HeelerSSH/Package.swift"),
            encoding: .utf8)
        // Match SPM `.binaryTarget(name:path:)` declarations. Path packages
        // never appear in Package.resolved; this is the declaration source
        // for vendored XCFrameworks.
        let pattern = #/\.binaryTarget\(\s*name:\s*"([^"]+)"\s*,\s*path:\s*"([^"]+)"/#
        return source.matches(of: pattern).map { match in
            BinaryTarget(name: String(match.1), path: String(match.2))
        }
    }

    /// Package names linked from the Heeler *application* target in
    /// `project.yml` (not the test or extension targets).
    private func loadHeelerAppProjectPackageNames() throws -> [String] {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Locate `targets:` → `Heeler:` → its `dependencies:` list; stop at the
        // next top-level target (`HeelerNotificationService:`) or `schemes:`.
        guard let targetsIndex = lines.firstIndex(where: { $0 == "targets:" }) else {
            throw DiscoveryError.projectYML("missing targets:")
        }
        guard
            let heelerIndex = lines[targetsIndex...].firstIndex(where: { $0 == "  Heeler:" })
        else {
            throw DiscoveryError.projectYML("missing Heeler application target")
        }
        guard
            let depsIndex = lines[heelerIndex...].firstIndex(where: { $0 == "    dependencies:" })
        else {
            throw DiscoveryError.projectYML("Heeler target has no dependencies:")
        }

        var names = Set<String>()
        for line in lines[(depsIndex + 1)...] {
            if line.hasPrefix("  ") && !line.hasPrefix("    ") {
                break  // next target at two-space indent
            }
            if line.hasPrefix("schemes:") {
                break
            }
            // `- package: Name` under the Heeler dependencies list.
            if let match = line.firstMatch(of: #/^\s+-\s+package:\s+(\S+)\s*$/#) {
                names.insert(String(match.1))
            }
        }
        return names.sorted()
    }

    private func loadBundledFontFamilyStems() throws -> [String] {
        let fonts = repositoryRoot
            .appendingPathComponent("Sources/Heeler/Resources/Fonts", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: fonts,
            includingPropertiesForKeys: nil)
        let weightSuffixes = ["Regular", "Bold", "Medium", "Light", "SemiBold", "Thin", "Black"]
        var stems = Set<String>()
        for file in files where file.pathExtension.lowercased() == "ttf" {
            var stem = file.deletingPathExtension().lastPathComponent
            for weight in weightSuffixes {
                let suffix = "-\(weight)"
                if stem.hasSuffix(suffix) {
                    stem = String(stem.dropLast(suffix.count))
                    break
                }
            }
            #expect(!stem.isEmpty, "font face produced an empty family stem: \(file.lastPathComponent)")
            stems.insert(stem)
        }
        return stems.sorted()
    }

    private enum DiscoveryError: Error, CustomStringConvertible {
        case projectYML(String)

        var description: String {
            switch self {
            case .projectYML(let detail):
                "project.yml discovery failed: \(detail)"
            }
        }
    }
}

/// Settings → About → Acknowledgements is a real route: identity, destination
/// type, and source wiring must all agree.
///
/// A row-count or enum-only guard is decorative: deleting the `NavigationLink`
/// and rendering a decoy `LabeledContent` while keeping `.acknowledgements` in
/// `aboutRows` left every prior test green (#161 review finding 1 / #135).
@Suite("Acknowledgements route identity")
struct AcknowledgementsRouteIdentityTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func aboutSectionOffersAcknowledgementsByIdentity() {
        #expect(SettingsView.aboutRows.contains(.acknowledgements))
        #expect(
            SettingsView.AboutRow.acknowledgements.id
                == SettingsView.acknowledgementsRouteID)
        #expect(SettingsView.acknowledgementsRouteID == "settings.about.acknowledgements")
        #expect(
            SettingsView.acknowledgementsRouteID
                == SettingsAboutDestination.acknowledgements.rawValue)
    }

    @Test func acknowledgementsIdentityMapsToAcknowledgementsView() throws {
        // The row identity must resolve to a pushed destination whose concrete
        // view type is AcknowledgementsView — not "some screen", not a label.
        let destination = try #require(
            SettingsView.aboutDestination(for: .acknowledgements))
        #expect(destination == .acknowledgements)
        #expect(destination.rawValue == SettingsView.acknowledgementsRouteID)
        #expect(
            destination.destinationTypeName
                == String(reflecting: AcknowledgementsView.self))

        // Sibling About rows do not push a SettingsAboutDestination; a decoy
        // version/repository/privacy row cannot satisfy the mapping.
        for row in SettingsView.aboutRows where row != .acknowledgements {
            #expect(SettingsView.aboutDestination(for: row) == nil)
        }
        #expect(SettingsView.aboutDestination(for: .version) == nil)
        #expect(SettingsView.aboutDestination(for: .repository) == nil)
        #expect(SettingsView.aboutDestination(for: .privacyPolicy) == nil)
    }

    @Test func acknowledgementsIdentityIsNotSatisfiedByADecoyLabel() {
        let decoyIDs = SettingsView.aboutRows
            .filter { $0 != .acknowledgements }
            .map(\.id)

        #expect(!decoyIDs.contains(SettingsView.acknowledgementsRouteID))
        #expect(SettingsView.AboutRow.version.id != SettingsView.acknowledgementsRouteID)
        #expect(SettingsView.AboutRow.repository.id != SettingsView.acknowledgementsRouteID)
        #expect(SettingsView.AboutRow.privacyPolicy.id != SettingsView.acknowledgementsRouteID)
    }

    @Test func settingsViewWiresAcknowledgementsThroughSharedDestination() throws {
        // Static mapping alone is still decorative if aboutRow ignores it.
        // Require the SettingsView source to push via aboutDestination and
        // destinationView, and to still name AcknowledgementsView as the
        // destination type. Replacing the NavigationLink with a decoy
        // LabeledContent (the 230c0e5 / review-round-1 failure) fails here.
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Heeler/Settings/SettingsView.swift"),
            encoding: .utf8)

        #expect(source.contains("case .acknowledgements:"))
        #expect(source.contains("aboutDestination(for:"))
        #expect(source.contains("destination.destinationView"))
        #expect(source.contains("NavigationLink"))
        #expect(source.contains("AcknowledgementsView.self"))
        #expect(source.contains("AcknowledgementsView()"))

        // The acknowledgements case body must not be a bare LabeledContent stand-in.
        let caseBody = try acknowledgementsCaseBody(in: source)
        #expect(caseBody.contains("NavigationLink"))
        #expect(caseBody.contains("aboutDestination(for:"))
        #expect(caseBody.contains("destination.destinationView"))
        #expect(!caseBody.contains("LabeledContent("))
    }

    @Test func aboutRowsKeepAcknowledgementsWhenSiblingLinksVary() {
        #expect(SettingsView.aboutRows.first == .version)
        #expect(SettingsView.aboutRows.contains(.acknowledgements))
        #expect(SettingsView.aboutRows.contains(.repository))
        #expect(SettingsView.aboutRows.contains(.privacyPolicy))
    }

    /// Slice of the `aboutRow` switch's `.acknowledgements` case. Scoped to
    /// that function so enum/`id`/`aboutDestination` cases with the same label
    /// are not mistaken for the NavigationLink body.
    private func acknowledgementsCaseBody(in source: String) throws -> String {
        guard let funcRange = source.range(of: "private func aboutRow") else {
            throw WiringError.missingAboutRowFunction
        }
        let fromFunc = source[funcRange.lowerBound...]
        let marker = "case .acknowledgements:"
        guard let start = fromFunc.range(of: marker) else {
            throw WiringError.missingAcknowledgementsCase
        }
        let after = fromFunc[start.upperBound...]
        let endMarkers = ["case .repository:", "case .privacyPolicy:", "case .version:"]
        var endOffset = after.endIndex
        for endMarker in endMarkers {
            if let range = after.range(of: endMarker), range.lowerBound < endOffset {
                endOffset = range.lowerBound
            }
        }
        return String(after[..<endOffset])
    }

    private enum WiringError: Error {
        case missingAboutRowFunction
        case missingAcknowledgementsCase
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
