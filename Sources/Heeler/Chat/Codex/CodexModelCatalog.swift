import Foundation

/// One model option offered in the Chat header's Model picker.
struct AgentModelChoice: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var supportedEfforts: [String] = []

    init(id: String, title: String, supportedEfforts: [String] = []) {
        self.id = id
        self.title = title
        self.supportedEfforts = supportedEfforts
    }
}

/// Codex's visible model catalog (`$CODEX_HOME/models_cache.json`) with a
/// built-in fallback from Codex's bundled presets when no cache file is on the
/// Host yet.
struct CodexModelCatalog: Equatable, Sendable {
    static let defaultEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    /// Maximum `models_cache.json` size read over SFTP.
    private static let maximumCacheBytes = 2 << 20

    static let fallback = CodexModelCatalog(
        choices: [
            AgentModelChoice(
                id: "gpt-6.1-sol", title: "GPT-6.1-Sol",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            AgentModelChoice(
                id: "gpt-6-astra", title: "GPT-6-Astra",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            AgentModelChoice(
                id: "gpt-6-sol", title: "GPT-6-Sol",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            AgentModelChoice(
                id: "gpt-6-luna", title: "GPT-6-Luna",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
            AgentModelChoice(
                id: "gpt-5.6-sol", title: "GPT-5.6-Sol",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            AgentModelChoice(
                id: "gpt-6.1-terra", title: "GPT-6.1 Terra",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            AgentModelChoice(
                id: "gpt-5.6-terra", title: "GPT-5.6-Terra",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            AgentModelChoice(
                id: "gpt-5.6-luna", title: "GPT-5.6-Luna",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max"]),
            AgentModelChoice(
                id: "gpt-5.5", title: "GPT-5.5",
                supportedEfforts: ["low", "medium", "high", "xhigh"]),
        ],
        knownTitles: [
            "gpt-daybreak-blue-latest": "Daybreak Blue",
            "gpt-daybreak-red-latest": "Daybreak Red",
            "codex-auto-review": "Codex Auto Review",
        ])

    var choices: [AgentModelChoice]
    /// Lowercased slug to display name for hidden models in the same cache.
    var knownTitles: [String: String] = [:]

    /// How the header names `model`: the catalog's `display_name` when known,
    /// `GPT-…` for standard OpenAI `gpt-…` slugs, or `model` unchanged.
    func displayTitle(for model: String) -> String {
        if let choice = matchingChoice(for: model) {
            return choice.title
        }
        let key = model.lowercased()
        if let title = knownTitles[key] ?? Self.fallback.knownTitles[key] {
            return title
        }
        if let choice = Self.fallback.matchingChoice(for: model) {
            return choice.title
        }
        return Self.formatSlug(model)
    }

    /// Which picker choice `model` corresponds to, matching either a recorded
    /// slug (`gpt-6.1-sol`) or the TUI footer's display name (`GPT-6.1-Sol`).
    func selectedChoiceID(for model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        return matchingChoice(for: model)?.id
    }

    /// Reasoning levels offered for `model`: the model's own supported list
    /// when known, else Codex's standard set.
    func effortChoices(for model: String?) -> [String] {
        if let model, let choice = matchingChoice(for: model), !choice.supportedEfforts.isEmpty {
            return choice.supportedEfforts
        }
        return Self.defaultEfforts
    }

    private func matchingChoice(for model: String) -> AgentModelChoice? {
        choices.first {
            $0.id.caseInsensitiveCompare(model) == .orderedSame
                || $0.title.caseInsensitiveCompare(model) == .orderedSame
        }
    }

    /// Formats `gpt-5.3-codex` → `GPT-5.3-Codex` when no catalog names it;
    /// custom provider IDs (`ollama/…`) and display names stay untouched.
    static func formatSlug(_ model: String) -> String {
        guard model.lowercased().hasPrefix("gpt-"), !model.contains("/"), !model.contains(" ") else {
            return model
        }
        let parts = model.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        return parts.enumerated().map { index, part in
            if index == 0, part.lowercased() == "gpt" { return "GPT" }
            guard let first = part.first, part.allSatisfy(\.isLetter) else { return part }
            return String(first).uppercased() + part.dropFirst()
        }.joined(separator: "-")
    }

    // MARK: Decoding & Host Read

    static func decode(_ data: Data) -> CodexModelCatalog? {
        guard let raw = try? JSONDecoder().decode(RawCache.self, from: data) else { return nil }
        var knownTitles: [String: String] = [:]
        var indexed: [(order: Int, priority: Int, choice: AgentModelChoice)] = []
        for (index, entry) in raw.models.enumerated() {
            guard let slug = entry.slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
                continue
            }
            let display = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (display?.isEmpty == false ? display : nil) ?? formatSlug(slug)
            knownTitles[slug.lowercased()] = title
            guard entry.visibility == nil || entry.visibility == "list" else { continue }
            var efforts: [String] = []
            for level in entry.supportedReasoningLevels {
                let effort = level.effort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !effort.isEmpty, !efforts.contains(effort) {
                    efforts.append(effort)
                }
            }
            indexed.append((
                order: index,
                priority: entry.priority ?? .max,
                choice: AgentModelChoice(id: slug, title: title, supportedEfforts: efforts)
            ))
        }
        indexed.sort { ($0.priority, $0.order) < ($1.priority, $1.order) }
        var seen: Set<String> = []
        var choices: [AgentModelChoice] = []
        for candidate in indexed {
            let key = candidate.choice.id.lowercased()
            guard seen.insert(key).inserted else { continue }
            choices.append(candidate.choice)
        }
        guard !choices.isEmpty else { return nil }
        return CodexModelCatalog(choices: choices, knownTitles: knownTitles)
    }

    static func read(files: ChatHostFiles, configRoot: String? = nil) async throws -> CodexModelCatalog? {
        let roots: [String]
        if let configRoot {
            roots = [configRoot]
        } else {
            let home = try await files.home()
            roots = try await files.configRoots(for: .codex, defaultRoot: RemoteFilePath.join(home, ".codex"))
        }
        return try await ChatHostFiles.firstAnswer(across: roots) { root in
            let path = RemoteFilePath.join(root, "models_cache.json")
            guard let data = try await files.read(
                path: path, from: 0, to: UInt64(Self.maximumCacheBytes), chunk: 256 << 10),
                data.count < Self.maximumCacheBytes
            else { return nil }
            return Self.decode(data)
        }
    }
}

private struct RawCache: Decodable {
    var models: [RawModel]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        guard let list = container.lenient("models", as: CodexLossyArray<RawModel>.self) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "missing models"))
        }
        models = list.elements
    }
}

private struct RawModel: Decodable {
    var slug: String?
    var displayName: String?
    var priority: Int?
    var visibility: String?
    var supportedReasoningLevels: [RawReasoningLevel]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        slug = container.lenient("slug")
        displayName = container.lenient("display_name")
        priority = container.lenient("priority")
        visibility = container.lenient("visibility")
        supportedReasoningLevels =
            container.lenient("supported_reasoning_levels", as: CodexLossyArray<RawReasoningLevel>.self)?.elements ?? []
    }
}

private struct RawReasoningLevel: Decodable {
    var effort: String

    init(from decoder: any Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            effort = bare
            return
        }
        let container = try decoder.container(keyedBy: CodexKey.self)
        guard let value: String = container.lenient("effort") else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "missing effort"))
        }
        effort = value
    }
}

// MARK: - Codex Screen Settings & Switch Outcome

enum CodexSessionScreen {
    static let knownEfforts: Set<String> = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ]

    enum SwitchOutcome: Equatable, Sendable {
        case changed(model: String, effort: String?)
        case failed(String)
    }

    /// Reads the live model and effort from Codex's status line below its
    /// composer before a rollout file exists (`<cwd> · <Model> <effort> …` in
    /// 0.160–0.162, `<Model> <effort>[ Fast] · <cwd>` in 0.169+).
    static func footerSettings(onScreen screen: ANSIScreen) -> (model: String, effort: String?)? {
        guard let composer = CodexComposer.locate(in: screen) else { return nil }
        let rows = screen.rows
        let runs = DialogRowScanner.runs(of: rows[composer.row], from: 2)
        let hasDraft = runs.contains { !DialogRowScanner.isBlank($0) && !$0.style.isDim }
        var start = composer.row + 1
        if hasDraft {
            while start < rows.count, !rows[start].isBlank, (rows[start].indent ?? 0) >= 2 {
                start += 1
            }
        }
        guard start < rows.count else { return nil }
        for row in rows[start...] where !row.isBlank {
            let parts = row.trimmedText.split(separator: "·").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 2,
                parts.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~") })
            else { continue }
            for part in parts {
                guard !part.isEmpty,
                    !part.hasPrefix("/"), !part.hasPrefix("~"),
                    !part.hasPrefix("?"), !part.hasPrefix("←"), !part.hasPrefix("⚠"),
                    !part.hasPrefix("Context "), !part.hasSuffix("…")
                else { continue }
                if let parsed = parseModelSegment(part) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func parseModelSegment(_ segment: String) -> (model: String, effort: String?)? {
        var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 3, words.last?.lowercased() == "fast",
            knownEfforts.contains(words[words.count - 2].lowercased())
        {
            words.removeLast()
        }
        guard words.count >= 2, let rawEffort = words.last?.lowercased(),
            knownEfforts.contains(rawEffort)
        else { return nil }
        let model = words.dropLast().joined(separator: " ")
        guard !model.isEmpty else { return nil }
        return (model: model, effort: rawEffort == "none" ? nil : rawEffort)
    }

    /// Reads the notice Codex prints above its composer after submitting
    /// `command` (`/model <slug>` or `/model --reasoning=<level>`).
    static func switchOutcome(
        since before: ANSIScreen, command: String, on after: ANSIScreen
    ) -> SwitchOutcome? {
        if case .text(let typed) = InputBoxStateDetector.detect(after, program: .codex),
            typed.trimmingCharacters(in: .whitespacesAndNewlines) == command
        {
            return nil
        }
        guard let beforeRows = nonBlankAboveComposer(before),
            let afterRows = nonBlankAboveComposer(after),
            afterRows != beforeRows
        else { return nil }

        var overlapStart = beforeRows.count
        for dropCount in 0...beforeRows.count {
            if afterRows.starts(with: beforeRows.dropFirst(dropCount)) {
                overlapStart = dropCount
                break
            }
        }
        let added = Array(afterRows.dropFirst(beforeRows.count - overlapStart))
        guard !added.isEmpty else { return nil }

        for bullet in logicalBullets(added).reversed() {
            if let parsed = parseChangedBullet(bullet, prefix: "• Model changed to ")
                ?? parseChangedBullet(bullet, prefix: "• Selected ")
            {
                return .changed(model: parsed.model, effort: parsed.effort)
            }
            if bullet.hasPrefix("■ ") || bullet.hasPrefix("✘ ") {
                let message = String(bullet.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !message.isEmpty { return .failed(message) }
            }
        }
        return nil
    }

    private static func nonBlankAboveComposer(_ screen: ANSIScreen) -> [String]? {
        guard let composer = CodexComposer.locate(in: screen) else { return nil }
        return screen.rows[..<composer.row].map(\.trimmedText).filter { !$0.isEmpty }
    }

    private static func logicalBullets(_ lines: [String]) -> [String] {
        let starters = ["• ", "■ ", "✘ ", "› ", "» "]
        var bullets: [String] = []
        for line in lines {
            if starters.contains(where: { line.hasPrefix($0) }) || bullets.isEmpty {
                bullets.append(line)
            } else {
                bullets[bullets.count - 1] += " " + line
            }
        }
        return bullets
    }

    private static func parseChangedBullet(
        _ bullet: String, prefix: String
    ) -> (model: String, effort: String?)? {
        guard bullet.hasPrefix(prefix) else { return nil }
        var rest = String(bullet.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if let forRange = rest.range(of: " for ") {
            rest = String(rest[..<forRange.lowerBound])
        } else if rest.hasSuffix(".") {
            rest.removeLast()
        }
        let tokens = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let model = tokens.first, !model.isEmpty else { return nil }
        let effort: String?
        if tokens.count >= 2, knownEfforts.contains(tokens[1].lowercased()) {
            let level = tokens[1].lowercased()
            effort = level == "none" ? nil : level
        } else {
            effort = nil
        }
        return (model: model, effort: effort)
    }
}
