import Foundation

/// Whose conversation a transcript file holds, read from its first lines
/// (docs/research/claude-code-transcript-format.md, "Location").
///
/// A file is a session's transcript when its first `sessionId` is that
/// session's id and its first chain record is not a subagent's. The second
/// check matters: a subagent file carries its parent's id, so the id alone
/// would accept it.
struct ClaudeFileIdentity: Sendable, Equatable {
    /// The first string `sessionId` the lines hold.
    var sessionID: String?
    /// Whether the first chain record is a sidechain or names an agent; nil
    /// when the lines hold no readable chain record.
    var isSubagent: Bool?

    init(sessionID: String? = nil, isSubagent: Bool? = nil) {
        self.sessionID = sessionID
        self.isSubagent = isSubagent
    }

    /// Lines held only in part (longer than the framer keeps) are skipped:
    /// a prefix of a JSON object cannot be decoded.
    init(lines: [ChatLine]) {
        self.init()
        let decoder = JSONDecoder()
        for line in lines where !line.isTruncated {
            guard let probe = try? decoder.decode(Probe.self, from: line.data) else { continue }
            if sessionID == nil {
                sessionID = probe.sessionID
            }
            if isSubagent == nil, let type = probe.type, ClaudeLine.chainTypes.contains(type), probe.uuid != nil {
                isSubagent = probe.isSidechain == true || probe.agentID != nil
            }
            if sessionID != nil, isSubagent != nil { break }
        }
    }

    /// True for the transcript of session `id`. A file whose first lines
    /// hold no chain record yet is accepted on its id, since subagent files
    /// start with one.
    func accepts(sessionID id: String) -> Bool {
        sessionID == id && isSubagent != true
    }

    private struct Probe: Decodable {
        var type: String?
        var uuid: String?
        var sessionID: String?
        var isSidechain: Bool?
        var agentID: String?

        private enum CodingKeys: String, CodingKey {
            case type, uuid, isSidechain
            case sessionID = "sessionId"
            case agentID = "agentId"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
            uuid = (try? c.decodeIfPresent(String.self, forKey: .uuid)) ?? nil
            sessionID = (try? c.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
            isSidechain = (try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)) ?? nil
            agentID = (try? c.decodeIfPresent(String.self, forKey: .agentID)) ?? nil
        }
    }
}
