import Foundation

/// A Workflow's agents as its journal records them (Claude Code 2.1.29x):
/// `{"type":"launched"}`, then `started {key, agentId, label, phase}` as each
/// agent starts, and `result {key, agentId, result}` or `failed {key,
/// agentId}` as it ends. Every line starts with its `type`, so a result line
/// cut to its first kilobyte still reads.
///
/// Agents are keyed by `key`: a key started again is the same agent, run
/// again, and its newest start wins. A running Workflow can start more
/// agents, so the count so far is a lower bound until it ends.
struct ClaudeWorkflowJournal: Sendable, Equatable {
    private(set) var agents: [ChatWorkflowProgress.Agent] = []
    private var positions: [String: Int] = [:]
    /// Lines that held no event this fold reads.
    private(set) var unreadableLines = 0

    mutating func apply(_ lines: [ChatLine]) {
        for line in lines {
            apply(line)
        }
    }

    private mutating func apply(_ line: ChatLine) {
        guard let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data,
            let event = try? JSONDecoder().decode(Event.self, from: data), let type = event.type
        else {
            unreadableLines += 1
            return
        }
        let state: ChatWorkflowProgress.Agent.State
        switch type {
        case "started": state = .running
        case "result": state = .done
        case "failed": state = .failed
        default:
            // `launched`, and events this fold does not know.
            return
        }
        guard let key = event.key, !key.isEmpty else {
            unreadableLines += 1
            return
        }
        guard let position = positions[key] else {
            positions[key] = agents.count
            agents.append(ChatWorkflowProgress.Agent(id: key, label: event.label, phase: event.phase, state: state))
            return
        }
        agents[position].state = state
        if let label = event.label { agents[position].label = label }
        if let phase = event.phase { agents[position].phase = phase }
    }

    func progress(updatedAt: Date?) -> ChatWorkflowProgress {
        ChatWorkflowProgress(agents: agents, updatedAt: updatedAt)
    }

    private struct Event: Decodable {
        var type: String?
        var key: String?
        var label: String?
        var phase: String?

        private enum CodingKeys: String, CodingKey { case type, key, label, phase }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            key = try? c.decodeIfPresent(String.self, forKey: .key)
            label = try? c.decodeIfPresent(String.self, forKey: .label)
            phase = try? c.decodeIfPresent(String.self, forKey: .phase)
        }
    }
}
