import Foundation

/// Running totals for one Agent session, folded from the session file the way
/// the Agent itself accounts for them. Pure, so it stays testable without a
/// transport. `refs #325`
///
/// Cost and context do not come from the same place, and neither is a sum of
/// "every usage you can find":
///
/// * **Cost** is billed per assistant turn — plus the spend of any subagent a
///   `task` tool result reports, which belongs to the parent session. Any
///   other tool result bills nothing. Recursing into nested usage objects, or
///   counting every tool result, reports money the Agent never spent.
/// * **Context** is what the provider measured for the prompt of one turn, not
///   the sum of tokens a turn consumed. An entry reports it as
///   `contextSnapshot.promptTokens` minus any history a rewrite removed; only
///   a turn that actually reached a provider anchors it, so an aborted or
///   failed turn must be passed over rather than allowed to blank the figure.
struct AgentSessionUsage: Equatable, Sendable {
    /// Session spend so far. `nil` until an entry carries a billed total, so a
    /// caller can tell "nothing billed yet" from "nothing to bill".
    private(set) var cost: Double?
    /// Prompt size the provider last measured. A snapshot of one request, not
    /// an accumulation: a later qualifying turn replaces it wholesale.
    private(set) var contextTokens: Int?
    /// Model named by the last assistant turn that anchored the context.
    private(set) var model: String?
    /// Provider that turn named, when it did. With `model` it spells the
    /// `provider/model` selector omp's registry is keyed by.
    private(set) var provider: String?

    /// `openai-codex/gpt-6-astra`: the key to ask omp about the model with.
    /// `nil` until a turn has named both halves.
    var modelSelector: String? {
        guard let model, let provider, !provider.isEmpty else { return nil }
        return "\(provider)/\(model)"
    }
    /// Generation speed of the newest assistant turn that reported an output
    /// count, the way omp keeps its `tok/s` readout between turns: billed
    /// output over the turn's wall-clock duration. `nil` until such a turn
    /// exists, and again when the newest one was too short or produced
    /// nothing, exactly as omp blanks its own readout then.
    private(set) var tokensPerSecond: Double?

    /// A turn shorter than this measures nothing; omp's own floor.
    static let minimumRateDurationMilliseconds = 100.0

    init() {}

    /// Folds one line of the session file. Unknown entry kinds, malformed JSON,
    /// and entries without billing leave the totals untouched.
    mutating func fold(line: Data) {
        guard let entry = Self.object(from: line) else { return }
        let kind = entry["type"] as? String
        let message = entry["message"] as? [String: Any]

        let usage: [String: Any]?
        if kind == "model_usage" {
            usage = entry["usage"] as? [String: Any]
        } else if kind == "message", message?["role"] as? String == "assistant" {
            usage = message?["usage"] as? [String: Any]
            adoptContext(from: message, usage: usage)
            adoptRate(from: message, usage: usage)
        } else if kind == "message", message?["role"] as? String == "toolResult",
            message?["toolName"] as? String == "task"
        {
            usage = (message?["details"] as? [String: Any])?["usage"] as? [String: Any]
        } else {
            usage = nil
        }

        guard let total = Self.costTotal(in: usage) else { return }
        // Guard the sum, not just the addend: two enormous bills of the same
        // sign would otherwise overflow a running total to infinity, which
        // would then render as "$inf".
        let sum = (cost ?? 0) + total
        guard sum.isFinite else { return }
        cost = sum
    }

    /// Adopts the model, and the prompt size, of the newest turn that has
    /// something to say.
    ///
    /// A turn that aborted or failed never reached the provider, so its
    /// numbers describe a prompt that was never sent. A turn that reported no
    /// usage at all is likewise silent. Neither may blank what an earlier turn
    /// established — but a turn that did report usage names the model even
    /// when it measured no prompt, so the strip does not lose the model merely
    /// because one turn could not size its prompt.
    private mutating func adoptContext(from message: [String: Any]?, usage: [String: Any]?) {
        guard let message, let usage, !usage.isEmpty else { return }
        if let stop = message["stopReason"] as? String, stop == "aborted" || stop == "error" {
            return
        }
        if let name = message["model"] as? String, !name.isEmpty {
            model = name
            // The provider travels with the model: a turn naming only the
            // model leaves the selector unknown rather than pairing it with
            // an earlier turn's provider.
            provider = message["provider"] as? String
        }
        if let measured = Self.contextTokens(in: message, usage: usage) {
            contextTokens = measured
        }
    }

    /// Mirrors omp's between-turns rate: the newest assistant turn carrying a
    /// numeric output count and timestamp decides it, whatever its stop
    /// reason, and decides it as `nil` when it produced nothing or lasted
    /// under the floor. Turns without an output count are passed over.
    private mutating func adoptRate(from message: [String: Any]?, usage: [String: Any]?) {
        guard
            let message, let usage,
            let output = Self.number(usage["output"]),
            Self.number(message["timestamp"]) != nil
        else { return }
        guard
            output > 0,
            let duration = Self.number(message["duration"]),
            duration >= Self.minimumRateDurationMilliseconds
        else {
            tokensPerSecond = nil
            return
        }
        let rate = output * 1_000 / duration
        tokensPerSecond = rate.isFinite && rate > 0 ? rate : nil
    }

    /// The prompt size the provider measured for this turn: the recorded
    /// snapshot minus any history a rewrite removed, falling back to the
    /// prompt-side usage counters when no snapshot was recorded.
    private static func contextTokens(
        in message: [String: Any], usage: [String: Any]
    ) -> Int? {
        let snapshot = message["contextSnapshot"] as? [String: Any]
        if let prompt = int(snapshot?["promptTokens"]) {
            return max(0, prompt - (int(snapshot?["historyRewriteTokensRemoved"]) ?? 0))
        }
        if let context = int(usage["contextTokens"]) { return context }
        let counters = ["input", "cacheRead", "cacheWrite"].compactMap { int(usage[$0]) }
        guard !counters.isEmpty else { return nil }
        return counters.reduce(0, +)
    }

    /// `$1.50`, or `nil` while nothing has been billed.
    var costText: String? {
        guard let cost else { return nil }
        return String(format: "$%.2f", cost)
    }

    /// `9.5 tok/s`, omp's own format, or `nil` while no turn has a rate.
    var rateText: String? {
        guard let tokensPerSecond else { return nil }
        return String(format: "%.1f tok/s", tokensPerSecond)
    }

    /// `248K`, or `nil` while no turn has measured the prompt.
    var contextText: String? { contextText(window: nil) }

    /// omp's own status-line shape: `11.0%/272K` once the model's window is
    /// known, the bare prompt size (`30K`) until then. A window changes the
    /// reading from a count into a share, which is what lets sessions on
    /// models of different sizes be compared at a glance.
    func contextText(window: Int?) -> String? {
        guard let contextTokens else { return nil }
        guard let window, window > 0 else { return Self.compact(contextTokens) }
        let percent = Double(contextTokens) / Double(window) * 100
        return String(format: "%.1f%%/", percent) + Self.compact(window)
    }

    /// The shape an Agent's own status line uses: one decimal below ten
    /// thousand and from one million up, whole thousands in between, rounding
    /// rather than truncating.
    private static func compact(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 10_000 { return "\(trimmed(Double(value) / 1_000))K" }
        if value < 1_000_000 { return "\(Int((Double(value) / 1_000).rounded()))K" }
        if value < 10_000_000 { return "\(trimmed(Double(value) / 1_000_000))M" }
        return "\(Int((Double(value) / 1_000_000).rounded()))M"
    }

    /// One decimal place, dropping a trailing zero.
    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// `usage.cost.total`, when it is a finite number.
    private static func costTotal(in usage: [String: Any]?) -> Double? {
        guard let cost = usage?["cost"] as? [String: Any] else { return nil }
        return number(cost["total"])
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        // A session file is remote input: `Int(_: Double)` traps on a value it
        // cannot represent, and the fold runs on the main actor. Refuse the
        // value instead of letting it end the app.
        guard number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func object(from line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
