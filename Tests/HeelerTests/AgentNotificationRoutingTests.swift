import Foundation
import Testing

@testable import Heeler

/// The deep-link and suppression decisions (#74) as pure functions: kid →
/// Host resolution through the Notification Key records established at
/// registration, pane extraction by decryption, and the presentation-time
/// banner rule. Envelopes come from the shared vectors so routing can never
/// drift from the envelope contract.
///
/// Hand-written pane ids that stand in for a live herdr address use the
/// observed `w…:p…` family (uppercase included). This suite only compares
/// them as opaque strings.
@Suite("Agent notification routing")
struct AgentNotificationRoutingTests {
    private static let vectors = NotificationVectorFile.shared

    private static func vector(named name: String) throws -> NotificationVectorFile.Valid {
        try #require(vectors.valid.first { $0.name == name })
    }

    private static func record(
        forVector vector: NotificationVectorFile.Valid, hostID: UUID
    ) throws -> NotificationKeyRecord {
        let key = try #require(Data(base64URLEncoded: vector.key))
        return NotificationKeyRecord(hostID: hostID, hostName: "mac-studio", key: key)
    }

    @Test func resolvesTheKidToItsHostAndDecryptsThePane() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let hostID = UUID()
        let record = try Self.record(forVector: vector, hostID: hostID)

        let target = AgentNotificationRouting.target(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(target == AgentNotificationTarget(hostID: hostID, paneID: vector.payload.paneId))
    }

    /// Several registered Hosts means several Notification Keys; the kid must
    /// pick the Host whose key it was derived from, not the first record.
    @Test func selectsTheRightHostAmongSeveralByKid() throws {
        let blocked = try Self.vector(named: "blocked claude agent")
        let done = try Self.vector(named: "done codex agent under a second key")
        let blockedHost = UUID()
        let doneHost = UUID()
        let records = [
            try Self.record(forVector: blocked, hostID: blockedHost),
            try Self.record(forVector: done, hostID: doneHost),
        ]

        let blockedTarget = AgentNotificationRouting.target(
            userInfo: ["envelope": blocked.envelope], keys: records)
        let doneTarget = AgentNotificationRouting.target(
            userInfo: ["envelope": done.envelope], keys: records)

        #expect(blockedTarget?.hostID == blockedHost)
        #expect(doneTarget?.hostID == doneHost)
        #expect(doneTarget?.paneID == done.payload.paneId)
    }

    /// An unknown key id — a Host whose registration was removed, or a forged
    /// push — resolves to no target, which routes to the Console quietly.
    @Test func unknownKidResolvesToNoTarget() throws {
        let blocked = try Self.vector(named: "blocked claude agent")
        let done = try Self.vector(named: "done codex agent under a second key")
        let records = [try Self.record(forVector: done, hostID: UUID())]

        let target = AgentNotificationRouting.target(
            userInfo: ["envelope": blocked.envelope], keys: records)

        #expect(target == nil)
    }

    @Test func missingOrNonStringEnvelopeResolvesToNoTarget() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let record = try Self.record(forVector: vector, hostID: UUID())

        #expect(AgentNotificationRouting.target(userInfo: [:], keys: [record]) == nil)
        #expect(AgentNotificationRouting.target(userInfo: ["envelope": 7], keys: [record]) == nil)
    }

    /// Broken framing, future versions, tampered material, wrong keys, and
    /// garbage plaintexts must all resolve to no target, never crash.
    @Test(arguments: vectors.invalid)
    func undecryptableEnvelopeResolvesToNoTarget(vector: NotificationVectorFile.Invalid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        let record = NotificationKeyRecord(hostID: UUID(), hostName: "mac-studio", key: key)

        let target = AgentNotificationRouting.target(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(target == nil, "\(vector.name)")
    }

    @Test func suppressesTheBannerOnlyForThePresentedAgent() {
        let hostID = UUID()
        let target = AgentNotificationTarget(hostID: hostID, paneID: "wV:p1")

        #expect(
            AgentNotificationRouting.shouldSuppressBanner(
                target: target, presentedAgent: ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")))
        // Another pane on the same Host is not "already watching it".
        #expect(
            !AgentNotificationRouting.shouldSuppressBanner(
                target: target, presentedAgent: ConsoleAgent.ID(hostID: hostID, paneID: "w1C:p1")))
        // Pane ids collide across Hosts; the Host must match too.
        #expect(
            !AgentNotificationRouting.shouldSuppressBanner(
                target: target, presentedAgent: ConsoleAgent.ID(hostID: UUID(), paneID: "wV:p1")))
        // On the Console list, nothing is presented.
        #expect(
            !AgentNotificationRouting.shouldSuppressBanner(target: target, presentedAgent: nil))
    }

    /// A push we cannot resolve is never "the one being watched": the banner
    /// (with the extension's generic copy) must show.
    @Test func neverSuppressesAnUnresolvablePush() {
        #expect(
            !AgentNotificationRouting.shouldSuppressBanner(
                target: nil, presentedAgent: ConsoleAgent.ID(hostID: UUID(), paneID: "wV:p1")))
        #expect(!AgentNotificationRouting.shouldSuppressBanner(target: nil, presentedAgent: nil))
    }
}
