import Foundation
import Testing

@testable import Heeler

/// The service extension's whole job as a pure function: pick the right
/// Notification Key by the envelope's kid, decrypt, and rewrite the alert to
/// Host, agent kind, and status — or degrade to the generic fallback banner
/// on any undecryptable push (#71). Envelopes come from the shared vectors,
/// so this stays in lockstep with the plugin's encrypt direction.
@Suite("Agent notification renderer")
struct AgentNotificationRendererTests {
    private static let vectors = NotificationVectorFile.shared

    private static func record(
        forVector vector: NotificationVectorFile.Valid, named hostName: String
    ) throws -> NotificationKeyRecord {
        let key = try #require(Data(base64URLEncoded: vector.key))
        return NotificationKeyRecord(hostID: UUID(), hostName: hostName, key: key)
    }

    private static func vector(named name: String) throws -> NotificationVectorFile.Valid {
        try #require(vectors.valid.first { $0.name == name })
    }

    /// A payload from a plugin that predates the display fields: the copy
    /// degrades to the agent kind and a status sentence rather than falling
    /// back to the generic banner.
    @Test func rewritesABlockedPushWithoutDisplayFields() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "claude")
        #expect(alert.body == "Blocked: waiting for your input")
    }

    /// The shape the current plugin sends: the project leads, the agent kind
    /// trails it, and the body says what the agent was doing.
    @Test func leadsWithTheProjectAndTheAgentsTask() throws {
        let vector = try Self.vector(named: "blocked agent with a project and a task title")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Caterm · claude")
        #expect(alert.body == "Blocked · 排查修复 split 按钮 UI 结构问题")
    }

    /// The Host is the same machine on every notification and would spend the
    /// whole title on an address; it must never reach the alert.
    @Test func neverNamesTheHost() throws {
        let vector = try Self.vector(named: "blocked agent with a project and a task title")
        let record = try Self.record(forVector: vector, named: "zingerbee@192.168.31.64")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(!alert.title.contains("zingerbee"))
        #expect(!alert.body.contains("zingerbee"))
    }

    @Test func trimsATaskTitleThatWouldOverrunTheBanner() {
        let long = String(repeating: "重构传输层", count: 40)

        let alert = AgentNotificationRenderer.alert(
            project: "heeler", agentKind: "claude", task: long, status: .done)

        let task = alert.body.dropFirst("Done · ".count)
        #expect(task.count == AgentNotificationRenderer.taskLimit)
        #expect(task.hasSuffix("…"))
        #expect(long.hasPrefix(task.dropLast()))
    }

    /// Best-effort fields: whitespace-only is the same as absent, so a Host
    /// that resolved a blank never renders a dangling separator.
    @Test func treatsBlankDisplayFieldsAsAbsent() {
        let alert = AgentNotificationRenderer.alert(
            project: "  ", agentKind: "claude", task: "\n", status: .blocked)

        #expect(alert.title == "claude")
        #expect(alert.body == "Blocked: waiting for your input")
    }

    /// An unrecognized status still names itself in the short form when there
    /// is a task to pair it with.
    @Test func pairsAnUnrecognizedStatusWithTheTask() {
        let alert = AgentNotificationRenderer.alert(
            project: "heeler", agentKind: "claude", task: "Fix the flaky test",
            status: AgentStatus(rawValue: "exited"))

        #expect(alert.body == "exited · Fix the flaky test")
    }

    @Test func rewritesADonePush() throws {
        let vector = try Self.vector(named: "done codex agent under a second key")
        let record = try Self.record(forVector: vector, named: "vps-1")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "codex")
        #expect(alert.body == "Done: the agent finished")
    }

    /// The status set is open on the wire; an unrecognized value must still
    /// render factually rather than fall back or crash.
    @Test func passesAnUnrecognizedStatusThrough() throws {
        let vector = try Self.vector(named: "unrecognized status string passes through leniently")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.body == "Status: exited")
    }

    /// Several registered Hosts means several Notification Keys; the kid in
    /// the cleartext header must select the right one without trial
    /// decryption. Picking the wrong key yields the generic fallback, so
    /// each envelope rendering its own payload is the proof.
    @Test func selectsTheRightKeyAmongSeveralHostsByKid() throws {
        let blocked = try Self.vector(named: "blocked claude agent")
        let done = try Self.vector(named: "done codex agent under a second key")
        let records = [
            try Self.record(forVector: blocked, named: "mac-studio"),
            try Self.record(forVector: done, named: "vps-1"),
        ]

        let blockedAlert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": blocked.envelope], keys: records)
        let doneAlert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": done.envelope], keys: records)

        #expect(blockedAlert.title == "claude")
        #expect(blockedAlert.body == "Blocked: waiting for your input")
        #expect(doneAlert.title == "codex")
        #expect(doneAlert.body == "Done: the agent finished")
    }

    @Test func unknownKidFallsBackToTheGenericBanner() throws {
        let blocked = try Self.vector(named: "blocked claude agent")
        let done = try Self.vector(named: "done codex agent under a second key")
        // Only the *other* Host's key is registered, so the kid matches nothing.
        let records = [try Self.record(forVector: done, named: "vps-1")]

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": blocked.envelope], keys: records)

        #expect(alert == AgentNotificationRenderer.fallback)
    }

    @Test func noRegisteredKeysFallsBack() throws {
        let vector = try Self.vector(named: "blocked claude agent")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [])

        #expect(alert == AgentNotificationRenderer.fallback)
    }

    /// Every invalid vector — broken framing, future version, tampered
    /// material, wrong key, garbage plaintext — must degrade to the generic
    /// fallback banner even when a plausible key is registered.
    @Test(arguments: vectors.invalid)
    func undecryptableVectorFallsBack(vector: NotificationVectorFile.Invalid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        let record = NotificationKeyRecord(hostID: UUID(), hostName: "mac-studio", key: key)

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert == AgentNotificationRenderer.fallback, "\(vector.name)")
    }

    @Test func pushWithoutAnEnvelopeFallsBack() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        #expect(
            AgentNotificationRenderer.alert(userInfo: [:], keys: [record])
                == AgentNotificationRenderer.fallback)
        #expect(
            AgentNotificationRenderer.alert(userInfo: ["envelope": 42], keys: [record])
                == AgentNotificationRenderer.fallback)
    }

    /// The fallback copy mirrors the relay's generic wrap, so an intercepted
    /// or forged push never renders attacker-chosen text.
    @Test func fallbackCopyIsGeneric() {
        #expect(AgentNotificationRenderer.fallback.title == "herdr")
        #expect(AgentNotificationRenderer.fallback.body == "Agent update")
    }
}
