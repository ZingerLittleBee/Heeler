import Foundation

/// An invocation token detected at the end of the Composer draft: `/rev`,
/// `$pdf`, `/skill:web`. Detection is suffix-based on purpose — the draft
/// store has no cursor, and command invocations are typed at the end of the
/// draft — so editing earlier text never opens suggestions.
struct SkillSuggestionTrigger: Equatable {
    /// The whole typed token, prefix included.
    let token: String
    /// The invocation prefix the token was recognized by.
    let prefix: String

    /// What the user typed after the prefix; the filter text.
    var query: String { String(token.dropFirst(prefix.count)) }

    /// The token at the end of the draft when it starts with one of the
    /// given prefixes, longest prefix winning so `/skill:` beats `/`. A
    /// token starts at the draft's beginning or after whitespace — `path/to`
    /// never triggers.
    static func detect(draft: String, prefixes: [String]) -> SkillSuggestionTrigger? {
        let token: Substring =
            if let boundary = draft.lastIndex(where: \.isWhitespace) {
                draft[draft.index(after: boundary)...]
            } else {
                draft[...]
            }
        guard !token.isEmpty else { return nil }
        let byLengthDescending = prefixes.sorted { $0.count > $1.count }
        guard let prefix = byLengthDescending.first(where: { token.hasPrefix($0) })
        else { return nil }
        return SkillSuggestionTrigger(token: String(token), prefix: prefix)
    }

    /// The skills worth suggesting for this token: those whose full command
    /// continues it (so `/sk` already offers `/skill:web`), and — once a
    /// query exists — same-prefix skills whose name or description contains
    /// it. Skills on another prefix never match a foreign token.
    func matches(in skills: [AgentSkill]) -> [AgentSkill] {
        skills.filter { skill in
            if skill.command.lowercased().hasPrefix(token.lowercased()) {
                return true
            }
            guard skill.commandPrefix == prefix, !query.isEmpty else { return false }
            return skill.name.localizedStandardContains(query)
                || (skill.description?.localizedStandardContains(query) ?? false)
        }
    }
}
