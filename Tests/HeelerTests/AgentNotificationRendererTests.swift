import Foundation
import Testing

@testable import Heeler

/// The service extension's whole job as a pure function: pick the right
/// Notification Key by the envelope's kid, decrypt, and rewrite the alert to
/// workspace, Agent kind, and status — or degrade to the generic fallback banner
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
    /// degrades to the friendly Agent kind and status rather than falling
    /// back to the generic banner.
    @Test func rewritesABlockedPushWithoutDisplayFields() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Claude")
        #expect(alert.body == "Blocked — waiting for input")
    }

    /// The shape the current plugin sends: the workspace leads, the friendly
    /// Agent kind trails it, and the body carries status only.
    @Test func leadsWithTheWorkspaceAndFriendlyAgentKind() throws {
        let vector = try Self.vector(named: "blocked agent with a project and a task title")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Caterm · Claude")
        #expect(alert.body == "Blocked — waiting for input")
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

    @Test func doesNotRenderTheTerminalTask() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "Heeler", agentKind: "codex", status: .done)

        #expect(alert == AgentNotificationAlert(title: "Heeler · Codex", body: "Done"))
    }

    @Test func namesMuseFriendly() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "Heeler", agentKind: "muse", status: .done)

        #expect(alert.title == "Heeler · Muse")
    }

    /// Every kind New Agent can launch gets an explicit label; the raw
    /// protocol id is only the fallback for kinds Heeler does not know.
    @Test(arguments: SupportedAgentKind.allCases)
    func labelsEverySupportedKind(kind: SupportedAgentKind) {
        #expect(AgentNotificationIdentity.kindLabel(kind.rawValue) != kind.rawValue)
    }

    /// Best-effort fields: whitespace-only is the same as absent, so a Host
    /// that resolved a blank never renders a dangling separator.
    @Test func treatsBlankDisplayFieldsAsAbsent() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "  ", agentKind: "claude", status: .blocked)

        #expect(alert.title == "Claude")
        #expect(alert.body == "Blocked — waiting for input")
    }

    /// An unrecognized status still names itself factually.
    @Test func rendersAnUnrecognizedStatusFactually() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "heeler", agentKind: "claude", status: AgentStatus(rawValue: "exited"))

        #expect(alert.body == "Status: exited")
    }

    @Test func rewritesADonePush() throws {
        let vector = try Self.vector(named: "done codex agent under a second key")
        let record = try Self.record(forVector: vector, named: "vps-1")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Codex")
        #expect(alert.body == "Done")
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

        #expect(blockedAlert.title == "Claude")
        #expect(blockedAlert.body == "Blocked — waiting for input")
        #expect(doneAlert.title == "Codex")
        #expect(doneAlert.body == "Done")
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
        #expect(AgentNotificationRenderer.fallback.title == "Heeler")
        #expect(AgentNotificationRenderer.fallback.body == "Agent update")
    }

    // MARK: Detailed alerts (#428)

    /// Off is the default: the same push renders exactly the #260 wording
    /// and carries no custom action.
    @Test func detailedAlertsOffKeepTheDefaultWording() throws {
        let vector = try Self.vector(named: "done agent with a tab label and launch directory (#428)")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert == AgentNotificationAlert(title: "Github · OMP", body: "Done"))
        #expect(alert.actionTitle == nil)
    }

    /// On for the Host whose key opened the envelope: tab in the title, kind
    /// and launch directory in the body, and an action naming the Agent.
    @Test func detailedAlertsOnNameTabDirectoryAndDestination() throws {
        let vector = try Self.vector(named: "done agent with a tab label and launch directory (#428)")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record],
            detailed: { $0 == record.hostID })

        #expect(alert.title == "Github · FIRSTMATE")
        #expect(alert.body == "Done · OMP in ~/Github")
        #expect(alert.actionTitle == "Open Github · FIRSTMATE")
    }

    /// A plugin that predates the new fields degrades one step at a time.
    @Test func detailedAlertsFallBackWithoutTabOrDirectory() throws {
        let vector = try Self.vector(named: "blocked agent with a project and a task title")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record], detailed: { _ in true })

        #expect(alert.title == "Caterm · Claude")
        #expect(alert.body == "Blocked · Claude")
        #expect(alert.actionTitle == "Open Caterm · Claude")
        // The terminal title stays out (#260).
        #expect(!alert.body.contains("排查"))
    }
}

@Suite("Agent notification detail (#428)")
struct AgentNotificationDetailTests {
    @Test func titleUsesTabWhenKnown() {
        #expect(AgentNotificationDetail.title(workspace: "Github", tab: "FIRSTMATE", kind: "omp")
            == "Github · FIRSTMATE")
    }

    @Test func titleFallsBackToWorkspaceAndKind() {
        #expect(AgentNotificationDetail.title(workspace: "Github", tab: nil, kind: "omp")
            == "Github · OMP")
        #expect(AgentNotificationDetail.title(workspace: "Github", tab: "  ", kind: "omp")
            == "Github · OMP")
        #expect(AgentNotificationDetail.title(workspace: nil, tab: "FIRSTMATE", kind: "claude")
            == "Claude")
    }

    @Test func bodyNamesStatusKindAndDirectory() {
        #expect(AgentNotificationDetail.body(status: .done, kind: "omp", directory: "~/Github")
            == "Done · OMP in ~/Github")
        #expect(AgentNotificationDetail.body(status: .blocked, kind: "codex", directory: nil)
            == "Blocked · Codex")
        #expect(AgentNotificationDetail.body(
            status: AgentStatus(rawValue: "exited"), kind: "claude", directory: "")
            == "Status: exited · Claude")
    }

    @Test func actionNamesTheDestination() {
        #expect(AgentNotificationDetail.actionTitle(workspace: "Github", tab: "FIRSTMATE", kind: "omp")
            == "Open Github · FIRSTMATE")
        #expect(AgentNotificationDetail.categoryIdentifier(actionTitle: "Open Github · OMP")
            == "dev.bybee.heeler.agent.open.Open Github · OMP")
    }

    @Test func categoryMergeKeepsOthersAndCapsDetailCategories() {
        let prefix = AgentNotificationDetail.openAgentCategoryPrefix
        let limit = AgentNotificationDetail.categoryLimit
        let old = (0..<limit).map { "\(prefix)\($0)" }
        let merged = AgentNotificationDetail.mergedCategoryIdentifiers(
            existing: ["other"] + old, adding: "\(prefix)new")
        #expect(merged.first == "other")
        #expect(merged.count == limit + 1)
        #expect(!merged.contains("\(prefix)0"))
        #expect(merged.last == "\(prefix)new")

        let moved = AgentNotificationDetail.mergedCategoryIdentifiers(
            existing: ["\(prefix)a", "\(prefix)b"], adding: "\(prefix)a")
        #expect(moved == ["\(prefix)b", "\(prefix)a"])
    }

    @Test func preferenceIsOffByDefaultAndPerHost() throws {
        let suite = "heeler.tests.detailed-alerts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AgentNotificationDetailPreferences(defaults: defaults)
        let host = UUID()
        let other = UUID()

        #expect(!preferences.isEnabled(forHost: host))
        preferences.setEnabled(true, forHost: host)
        #expect(preferences.isEnabled(forHost: host))
        #expect(!preferences.isEnabled(forHost: other))
        preferences.setEnabled(false, forHost: host)
        #expect(!preferences.isEnabled(forHost: host))
    }
}
