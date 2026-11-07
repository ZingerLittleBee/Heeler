import Foundation

/// Why an Account change was refused or could not be saved, in the words
/// the Accounts screen shows.
enum AgentAccountError: Error, Equatable, Sendable {
    /// A newer Heeler wrote the Account file; rewriting it could lose what
    /// that version added.
    case unsupportedFileVersion(Int)
    /// The harness's Default Account and three added ones are already listed.
    case limitReached
    /// The directory is already an Account, the Default Account included.
    case alreadyListed
    case notAbsolute
    /// The directory holds none of the harness's own files
    /// (`SupportedAgentKind.accountMarkers`), or is no directory.
    case notHarnessDirectory(SupportedAgentKind)
    case emptyName
    case nameTaken(String)
    /// Another device removed the Account since this list was read.
    case accountNotFound
    /// The Host's plugin predates Accounts; the note names its version.
    case pluginRequirement(String)
    /// The row's last change is still being saved or read back.
    case busy
    /// Not a name an environment variable can have.
    case invalidVariable

    var message: String {
        switch self {
        case .unsupportedFileVersion:
            String(localized: "A newer version of Heeler saved this Host’s Accounts. Update Heeler to change them.")
        case .limitReached:
            String(localized: "A harness can have up to four Accounts on a Host. Remove one to add another.")
        case .alreadyListed:
            String(localized: "This directory is already an Account.")
        case .notAbsolute:
            String(localized: "Choose a directory by its full path.")
        case .notHarnessDirectory(let kind):
            kind.accountMarkers.isEmpty
                ? String(localized: "Choose a folder for \(kind.displayName)’s settings.")
                : String(localized: "This folder has none of \(kind.displayName)’s files. Choose one that holds ")
                    + ListFormatter.localizedString(byJoining: kind.accountMarkers.map(\.label)) + "."
        case .emptyName:
            String(localized: "Enter a name for this Account.")
        case .nameTaken(let name):
            String(localized: "Another Account on this Host is named \(name).")
        case .accountNotFound:
            String(localized: "This Account was already removed. Refresh Usage to see the current list.")
        case .pluginRequirement(let note):
            note
        case .busy:
            String(localized: "The last change here is still being saved. Try again in a moment.")
        case .invalidVariable:
            String(localized: "Enter a variable name of letters, digits and underscores, such as AMP_HOME.")
        }
    }
}

/// `usage-accounts.json` in the Heeler plugin's config directory: the
/// Accounts the user added for each harness (ADR 0030, #621). Claude Code's
/// stay in `claude`, where plugins since 0.8.0 read them; every other
/// harness's sit under `programs`, keyed by its herdr kind. Only the app
/// writes it, with an atomic replace; the plugin's query and worker read it
/// with the rules in `plugin/src/usage/accounts.js`, which this type applies
/// too. An entry the plugin would skip is dropped on the next write; fields
/// this app does not know are carried through it.
struct UsageAccountFile: Codable, Equatable, Sendable {
    static let fileName = "usage-accounts.json"
    static let version = 1
    /// Added Accounts a harness can have on a Host; with its Default
    /// Account, four.
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

    /// One harness's Accounts.
    fileprivate struct Section: Equatable, Sendable {
        /// The Default Account's name; nil shows the app's own "Default".
        var defaultName: String?
        /// The added Accounts, in the order the user added them.
        var accounts: [Account] = []
        /// Suggested directories the user dismissed, and removed Accounts'.
        var ignored: [String] = []
        /// The environment variable the harness reads its config directory
        /// from, when the user named one.
        var variable: String?
        var otherFields: [String: JSONValue] = [:]

        init() {}

        init(_ object: [String: JSONValue]) {
            otherFields = object.filter { !["defaultName", "accounts", "ignored", "variable"].contains($0.key) }
            if let name = object["defaultName"]?.stringValue, UsageAccountFile.isName(name) { defaultName = name }
            if let variable = object["variable"]?.stringValue, UsageAccountFile.isVariable(variable) {
                self.variable = variable
            }
            var ids: Set<String> = []
            var names: Set<String> = defaultName.map { [$0] } ?? []
            if case .array(let entries) = object["accounts"] {
                for case .object(let entry) in entries {
                    guard let id = entry["id"]?.stringValue, UsageAccountFile.isValidID(id), !ids.contains(id),
                        let directory = entry["directory"]?.stringValue, UsageAccountFile.isAbsolute(directory),
                        let name = entry["name"]?.stringValue, UsageAccountFile.isName(name), !names.contains(name)
                    else { continue }
                    ids.insert(id)
                    names.insert(name)
                    var account = Account(id: id, directory: directory, name: name)
                    account.otherFields = entry.filter { !["id", "directory", "name"].contains($0.key) }
                    accounts.append(account)
                }
            }
            if case .array(let paths) = object["ignored"] {
                ignored = paths.compactMap { $0.stringValue }.filter(UsageAccountFile.isAbsolute)
            }
        }

        var json: JSONValue {
            var object = otherFields
            object["defaultName"] = defaultName.map { .string($0) } ?? .null
            object["accounts"] = .array(accounts.map { account in
                var entry = account.otherFields
                entry["id"] = .string(account.id)
                entry["directory"] = .string(account.directory)
                entry["name"] = .string(account.name)
                return .object(entry)
            })
            object["ignored"] = .array(ignored.map { .string($0) })
            if let variable { object["variable"] = .string(variable) }
            return .object(object)
        }

        var isEmpty: Bool {
            defaultName == nil && accounts.isEmpty && ignored.isEmpty && variable == nil && otherFields.isEmpty
        }
    }

    private var claude = Section()
    /// Every other harness's Accounts, by its herdr kind.
    private var programs: [String: Section] = [:]
    private var otherFields: [String: JSONValue] = [:]
    /// Entries under `programs` this app does not read as a harness's.
    private var otherPrograms: [String: JSONValue] = [:]

    /// Claude Code's Default Account name; nil shows the app's own "Default".
    var defaultName: String? { claude.defaultName }
    /// Claude Code's added Accounts, in the order the user added them.
    var accounts: [Account] { claude.accounts }
    /// Claude Code's dismissed suggestions and removed Accounts' directories.
    var ignored: [String] { claude.ignored }

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
            throw AgentAccountError.unsupportedFileVersion(Int(exactly: version) ?? Int.max)
        }
        otherFields = object.filter { !["version", "claude", "programs"].contains($0.key) }
        if case .object(let section) = object["claude"] { claude = Section(section) }
        if case .object(let entries) = object["programs"] {
            for (key, value) in entries {
                // Claude Code's Accounts come from `claude` alone.
                if case .object(let section) = value, key != SupportedAgentKind.claude.rawValue,
                    SupportedAgentKind(rawValue: key) != nil
                {
                    programs[key] = Section(section)
                } else if key != SupportedAgentKind.claude.rawValue {
                    otherPrograms[key] = value
                }
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var object = otherFields
        object["version"] = .number(Double(Self.version))
        object["claude"] = claude.json
        var entries = otherPrograms
        for (key, section) in programs where !section.isEmpty { entries[key] = section.json }
        if !entries.isEmpty { object["programs"] = .object(entries) }
        try JSONValue.object(object).encode(to: encoder)
    }

    /// The file's bytes for an atomic whole-file replace, readable by hand.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private func section(_ kind: SupportedAgentKind) -> Section {
        kind == .claude ? claude : programs[kind.rawValue] ?? Section()
    }

    private mutating func edit<Value>(
        _ kind: SupportedAgentKind, _ change: (inout Section) throws -> Value
    ) rethrows -> Value {
        if kind == .claude { return try change(&claude) }
        var section = programs[kind.rawValue] ?? Section()
        let value = try change(&section)
        programs[kind.rawValue] = section
        return value
    }

    /// `kind`'s added Accounts, in the order the user added them.
    func accounts(for kind: SupportedAgentKind) -> [Account] { section(kind).accounts }

    /// The added Accounts' directories for `kind`, in the file's order.
    func directories(for kind: SupportedAgentKind) -> [String] { accounts(for: kind).map(\.directory) }

    /// `kind`'s dismissed suggestions and removed Accounts' directories.
    func ignored(for kind: SupportedAgentKind) -> [String] { section(kind).ignored }

    /// The variable `kind` reads its config directory from: the one the
    /// user named, else the harness's own; nil when neither is known.
    func variable(for kind: SupportedAgentKind) -> String? {
        section(kind).variable ?? kind.configDirectoryVariable
    }

    /// Names the variable `kind`'s Accounts set; empty forgets it.
    mutating func setVariable(_ variable: String, for kind: SupportedAgentKind) throws {
        let variable = Self.trimmed(variable)
        guard variable.isEmpty || Self.isVariable(variable) else { throw AgentAccountError.invalidVariable }
        edit(kind) { $0.variable = variable.isEmpty || variable == kind.configDirectoryVariable ? nil : variable }
    }

    // MARK: Edits

    /// The Default Account's name as every surface shows it.
    var defaultDisplayName: String { defaultDisplayName(for: .claude) }

    func defaultDisplayName(for kind: SupportedAgentKind) -> String {
        section(kind).defaultName ?? AgentUsageReport.Account.defaultDisplayName
    }

    /// Whether `name` (trimmed) already names an Account of `kind` other
    /// than `accountID`'s, the Default Account's shown name included.
    func isNameTaken(_ name: String, byOtherThan accountID: String? = nil, for kind: SupportedAgentKind = .claude) -> Bool {
        let name = Self.trimmed(name)
        if accountID != Self.defaultAccountID, name == defaultDisplayName(for: kind) { return true }
        return accounts(for: kind).contains { $0.id != accountID && $0.name == name }
    }

    /// Adds `directory` as `kind`'s last Account and returns it. `name`, a
    /// suggestion's, defaults to the directory's base name without leading
    /// dots; either gets " 2", " 3"… while it is taken. `defaultDirectory`
    /// is the Default Account's, which cannot be added again.
    @discardableResult
    mutating func add<Generator: RandomNumberGenerator>(
        directory: String, name: String? = nil, defaultDirectory: String?, for kind: SupportedAgentKind = .claude,
        using generator: inout Generator
    ) throws -> Account {
        guard Self.isAbsolute(directory) else { throw AgentAccountError.notAbsolute }
        let key = Self.comparable(directory)
        let existing = accounts(for: kind)
        guard !existing.contains(where: { Self.comparable($0.directory) == key }),
            defaultDirectory.map(Self.comparable) != key
        else { throw AgentAccountError.alreadyListed }
        guard existing.count < Self.accountLimit else { throw AgentAccountError.limitReached }
        var id = Self.randomID(using: &generator)
        while existing.contains(where: { $0.id == id }) { id = Self.randomID(using: &generator) }
        let account = Account(
            id: id, directory: directory, name: availableName(name ?? Self.baseName(of: directory), for: kind))
        edit(kind) { section in
            section.accounts.append(account)
            section.ignored.removeAll { Self.comparable($0) == key }
        }
        return account
    }

    @discardableResult
    mutating func add(
        directory: String, name: String? = nil, defaultDirectory: String?, for kind: SupportedAgentKind = .claude
    ) throws -> Account {
        var generator = SystemRandomNumberGenerator()
        return try add(
            directory: directory, name: name, defaultDirectory: defaultDirectory, for: kind, using: &generator)
    }

    /// Renames `kind`'s Default Account (`defaultAccountID`) or an added
    /// one. An empty name gives the Default Account back its "Default"; an
    /// added Account needs one.
    mutating func rename(accountID: String, to name: String, for kind: SupportedAgentKind = .claude) throws {
        let name = Self.trimmed(name)
        if accountID == Self.defaultAccountID {
            let shown = name.isEmpty ? AgentUsageReport.Account.defaultDisplayName : name
            guard !accounts(for: kind).contains(where: { $0.name == shown }) else {
                throw AgentAccountError.nameTaken(shown)
            }
            edit(kind) { $0.defaultName = name.isEmpty ? nil : name }
            return
        }
        guard let index = accounts(for: kind).firstIndex(where: { $0.id == accountID }) else {
            throw AgentAccountError.accountNotFound
        }
        guard !name.isEmpty else { throw AgentAccountError.emptyName }
        guard !isNameTaken(name, byOtherThan: accountID, for: kind) else { throw AgentAccountError.nameTaken(name) }
        edit(kind) { $0.accounts[index].name = name }
    }

    /// Removes an added Account; one already gone is not an error. Its
    /// directory joins `ignored` as stored, so the plugin does not suggest
    /// it again right away; adding it back takes it off.
    mutating func remove(accountID: String, for kind: SupportedAgentKind = .claude) {
        edit(kind) { section in
            guard let index = section.accounts.firstIndex(where: { $0.id == accountID }) else { return }
            let directory = section.accounts.remove(at: index).directory
            let key = Self.comparable(directory)
            guard !section.ignored.contains(where: { Self.comparable($0) == key }) else { return }
            section.ignored.append(directory)
        }
    }

    /// Dismisses a suggested directory, so the plugin stops offering it. A
    /// directory that already counts, an added Account's or the Default
    /// Account's (`defaultDirectory`), stays as it is: a suggestion shown
    /// before it was added cannot dismiss it.
    mutating func ignore(directory: String, defaultDirectory: String?, for kind: SupportedAgentKind = .claude) throws {
        guard Self.isAbsolute(directory) else { throw AgentAccountError.notAbsolute }
        let key = Self.comparable(directory)
        guard !accounts(for: kind).contains(where: { Self.comparable($0.directory) == key }),
            defaultDirectory.map(Self.comparable) != key,
            !ignored(for: kind).contains(where: { Self.comparable($0) == key })
        else { return }
        edit(kind) { $0.ignored.append(directory) }
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
    private func availableName(_ name: String, for kind: SupportedAgentKind) -> String {
        let base = Self.isName(name) ? Self.trimmed(name) : "Account"
        guard isNameTaken(base, for: kind) else { return base }
        var suffix = 2
        while isNameTaken("\(base) \(suffix)", for: kind) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private static func randomID<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max, using: &generator))
    }

    fileprivate static func isName(_ name: String) -> Bool { !trimmed(name).isEmpty }

    /// A POSIX environment variable name: a letter or underscore, then
    /// letters, digits or underscores.
    static func isVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
            CharacterSet.letters.contains(first) || first == "_"
        else { return false }
        return name.count <= 64 && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
    }

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// POSIX only, like the usage read.
    fileprivate static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

    /// Two spellings of one directory string compare equal without a
    /// trailing slash; the stored string stays as chosen.
    private static func comparable(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
