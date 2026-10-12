import Testing

@testable import Heeler

@Suite("Conversation reference")
struct ConversationReferenceTests {
    private static let claudeID = "E951205E-24AF-4A5E-BAA7-3CCBEBD2DE2C"
    private static let codexID = "01a10f87-e025-7fb1-8974-8dd09937767a"

    private static func session(
        source: String, agent: String, kind: AgentSessionRefKind = .id, value: String
    ) -> AgentSessionInfo {
        AgentSessionInfo(agent: agent, kind: kind, source: source, value: value)
    }

    @Test func bindsOfficialPairsWithLowercasedIDs() {
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:claude", agent: "claude", value: Self.claudeID))
                == .bound(
                    ConversationReference(
                        program: .claude, sessionID: "e951205e-24af-4a5e-baa7-3ccbebd2de2c")))
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:codex", agent: "codex", value: Self.codexID))
                == .bound(ConversationReference(program: .codex, sessionID: Self.codexID)))
    }

    @Test func noSessionBeforeHerdrReportsOne() {
        #expect(ConversationReference.resolve(nil) == .noSession)
    }

    @Test(arguments: [
        ("herdr:pi", "pi", AgentSessionRefKind.id),
        ("herdr:claude", "codex", .id),
        ("custom", "claude", .id),
        ("herdr:claude", "claude", .path),
        ("herdr:codex", "codex", AgentSessionRefKind(rawValue: "name")),
    ])
    func otherPairsAndKindsAreUnsupported(source: String, agent: String, kind: AgentSessionRefKind) {
        #expect(
            ConversationReference.resolve(
                Self.session(source: source, agent: agent, kind: kind, value: Self.codexID))
                == .unsupported)
    }

    @Test(arguments: [
        "../x",
        "my-thread-name",
        "01a10f87e0257fb189748dd09937767a",
        "{01a10f87-e025-7fb1-8974-8dd09937767a}",
        "01a10f87-e025-7fb1-8974-8dd09937767a/../../etc",
        "",
    ])
    func valuesThatAreNotUUIDsCannotBeLocated(value: String) {
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:codex", agent: "codex", value: value))
                == .unidentified)
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:claude", agent: "claude", value: value))
                == .unidentified)
    }
}
