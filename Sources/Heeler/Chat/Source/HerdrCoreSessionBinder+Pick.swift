import Foundation

extension HerdrCoreSessionHint {
    /// The label a confirmed candidate writes, for the process it was confirmed on.
    /// `file` is the session's file when the program's reference is its file.
    static func pickLabelValue(session: String, file: String?, pid: Int, start: String) -> String? {
        var fields: [String: JSONValue] = [
            "session": .string(session), "pid": .number(Double(pid)), "start": .string(start),
        ]
        if let file { fields["file"] = .string(file) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(JSONValue.object(fields)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A pick is the user's word on which conversation an Agent is in, stored as the
/// Terminal's `heeler.chat` label (ADR 0034). It stands only while the Host shows
/// nothing better for that very process: the label counts when its pid and process
/// start match the resolved agent and the check found no exact evidence, and it is
/// removed when anything says it no longer holds.
extension HerdrCoreSessionBinder {
    func applyingPick(
        to evidence: ChatSessionEvidence, record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses
    ) async -> ChatSessionEvidence {
        let labels = await currentLabels() ?? record.labels
        guard let value = labels[HerdrCoreSessionHint.pickLabel] else { return evidence }
        func dropped() async -> ChatSessionEvidence {
            try? await clearLabels([HerdrCoreSessionHint.pickLabel: value])
            return evidence
        }
        guard let hint = HerdrCoreSessionHint(label: value), await !isDroppedPick(value),
            tree.facts[String(hint.pid)]?.start == .value(hint.start)
        else { return await dropped() }
        guard let agent = agentProcess(in: tree) else {
            // Its process is still there, and which one is the Agent cannot be said.
            return unconfirmed(evidence)
        }
        guard agent == String(hint.pid), let process = tree.facts[agent] else { return await dropped() }
        // A session label from this very process is the program saying it moved.
        if let session = labels[HerdrCoreSessionHint.sessionLabel].flatMap(HerdrCoreSessionHint.init(label:)),
            session.pid == hint.pid, session.start == hint.start
        {
            return await dropped()
        }
        guard evidence == cannotTell else { return await dropped() }
        guard let conversation = pickedConversation(hint) else { return await dropped() }
        let root = transcriptRoot(of: process)
        guard root != nil || program == .opencode else { return unconfirmed(evidence) }
        return .picked(sessionID: conversation, transcriptRoot: root)
    }

    /// What a check says with no processes to read: a pick label still there stands
    /// until a check can hold it against them.
    func evidenceWithoutProcesses(in record: HerdrCoreTerminalRecord) async -> ChatSessionEvidence {
        let labels = await currentLabels() ?? record.labels
        guard let value = labels[HerdrCoreSessionHint.pickLabel], await !isDroppedPick(value) else { return cannotTell }
        return unconfirmed(cannotTell)
    }

    private func unconfirmed(_ evidence: ChatSessionEvidence) -> ChatSessionEvidence {
        guard case .unavailable(let reason) = evidence else { return evidence }
        return .pickUnconfirmed(reason)
    }

    /// The id or file the label names, in the form this program's Chat reads it.
    private func pickedConversation(_ hint: HerdrCoreSessionHint) -> String? {
        switch program {
        case .claude, .codex: ConversationReference.canonicalUUID(hint.session)
        case .grok: ConversationReference.lowercaseUUID(hint.session)
        case .opencode: OpenCodeSessionID(hint.session)?.rawValue
        case .pi, .omp: hint.piSession
        }
    }
}
