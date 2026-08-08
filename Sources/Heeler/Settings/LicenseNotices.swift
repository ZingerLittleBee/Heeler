import Foundation

/// One redistribution notice the app ships: the component it covers, the
/// licence identity, and that licence's verbatim text.
struct LicenseNotice: Identifiable, Equatable, Sendable {
    /// Stable inventory id, e.g. `libssh2` or `libssh2-bcrypt_pbkdf`.
    let id: String
    /// User-visible component name.
    let component: String
    /// SPDX identifier recorded in the inventory.
    let license: String
    /// Version or revision pin when the inventory records one.
    let version: String?
    /// Provenance string for the notice (source path or upstream URL).
    let source: String?
    /// The licence text exactly as upstream ships it. Never a summary.
    let text: String
}

/// Audited inventory of every third-party component redistributed in the app.
///
/// The catalogue is *not* discovered from whatever `.txt` files happen to sit
/// in the bundle: filename-only discovery is self-concealing, because adding a
/// dependency without a notice produces no signal (#161). The inventory is the
/// audited list; each entry must resolve to a bundled UTF-8 notice or loading
/// fails loudly.
///
/// `dependencyCoverage` is the two-way join between repository dependency
/// *declarations* (Package.resolved pins, local binary targets, project
/// package links, bundled font families) and inventory component ids. Completeness
/// tests discover the declarations from the repo and require every one to be
/// named here with inventory ids that exist in `components`.
struct LicenseInventory: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let version: String?
        let source: String?
        let spdx: String
        /// Filename under the bundle's `Notices/` directory.
        let notice: String
    }

    /// Maps each machine-discovered dependency declaration key to the inventory
    /// component ids that cover it. Keys must match discovery exactly.
    struct DependencyCoverage: Equatable, Sendable {
        /// `Package.resolved` pin `identity` → component ids.
        let packageResolved: [String: [String]]
        /// `Packages/HeelerSSH/Package.swift` `.binaryTarget` `name` → component ids.
        let heelerSSHBinaryTargets: [String: [String]]
        /// `project.yml` `packages:` entry name linked from the Heeler app
        /// target → component ids.
        let projectPackages: [String: [String]]
        /// Bundled font family stem under `Resources/Fonts` (e.g. `IBMPlexMono`)
        /// → component ids.
        let bundledFontFamilies: [String: [String]]
    }

    let schemaVersion: Int
    let components: [Entry]
    let dependencyCoverage: DependencyCoverage
}

enum LicenseNoticeCatalogError: Error, Equatable, LocalizedError {
    case inventoryMissing
    case inventoryUnreadable(String)
    case inventoryMalformed(String)
    case noticeMissing(componentID: String, fileName: String)
    case noticeNotUTF8(componentID: String, fileName: String)
    case noticeEmpty(componentID: String, fileName: String)

    var errorDescription: String? {
        switch self {
        case .inventoryMissing:
            "Notices/inventory.json is missing from the app bundle"
        case .inventoryUnreadable(let detail):
            "Notices/inventory.json could not be read: \(detail)"
        case .inventoryMalformed(let detail):
            "Notices/inventory.json is malformed: \(detail)"
        case .noticeMissing(let componentID, let fileName):
            "Notice for \(componentID) is missing: Notices/\(fileName)"
        case .noticeNotUTF8(let componentID, let fileName):
            "Notice for \(componentID) is not valid UTF-8: Notices/\(fileName)"
        case .noticeEmpty(let componentID, let fileName):
            "Notice for \(componentID) is empty: Notices/\(fileName)"
        }
    }
}

/// Loads the audited notice inventory and resolves each entry to bundled text.
enum LicenseNoticeCatalog {
    /// Bundle subdirectory that holds `inventory.json` and every notice file.
    static let noticesSubdirectory = "Notices"
    static let inventoryResourceName = "inventory"
    static let inventoryExtension = "json"

    /// Decode the audited inventory from `bundle`. Fails if the resource is
    /// missing, unreadable, or not a well-formed inventory document.
    static func loadInventory(in bundle: Bundle = .main) throws -> LicenseInventory {
        guard
            let url = bundle.url(
                forResource: inventoryResourceName,
                withExtension: inventoryExtension,
                subdirectory: noticesSubdirectory)
        else {
            throw LicenseNoticeCatalogError.inventoryMissing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LicenseNoticeCatalogError.inventoryUnreadable(error.localizedDescription)
        }

        do {
            return try decodeInventory(from: data)
        } catch let error as LicenseNoticeCatalogError {
            throw error
        } catch {
            throw LicenseNoticeCatalogError.inventoryMalformed(error.localizedDescription)
        }
    }

    /// Every notice the inventory names, resolved against `bundle`.
    ///
    /// Order follows the inventory document so the screen is stable and tests
    /// can compare against the audited list rather than a parallel Swift array.
    static func bundledNotices(in bundle: Bundle = .main) throws -> [LicenseNotice] {
        let inventory = try loadInventory(in: bundle)
        return try inventory.components.map { entry in
            try notice(for: entry, in: bundle)
        }
    }

    /// Resolve one inventory entry. Exposed for tests that exercise missing,
    /// misplaced, and malformed notice resources in isolation.
    static func notice(
        for entry: LicenseInventory.Entry,
        in bundle: Bundle
    ) throws -> LicenseNotice {
        let fileName = entry.notice
        let resourceName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard
            let url = bundle.url(
                forResource: resourceName,
                withExtension: ext.isEmpty ? nil : ext,
                subdirectory: noticesSubdirectory)
        else {
            throw LicenseNoticeCatalogError.noticeMissing(
                componentID: entry.id, fileName: fileName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LicenseNoticeCatalogError.noticeMissing(
                componentID: entry.id, fileName: fileName)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw LicenseNoticeCatalogError.noticeNotUTF8(
                componentID: entry.id, fileName: fileName)
        }
        guard !text.isEmpty else {
            throw LicenseNoticeCatalogError.noticeEmpty(
                componentID: entry.id, fileName: fileName)
        }

        return LicenseNotice(
            id: entry.id,
            component: entry.displayName,
            license: entry.spdx,
            version: entry.version,
            source: entry.source,
            text: text)
    }

    // MARK: - Decoding

    private struct InventoryDTO: Decodable {
        let schemaVersion: Int
        let components: [ComponentDTO]
        let dependencyCoverage: DependencyCoverageDTO
    }

    private struct ComponentDTO: Decodable {
        let id: String
        let displayName: String
        let version: String?
        let source: String?
        let spdx: String
        let notice: String
    }

    private struct DependencyCoverageDTO: Decodable {
        let packageResolved: [String: [String]]
        let heelerSSHBinaryTargets: [String: [String]]
        let projectPackages: [String: [String]]
        let bundledFontFamilies: [String: [String]]
    }

    private static func decodeInventory(from data: Data) throws -> LicenseInventory {
        let dto: InventoryDTO
        do {
            dto = try JSONDecoder().decode(InventoryDTO.self, from: data)
        } catch {
            throw LicenseNoticeCatalogError.inventoryMalformed(String(describing: error))
        }

        guard dto.schemaVersion == 1 else {
            throw LicenseNoticeCatalogError.inventoryMalformed(
                "unsupported schemaVersion \(dto.schemaVersion)")
        }
        guard !dto.components.isEmpty else {
            throw LicenseNoticeCatalogError.inventoryMalformed("components is empty")
        }

        var seen = Set<String>()
        var entries: [LicenseInventory.Entry] = []
        for component in dto.components {
            let id = component.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = component.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let spdx = component.spdx.trimmingCharacters(in: .whitespacesAndNewlines)
            let notice = component.notice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !displayName.isEmpty, !spdx.isEmpty, !notice.isEmpty else {
                throw LicenseNoticeCatalogError.inventoryMalformed(
                    "component is missing a required field")
            }
            guard seen.insert(id).inserted else {
                throw LicenseNoticeCatalogError.inventoryMalformed(
                    "duplicate component id \(id)")
            }
            entries.append(
                LicenseInventory.Entry(
                    id: id,
                    displayName: displayName,
                    version: component.version,
                    source: component.source,
                    spdx: spdx,
                    notice: notice))
        }

        let coverage = try decodeCoverage(dto.dependencyCoverage, knownIDs: seen)
        return LicenseInventory(
            schemaVersion: dto.schemaVersion,
            components: entries,
            dependencyCoverage: coverage)
    }

    private static func decodeCoverage(
        _ dto: DependencyCoverageDTO,
        knownIDs: Set<String>
    ) throws -> LicenseInventory.DependencyCoverage {
        func normalize(
            _ map: [String: [String]],
            label: String
        ) throws -> [String: [String]] {
            var result: [String: [String]] = [:]
            for (rawKey, rawIDs) in map {
                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    throw LicenseNoticeCatalogError.inventoryMalformed(
                        "dependencyCoverage.\(label) has an empty key")
                }
                guard !rawIDs.isEmpty else {
                    throw LicenseNoticeCatalogError.inventoryMalformed(
                        "dependencyCoverage.\(label)[\(key)] is empty")
                }
                var ids: [String] = []
                var seenIDs = Set<String>()
                for rawID in rawIDs {
                    let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else {
                        throw LicenseNoticeCatalogError.inventoryMalformed(
                            "dependencyCoverage.\(label)[\(key)] has an empty id")
                    }
                    guard knownIDs.contains(id) else {
                        throw LicenseNoticeCatalogError.inventoryMalformed(
                            "dependencyCoverage.\(label)[\(key)] references unknown component \(id)")
                    }
                    guard seenIDs.insert(id).inserted else {
                        throw LicenseNoticeCatalogError.inventoryMalformed(
                            "dependencyCoverage.\(label)[\(key)] duplicates component \(id)")
                    }
                    ids.append(id)
                }
                guard result[key] == nil else {
                    throw LicenseNoticeCatalogError.inventoryMalformed(
                        "dependencyCoverage.\(label) has duplicate key \(key)")
                }
                result[key] = ids
            }
            return result
        }

        return LicenseInventory.DependencyCoverage(
            packageResolved: try normalize(dto.packageResolved, label: "packageResolved"),
            heelerSSHBinaryTargets: try normalize(
                dto.heelerSSHBinaryTargets, label: "heelerSSHBinaryTargets"),
            projectPackages: try normalize(dto.projectPackages, label: "projectPackages"),
            bundledFontFamilies: try normalize(
                dto.bundledFontFamilies, label: "bundledFontFamilies"))
    }
}
