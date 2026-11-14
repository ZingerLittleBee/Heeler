import Foundation

/// Models Antigravity CLI offers on a Host (`agy models`), grouped into
/// families and effort levels the way agy's own `/model` picker groups them.
///
/// Unlike Claude Code's fixed alias shortcuts, agy's catalog depends on the
/// account or gateway signed in on the Host (`Google AI Ultra`, API key,
/// Vertex AI, or Enterprise Model Gateway). Multi-effort families appear as
/// separate rows (`gemini-4-carbon-medium` / `Gemini 4 Carbon (Medium)`,
/// `gemini-4-carbon-high` / `Gemini 4 Carbon (High)`, …), while single-variant
/// models (`gpt-oss-120b-medium`, `gemini-pro-orchestrator`) appear once and
/// refuse `/effort`.
enum AgyModelCatalog {
    static let effortOrder = ["low", "medium", "high", "xhigh", "max"]

    /// Fallback catalog (Antigravity CLI 1.5.9, Google AI Ultra) used when
    /// `agy models` cannot query the account from a non-interactive SSH exec —
    /// notably macOS `sshd` public-key logins, whose `Background` session
    /// leaves `login.keychain-db` locked while `herdr` in the GUI session is
    /// signed in — or on transports without POSIX shell exec (`herdr-core`,
    /// native Windows).
    static let defaultChoices: [Choice] = parse(Data("""
        gemini-4-carbon-medium         Gemini 4 Carbon (Medium)
        gemini-4-carbon-high           Gemini 4 Carbon (High)
        gemini-4-carbon-low            Gemini 4 Carbon (Low)
        gemini-4-argon-medium          Gemini 4 Argon (Medium)
        gemini-4-argon-high            Gemini 4 Argon (High)
        gemini-4-argon-low             Gemini 4 Argon (Low)
        gemini-4-hydrogen-high         Gemini 4 Hydrogen (High)
        gemini-4-hydrogen-xhigh        Gemini 4 Hydrogen (XHigh)
        gemini-4-hydrogen-medium       Gemini 4 Hydrogen (Medium)
        gemini-4-hydrogen-low          Gemini 4 Hydrogen (Low)
        gemini-pro-orchestrator        Orchestrator (Carbon)
        gemini-pro-orchestrator-argon  Orchestrator (Argon)
        gemini-3.8-flash-high          Gemini 3.8 Flash (High)
        gemini-3.8-flash-medium        Gemini 3.8 Flash (Medium)
        gemini-3.8-flash-low           Gemini 3.8 Flash (Low)
        claude-opus-5-5-low            Claude Opus 5.5 (Low)
        claude-opus-5-5-medium         Claude Opus 5.5 (Medium)
        claude-opus-5-5-high           Claude Opus 5.5 (High)
        claude-sonnet-5-5-low          Claude Sonnet 5.5 (Low)
        claude-sonnet-5-5-medium       Claude Sonnet 5.5 (Medium)
        claude-sonnet-5-5-high         Claude Sonnet 5.5 (High)
        gpt-oss-120b-medium            GPT-OSS 120B (Medium)
        """.utf8))

    struct Choice: Equatable, Sendable {
        /// Stable picker tag: the family slug (`gemini-4-carbon`) when two or
        /// more effort rows share a family, otherwise the model's exact slug.
        let id: String
        /// Menu title (`Gemini 4 Carbon`, `GPT-OSS 120B (Medium)`, …).
        let title: String
        /// First slug `agy models` listed for this choice (its default variant).
        let defaultSlug: String
        /// Supported `/effort` levels in canonical order; empty when effort is fixed.
        let efforts: [String]
        /// Exact `agy models` slug per effort level.
        let variantSlugs: [String: String]

        /// Exact `agy models` slug to pass to `/model`, keeping `effort` when
        /// the chosen family offers it and falling back to `defaultSlug`.
        func slug(preferringEffort effort: String?) -> String {
            if let effort = effort?.lowercased(), !effort.isEmpty, let match = variantSlugs[effort] {
                return match
            }
            return defaultSlug
        }

        /// Matches a footer or transcript model name or slug against this choice.
        func matches(model: String?) -> Bool {
            guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return false
            }
            if raw.caseInsensitiveCompare(id) == .orderedSame
                || raw.caseInsensitiveCompare(title) == .orderedSame
                || raw.caseInsensitiveCompare(defaultSlug) == .orderedSame
            {
                return true
            }
            if variantSlugs.values.contains(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
                return true
            }
            if efforts.isEmpty {
                let stripped = AgyModelCatalog.splitDisplayLabel(title).model
                if stripped.caseInsensitiveCompare(raw) == .orderedSame {
                    return true
                }
            }
            return false
        }
    }

    /// POSIX `/bin/sh` body for `HeelerSSHTransport.runBoundedScript`: prepends
    /// user-local/mise/Homebrew paths plus `~/.antigravity/bin` and lists models.
    static var script: Data {
        let lines = [
            "LC_ALL=C",
            "export LC_ALL",
            HerdrHostPath.pathExport,
            "PATH=\"$PATH:$HOME/.antigravity/bin\"",
            "exec agy models",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Parses `agy models` stdout into menu choices.
    static func parse(_ output: Data) -> [Choice] {
        let text = String(decoding: output, as: UTF8.self)
        struct RawEntry {
            let slug: String
            let label: String
            let familyKey: String?
            let baseSlug: String?
            let baseLabel: String?
            let effort: String?
        }

        var entries: [RawEntry] = []
        var seenSlugs: Set<String> = []
        var familyCounts: [String: Int] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedCR = rawLine.replacing(/\r+$/, with: "")
            let afterCR = trimmedCR.split(separator: "\r", omittingEmptySubsequences: false).last ?? trimmedCR[...]
            let clean = String(afterCR).replacing(/\x1B\[[0-9;]*[A-Za-z]/, with: "")
            guard let match = clean.wholeMatch(of: /^\s*([A-Za-z0-9._:\/+-]+)\s{2,}(.+\S)\s*$/) else {
                continue
            }
            let slug = String(match.1)
            let label = String(match.2)
            let slugKey = slug.lowercased()
            guard seenSlugs.insert(slugKey).inserted else { continue }

            let splitLabel = splitDisplayLabel(label)
            if let effort = splitLabel.effort,
                let baseSlug = stripEffortSuffix(effort, fromSlug: slug)
            {
                let key = "\(baseSlug.lowercased())\u{0}\(splitLabel.model.lowercased())"
                familyCounts[key, default: 0] += 1
                entries.append(RawEntry(
                    slug: slug, label: label, familyKey: key,
                    baseSlug: baseSlug, baseLabel: splitLabel.model, effort: effort))
            } else {
                entries.append(RawEntry(
                    slug: slug, label: label, familyKey: nil,
                    baseSlug: nil, baseLabel: nil, effort: nil))
            }
        }

        var groupedByKey: [String: (baseSlug: String, baseLabel: String, defaultSlug: String, variants: [String: String])] = [:]
        for entry in entries {
            guard let key = entry.familyKey, (familyCounts[key] ?? 0) >= 2,
                let baseSlug = entry.baseSlug, let baseLabel = entry.baseLabel, let effort = entry.effort
            else { continue }
            if var existing = groupedByKey[key] {
                if existing.variants[effort] == nil {
                    existing.variants[effort] = entry.slug
                    groupedByKey[key] = existing
                }
            } else {
                groupedByKey[key] = (baseSlug, baseLabel, entry.slug, [effort: entry.slug])
            }
        }

        var choices: [Choice] = []
        var emittedFamilies: Set<String> = []
        for entry in entries {
            if let key = entry.familyKey, let group = groupedByKey[key] {
                guard emittedFamilies.insert(key).inserted else { continue }
                let orderedEfforts = effortOrder.filter { group.variants[$0] != nil }
                choices.append(Choice(
                    id: group.baseSlug,
                    title: group.baseLabel,
                    defaultSlug: group.defaultSlug,
                    efforts: orderedEfforts,
                    variantSlugs: group.variants))
            } else {
                choices.append(Choice(
                    id: entry.slug,
                    title: entry.label,
                    defaultSlug: entry.slug,
                    efforts: [],
                    variantSlugs: [:]))
            }
        }
        return choices
    }

    /// Splits `"Gemini 4 Carbon (High)"` into `("Gemini 4 Carbon", "high")`,
    /// leaving non-effort parentheticals such as `"Orchestrator (Carbon)"` intact.
    static func splitDisplayLabel(_ label: String) -> (model: String, effort: String?) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /^(.+\S)\s+\(([A-Za-z]+)\)$/) else {
            return (trimmed, nil)
        }
        let candidate = match.2.lowercased()
        guard effortOrder.contains(candidate) else {
            return (trimmed, nil)
        }
        return (String(match.1), candidate)
    }

    /// Resolves a confirmed `Model set to <Label>` label against `choices` so
    /// single-entry models like `"GPT-OSS 120B (Medium)"` keep their full title
    /// and report no adjustable effort.
    static func resolveDisplayLabel(_ label: String, in choices: [Choice]) -> (model: String, effort: String?) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let single = choices.first(where: { $0.efforts.isEmpty && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return (single.title, nil)
        }
        return splitDisplayLabel(trimmed)
    }

    /// Resolves a `PLANNER_RESPONSE` `"model"` slug (such as
    /// `"gemini-4-carbon-high"` or `"gemini-pro-orchestrator"`) into the
    /// display family and optional adjustable effort.
    static func resolveModelSlug(
        _ rawSlug: String, in choices: [Choice] = defaultChoices
    ) -> (model: String, effort: String?)? {
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, slug != "None" else { return nil }
        if slug.contains(" ") {
            return resolveDisplayLabel(slug, in: choices)
        }
        for choice in choices {
            for effort in choice.efforts {
                if choice.variantSlugs[effort]?.caseInsensitiveCompare(slug) == .orderedSame {
                    return (choice.title, effort)
                }
            }
            if choice.efforts.isEmpty, choice.defaultSlug.caseInsensitiveCompare(slug) == .orderedSame {
                return (choice.title, nil)
            }
            if choice.id.caseInsensitiveCompare(slug) == .orderedSame {
                return (choice.title, nil)
            }
        }
        for effort in effortOrder {
            if let baseSlug = stripEffortSuffix(effort, fromSlug: slug) {
                return (baseSlug, effort)
            }
        }
        return (slug, nil)
    }

    private static func stripEffortSuffix(_ effort: String, fromSlug slug: String) -> String? {
        let suffix = "-\(effort)"
        guard slug.lowercased().hasSuffix(suffix), slug.count > suffix.count else { return nil }
        return String(slug.dropLast(suffix.count))
    }
}
