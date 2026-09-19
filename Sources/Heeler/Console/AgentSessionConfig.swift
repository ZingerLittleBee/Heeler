import Foundation

/// The little of omp's configuration the usage strip needs (#325): whether
/// omp itself shows its `tok/s` readout, so the strip shows the same figure
/// exactly when the Agent's own status line would.
///
/// omp keeps `config.yml` beside its `sessions/` directory, so the file is
/// found from the session path herdr reports rather than from a guess about
/// the Host's home or profile. A session stored anywhere else (`--session-dir`)
/// resolves to no config, which reads as the readout being off.
enum AgentSessionConfig {
    /// `…/agent/config.yml` for `…/agent/sessions/<cwd>/<session>.jsonl`.
    static func configPath(forSessionFile path: String) -> String? {
        var components = path.split(separator: "/", omittingEmptySubsequences: false)
        // session file, its cwd directory, then the `sessions` directory.
        guard components.count >= 4, components.removeLast().hasSuffix(".jsonl"),
            !components.removeLast().isEmpty, components.removeLast() == "sessions"
        else { return nil }
        components.append("config.yml")
        return components.joined(separator: "/")
    }

    /// `composer.tokenRate` from the file's contents, false when unset or the
    /// file cannot be read as omp writes it. Only the shape omp's own writer
    /// produces is understood: a top-level `composer:` mapping holding an
    /// indented `tokenRate:` scalar.
    static func showsTokenRate(in contents: Data) -> Bool {
        guard let text = String(data: contents, encoding: .utf8) else { return false }
        var inComposer = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.prefix { $0 != "#" }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indented = line.first?.isWhitespace ?? false
            if !indented {
                inComposer = trimmed == "composer:"
                continue
            }
            guard inComposer, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            guard key == "tokenRate" else { continue }
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return ["true", "yes", "on"].contains(value)
        }
        return false
    }
}
