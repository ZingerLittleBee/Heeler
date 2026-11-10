import Foundation

/// Names from `show-environment`, never values (ADR 0043).
///
/// A line is `NAME=value` or, in a session listing, `-NAME` for a name that
/// session removed. The value is dropped at the first `=`. An empty `NAME=`
/// still counts as set: once the value is gone, empty cannot be told apart
/// from a value. Junk, and a name `UsageAccountFile.isVariable` rejects, is
/// ignored.
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
                continue
            }
            guard let equals = row.firstIndex(of: "=") else { continue }
            let name = String(row[..<equals])
            guard UsageAccountFile.isVariable(name) else { continue }
            assigned.insert(name)
        }
        return Scope(assigned: assigned, removed: removed)
    }

    /// Names a new pane in the session gets. The session listing is a delta:
    /// a removal drops a global name, and a session assignment wins when both
    /// name it.
    static func inherited(global: Scope, session: Scope) -> Set<String> {
        global.assigned.subtracting(session.removed).union(session.assigned)
    }
}
