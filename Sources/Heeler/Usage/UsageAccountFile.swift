import Foundation

/// Why a Claude Code Account change was refused or could not be saved, in
/// the words the Accounts sheet shows.
enum ClaudeAccountError: Error, Equatable, Sendable {
    /// A newer Heeler wrote the Account file; rewriting it could lose what
    /// that version added.
    case unsupportedFileVersion(Int)
    /// The Default Account and three added ones are already listed.
    case limitReached
    /// The directory is already an Account, the Default Account included.
    case alreadyListed
    case notAbsolute
    /// The directory holds neither `.claude.json` nor `projects/`.
    case notClaudeDirectory
    case emptyName
    case nameTaken(String)
    /// Another device removed the Account since this list was read.
    case accountNotFound
    /// The Host's plugin predates Accounts; the note names its version.
    case pluginRequirement(String)

    var message: String {
        switch self {
        case .unsupportedFileVersion:
            "A newer version of Heeler saved this Host’s Accounts. Update Heeler to change them."
        case .limitReached:
            "A Host can have up to four Claude Code Accounts. Remove one to add another."
        case .alreadyListed:
            "This directory is already an Account."
        case .notAbsolute:
            "Choose a directory by its full path."
        case .notClaudeDirectory:
            "This directory has no Claude Code sign-in or Transcripts. Choose one that holds "
                + ".claude.json or a projects folder."
        case .emptyName:
            "Enter a name for this Account."
        case .nameTaken(let name):
            "Another Account on this Host is named \(name)."
        case .accountNotFound:
            "This Account was already removed. Refresh Usage to see the current list."
        case .pluginRequirement(let note):
            note
        }
    }
}

/// `usage-accounts.json` in the Heeler plugin's config directory: the
/// Claude Code Accounts the user added (ADR 0030). Only the app writes it,
/// with an atomic replace; the plugin's query and worker read it with the
/// rules in `plugin/src/usage/accounts.js`, which this type applies too. An
/// entry the plugin would skip is dropped on the next write; fields this
/// app does not know are carried through it.
struct UsageAccountFile: Codable, Equatable, Sendable {
    static let fileName = "usage-accounts.json"
    static let version = 1
    /// Added Accounts a Host can have; with the Default Account, four.
    static let accountLimit = 3
    /// The id the report gives the Default Account; never an added one's.
    static let defaultAccountID = "default"
    /// Ids key the plugin's plain objects, so a name every JavaScript
    /// object already has is refused (`Object.prototype`'s own keys).
    private static let reservedIDs: Set<String> = [
        "default", "constructor", "__proto__", "__defineGetter__", "__defineSetter__",
        "__lookupGetter__", "__lookupSetter__", "hasOwnProperty", "isPrototypeOf",
        "propertyIsEnumerable", "toString", "toLocaleString", "valueOf",
    ]

    struct Account: Equatable, Sendable, Identifiable {
        let id: String
        /// Absolute and kept as chosen, not resolved: Claude Code keys its
        /// keychain item by the string it is given.
        let directory: String
        var name: String
        /// Fields a newer app wrote on this entry.
        fileprivate var otherFields: [String: JSONValue] = [:]

        init(id: String, directory: String, name: String) {
            self.id = id
            self.directory = directory
            self.name = name
        }
    }

    /// The Default Account's name; nil shows the app's own "Default".
    private(set) var defaultName: String?
    /// The added Accounts, in the order the user added them.
    private(set) var accounts: [Account] = []
    /// Suggested directories the user dismissed.
    private(set) var ignored: [String] = []
    private var otherFields: [String: JSONValue] = [:]
    private var otherClaudeFields: [String: JSONValue] = [:]

    /// A Host without the file: no added Accounts.
    init() {}

    /// The file a Host holds. A missing, unreadable or unversioned file
    /// reads as empty, as the plugin reads it; another `version` is a newer
    /// app's file, which this one must not rewrite.
    static func decode(_ data: Data?) throws -> Self {
        guard let data, let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return Self() }
        return try Self(object)
    }

    init(from decoder: any Decoder) throws {
        try self.init(try [String: JSONValue](from: decoder))
    }

    private init(_ object: [String: JSONValue]) throws {
        guard case .number(let version) = object["version"] else { return }
        guard version == Double(Self.version) else {
            throw ClaudeAccountError.unsupportedFileVersion(Int(exactly: version) ?? Int.max)
        }
        otherFields = object.filter { $0.key != "version" && $0.key != "claude" }
        guard case .object(let claude) = object["claude"] else { return }
        otherClaudeFields = claude.filter { !["defaultName", "accounts", "ignored"].contains($0.key) }
        if let name = claude["defaultName"]?.stringValue, Self.isName(name) { defaultName = name }
        var ids: Set<String> = []
        var names: Set<String> = defaultName.map { [$0] } ?? []
        if case .array(let entries) = claude["accounts"] {
            for case .object(let entry) in entries {
                guard let id = entry["id"]?.stringValue, Self.isValidID(id), !ids.contains(id),
                    let directory = entry["directory"]?.stringValue, Self.isAbsolute(directory),
                    let name = entry["name"]?.stringValue, Self.isName(name), !names.contains(name)
                else { continue }
                ids.insert(id)
                names.insert(name)
                var account = Account(id: id, directory: directory, name: name)
                account.otherFields = entry.filter { !["id", "directory", "name"].contains($0.key) }
                accounts.append(account)
            }
        }
        if case .array(let paths) = claude["ignored"] {
            ignored = paths.compactMap { $0.stringValue }.filter(Self.isAbsolute)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var claude = otherClaudeFields
        claude["defaultName"] = defaultName.map { .string($0) } ?? .null
        claude["accounts"] = .array(accounts.map { account in
            var entry = account.otherFields
            entry["id"] = .string(account.id)
            entry["directory"] = .string(account.directory)
            entry["name"] = .string(account.name)
            return .object(entry)
        })
        claude["ignored"] = .array(ignored.map { .string($0) })
        var object = otherFields
        object["version"] = .number(Double(Self.version))
        object["claude"] = .object(claude)
        try JSONValue.object(object).encode(to: encoder)
    }

    /// The file's bytes for an atomic whole-file replace, readable by hand.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Edits

    /// The Default Account's name as every surface shows it.
    var defaultDisplayName: String { defaultName ?? AgentUsageReport.Account.defaultDisplayName }

    /// Whether `name` (trimmed) already names an Account other than
    /// `accountID`'s, the Default Account's shown name included.
    func isNameTaken(_ name: String, byOtherThan accountID: String? = nil) -> Bool {
        let name = Self.trimmed(name)
        if accountID != Self.defaultAccountID, name == defaultDisplayName { return true }
        return accounts.contains { $0.id != accountID && $0.name == name }
    }

    /// Adds `directory` as the last Account and returns it. `name`, a
    /// suggestion's, defaults to the directory's base name without leading
    /// dots; either gets " 2", " 3"… while it is taken. `defaultDirectory`
    /// is the Default Account's, which cannot be added again.
    @discardableResult
    mutating func add<Generator: RandomNumberGenerator>(
        directory: String, name: String? = nil, defaultDirectory: String?,
        using generator: inout Generator
    ) throws -> Account {
        guard Self.isAbsolute(directory) else { throw ClaudeAccountError.notAbsolute }
        let key = Self.comparable(directory)
        guard !accounts.contains(where: { Self.comparable($0.directory) == key }),
            defaultDirectory.map(Self.comparable) != key
        else { throw ClaudeAccountError.alreadyListed }
        guard accounts.count < Self.accountLimit else { throw ClaudeAccountError.limitReached }
        var id = Self.randomID(using: &generator)
        while accounts.contains(where: { $0.id == id }) { id = Self.randomID(using: &generator) }
        let account = Account(id: id, directory: directory, name: availableName(name ?? Self.baseName(of: directory)))
        accounts.append(account)
        ignored.removeAll { Self.comparable($0) == key }
        return account
    }

    @discardableResult
    mutating func add(directory: String, name: String? = nil, defaultDirectory: String?) throws -> Account {
        var generator = SystemRandomNumberGenerator()
        return try add(directory: directory, name: name, defaultDirectory: defaultDirectory, using: &generator)
    }

    /// Renames the Default Account (`defaultAccountID`) or an added one.
    /// An empty name gives the Default Account back its "Default"; an added
    /// Account needs one.
    mutating func rename(accountID: String, to name: String) throws {
        let name = Self.trimmed(name)
        if accountID == Self.defaultAccountID {
            let shown = name.isEmpty ? AgentUsageReport.Account.defaultDisplayName : name
            guard !accounts.contains(where: { $0.name == shown }) else {
                throw ClaudeAccountError.nameTaken(shown)
            }
            defaultName = name.isEmpty ? nil : name
            return
        }
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw ClaudeAccountError.accountNotFound
        }
        guard !name.isEmpty else { throw ClaudeAccountError.emptyName }
        guard !isNameTaken(name, byOtherThan: accountID) else { throw ClaudeAccountError.nameTaken(name) }
        accounts[index].name = name
    }

    /// Removes an added Account; one already gone is not an error. The
    /// directory may be suggested again.
    mutating func remove(accountID: String) {
        accounts.removeAll { $0.id == accountID }
    }

    /// Dismisses a suggested directory, so the plugin stops offering it. A
    /// directory that already counts, an added Account's or the Default
    /// Account's (`defaultDirectory`), stays as it is: a suggestion shown
    /// before it was added cannot dismiss it.
    mutating func ignore(directory: String, defaultDirectory: String?) throws {
        guard Self.isAbsolute(directory) else { throw ClaudeAccountError.notAbsolute }
        let key = Self.comparable(directory)
        guard !accounts.contains(where: { Self.comparable($0.directory) == key }),
            defaultDirectory.map(Self.comparable) != key,
            !ignored.contains(where: { Self.comparable($0) == key })
        else { return }
        ignored.append(directory)
    }

    // MARK: Rules

    /// 8 to 32 characters of `[A-Za-z0-9_-]`, never a reserved name.
    static func isValidID(_ id: String) -> Bool {
        (8...32).contains(id.count) && !reservedIDs.contains(id)
            && id.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
            }
    }

    /// The new Account's name for `directory`: its base name without
    /// leading dots (`~/.claude-2` gives `claude-2`).
    static func baseName(of directory: String) -> String {
        let last = comparable(directory).split(separator: "/").last.map(String.init) ?? ""
        let name = String(last.drop { $0 == "." })
        return name.isEmpty ? "Account" : name
    }

    /// `name`, or the first of `name 2`, `name 3`… no Account has.
    private func availableName(_ name: String) -> String {
        let base = Self.isName(name) ? Self.trimmed(name) : "Account"
        guard isNameTaken(base) else { return base }
        var suffix = 2
        while isNameTaken("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private static func randomID<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max, using: &generator))
    }

    private static func isName(_ name: String) -> Bool { !trimmed(name).isEmpty }

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// POSIX only, like the usage read.
    private static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

    /// Two spellings of one directory string compare equal without a
    /// trailing slash; the stored string stays as chosen.
    private static func comparable(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
