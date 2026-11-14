import Foundation

/// Names from `show-environment -s`, filtered on the Host so no value crosses
/// SSH (ADR 0045).
///
/// The Host script strips values from Bourne shell output (`NAME="..."; export NAME;`
/// and `unset NAME;`) and prints one `NAME` per assigned POSIX variable name, or
/// `-NAME` for a name a session removed. Empty assignments (`NAME=""`) still
/// count as set. Any line with `=` or a name `UsageAccountFile.isVariable`
/// rejects is ignored.
enum TmuxEnvironment {
    struct Scope: Equatable, Sendable {
        var assigned: Set<String>
        var removed: Set<String>
    }

    static func parse(_ stdout: Data) -> Scope {
        var assigned: Set<String> = []
        var removed: Set<String> = []
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("-") {
                let name = String(row.dropFirst())
                if UsageAccountFile.isVariable(name) { removed.insert(name) }
            } else if UsageAccountFile.isVariable(row) {
                assigned.insert(row)
            }
        }
        return Scope(assigned: assigned, removed: removed)
    }

    /// Names a new pane in the session gets. The session listing is a delta:
    /// a removal drops a global name, and a session assignment wins when both
    /// name it.
    static func inherited(global: Scope, session: Scope) -> Set<String> {
        global.assigned.subtracting(session.removed).union(session.assigned)
    }

    /// The names ADR 0034's notice is about, from a set of environment names.
    static func leaked(in names: Set<String>) -> Set<String> {
        names.filter { name in
            HerdrCoreEnvironmentCheck.names.contains(name)
                || HerdrCoreEnvironmentCheck.prefixes.contains { name.hasPrefix($0) }
        }
    }

    /// One server's leaked names. `sessions` is each user session's delta.
    /// A leak in the global environment stays even when one session removes
    /// it, because a new session inherits the global names.
    static func reading(global: Scope, sessions: [String: Scope]) -> Set<String> {
        var found = leaked(in: global.assigned)
        for delta in sessions.values {
            found.formUnion(leaked(in: inherited(global: global, session: delta)))
        }
        return found
    }
}
