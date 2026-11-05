import Foundation

extension SupportedAgentKind: Codable {}

/// A named way to start an Agent (#622): a harness, optionally one of its
/// Accounts, arguments placed before the New Agent form's, and any
/// environment. Saved on the device, so one preset serves every Host; `~`,
/// `$HOME` and `${HOME}` stand for each Host's home at launch.
struct LaunchPreset: Codable, Equatable, Identifiable, Sendable {
    /// One environment variable the launch sets.
    struct Variable: Codable, Equatable, Hashable, Sendable {
        var name: String
        var value: String

        /// A row added and left empty, which sets nothing.
        var isBlank: Bool {
            name.trimmingCharacters(in: .whitespaces).isEmpty && value.isEmpty
        }
    }

    /// What a preset hands the launch.
    struct Launch: Equatable, Sendable {
        let arguments: [String]
        let environment: [String: String]
    }

    /// Why a preset cannot launch on a Host, in the words New Agent shows.
    enum Problem: Error, Equatable, Sendable {
        /// The Account's harness has no folder variable, Heeler's or the
        /// user's.
        case noFolderVariable(SupportedAgentKind)
        case arguments(StartAgentStore.ArgumentError)
        case invalidVariableName(String)
        /// A value names the home folder and the Host's is not known.
        case homeUnknown

        var message: String {
            switch self {
            case .noFolderVariable(let kind):
                "Name \(kind.displayName)’s folder variable in this Host’s Accounts to launch one of its Accounts."
            case .arguments(let error): error.message
            case .invalidVariableName(let name): "\(name) is not a variable name."
            case .homeUnknown: "Heeler could not find this Host’s home folder."
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: SupportedAgentKind
    /// The Account's folder as chosen in the Host's Accounts, `~` for the
    /// home; nil launches the harness's Default Account.
    var accountDirectory: String?
    /// Shell-style arguments, parsed into argv without a shell.
    var arguments: String = ""
    /// Set after the Account's folder variable, so one named here wins.
    var environment: [Variable] = []

    /// Whether a value needs the Host's home folder.
    var needsHome: Bool {
        ([accountDirectory].compactMap(\.self) + environment.map(\.value)).contains(where: Self.namesHome)
    }

    /// The launch on a Host whose home is `home`, the harness's folder
    /// variable there being `accountVariable`. The form's arguments follow
    /// the preset's.
    func launch(formArguments: [String], home: String?, accountVariable: String?) throws(Problem) -> Launch {
        let parsed: [String]
        switch StartAgentStore.parseArguments(StartAgentStore.normalizeSmartPunctuation(arguments)) {
        case .success(let arguments): parsed = arguments
        case .failure(let error): throw .arguments(error)
        }
        var environment: [String: String] = [:]
        if let accountDirectory {
            guard let accountVariable else { throw .noFolderVariable(kind) }
            environment[accountVariable] = try Self.expandingHome(accountDirectory, home: home)
        }
        for variable in self.environment where !variable.isBlank {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            guard UsageAccountFile.isVariable(name) else { throw .invalidVariableName(name) }
            environment[name] = try Self.expandingHome(variable.value, home: home)
        }
        return Launch(arguments: parsed + formArguments, environment: environment)
    }

    // MARK: Home

    private static func namesHome(_ value: String) -> Bool {
        value == "~" || value.hasPrefix("~/") || value.contains("${HOME}") || homeVariableRanges(in: value).first != nil
    }

    /// `value` with a leading `~` and every `$HOME` and `${HOME}` replaced
    /// by `home`.
    static func expandingHome(_ value: String, home: String?) throws(Problem) -> String {
        guard namesHome(value) else { return value }
        guard var home, home.hasPrefix("/") else { throw .homeUnknown }
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        var text = value
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + text.dropFirst()
        }
        text = text.replacingOccurrences(of: "${HOME}", with: home)
        for range in homeVariableRanges(in: text).reversed() { text.replaceSubrange(range, with: home) }
        return text
    }

    /// `$HOME` not followed by another identifier character.
    private static func homeVariableRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: "$HOME", range: search) {
            let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if next.map({ !($0.isLetter || $0.isNumber || $0 == "_") }) ?? true { ranges.append(range) }
            search = range.upperBound..<text.endIndex
        }
        return ranges
    }
}
