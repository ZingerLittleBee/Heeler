import Foundation
import Testing

@testable import Heeler

@Suite("Host draft")
struct HostDraftTests {
    @Test func prefillsFromAnExistingHostAndRoundTripsWithItsID() throws {
        let host = Host(
            id: UUID(), name: "Workbox", address: "box.example", port: 2222,
            username: "dev", authMethod: .password, sessionName: "work")

        let draft = HostDraft(host: host)
        let rebuilt = try #require(draft.makeHost(id: host.id))

        #expect(rebuilt == host)
    }

    @Test func coreKindSurvivesEditing() throws {
        let host = Host(
            name: "Desktop", address: "box.example", username: "dev",
            serverKind: .herdrCore, sessionName: "work")
        let draft = HostDraft(host: host)
        #expect(draft.serverKind == .herdrCore)
        #expect(try #require(draft.makeHost(id: host.id)) == host)
    }

    @Test func aNewDraftIsUnconfirmed() throws {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"
        let host = try #require(draft.makeHost())
        #expect(host.serverKind == .unconfirmed)
    }

    /// Which rule a name answers to depends on the kind the user confirms, and
    /// confirming says why it was refused.
    @Test(arguments: ["work session", "a/b", ".", String(repeating: "a", count: 65)])
    func aNewDraftAcceptsAnySessionNameUntilItsKindIsConfirmed(_ name: String) throws {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"
        draft.sessionName = "  \(name) "

        #expect(try #require(draft.makeHost()).sessionName == name)
    }

    /// `serverKind` has no setter outside the draft, so Edit can only hand the
    /// store the kind the Host already has, whatever else changes.
    @MainActor
    @Test(arguments: [ServerKind.herdrTUI, .herdrCore])
    func editingKeepsTheKindTheStoreRequires(_ kind: ServerKind) throws {
        let host = Host(name: "Desktop", address: "box.example", username: "dev", serverKind: kind)
        let store = HostStore(volatileHosts: [host])
        var draft = HostDraft(host: host)
        draft.name = "Renamed"
        draft.sessionName = "work"
        draft.authMethod = .password
        draft.password = "secret"

        let edited = try #require(draft.makeHost(id: host.id))
        try store.update(edited, password: draft.passwordUpdate)

        #expect(store.hosts.map(\.serverKind) == [kind])
        #expect(store.hosts.map(\.name) == ["Renamed"])
    }

    @Test func anEndpointPairingStaysHerdrTUI() throws {
        let endpoint = try #require(HerdrEndpoint(
            socketPath: "/srv/app/herdr/herdr.sock", executablePath: "/srv/app/bin/herdr"))
        let draft = HostDraft(host: Host(
            address: "box.example", username: "dev", herdrEndpoint: endpoint))
        let saved = try #require(draft.makeHost())
        #expect(saved.serverKind == .herdrTUI)
        #expect(saved.herdrEndpoint == endpoint)
    }

    @Test func prefillsAndRoundTripsAJumpHost() throws {
        let host = Host(
            id: UUID(), name: "Behind NAT", address: "127.0.0.1", port: 12_222,
            username: "dev", sessionName: "work",
            jumpAddress: "jump.example", jumpPort: 2022, jumpUsername: "tunnel")

        let draft = HostDraft(host: host)
        let rebuilt = try #require(draft.makeHost(id: host.id))

        #expect(rebuilt == host)
    }

    @Test func blankJumpAddressMeansDirectConnection() throws {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"

        let host = try #require(draft.makeHost())

        #expect(!host.primaryRoute.usesJumpHost)
        #expect(host.primaryRoute.jumpAddress.isEmpty)
    }

    // The Jump Host port sits in the form even when unused, so an invalid
    // value must not block saving a Host that connects directly.
    @Test func jumpPortOnlyHasToParseWhenAJumpHostIsSet() throws {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"
        draft.jumpPort = "not-a-port"
        #expect(draft.isValid)

        draft.jumpAddress = "jump.example"
        #expect(!draft.isValid)

        draft.jumpPort = "2022"
        #expect(draft.isValid)
    }

    @Test func blankJumpUsernameFallsBackToTheHostAccount() throws {
        var draft = HostDraft()
        draft.address = "127.0.0.1"
        draft.username = "dev"
        draft.jumpAddress = "jump.example"

        let host = try #require(draft.makeHost())

        #expect(host.primaryRoute.jumpUsername.isEmpty)
        #expect(host.jumpUsername(on: host.primaryRoute) == "dev")
    }

    @Test func trimsFieldsOnSave() throws {
        var draft = HostDraft()
        draft.name = " Workbox "
        draft.address = " box.example "
        draft.username = " dev "
        draft.sessionName = " work "

        let host = try #require(draft.makeHost())

        #expect(host.name == "Workbox")
        #expect(host.address == "box.example")
        #expect(host.username == "dev")
        #expect(host.sessionName == "work")
        #expect(host.port == 22)
    }

    @Test func rejectsBlankAddressOrUsername() {
        var draft = HostDraft()
        draft.address = ""
        draft.username = "dev"
        #expect(!draft.isValid)
        #expect(draft.makeHost() == nil)

        draft.address = "box.example"
        draft.username = "   "
        #expect(!draft.isValid)
    }

    @Test(arguments: ["", "0", "65536", "abc", "-1"])
    func rejectsInvalidPorts(port: String) {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"
        draft.port = port
        #expect(!draft.isValid)
    }

    @Test func rejectsSessionNamesHerdrWouldReject() {
        let invalidNames = [
            "work session", "../prod", ".", "..", "work/session", String(repeating: "a", count: 65),
        ]

        for sessionName in invalidNames {
            var draft = HostDraft(host: Host(address: "host.example", username: "dev", serverKind: .herdrTUI))
            draft.sessionName = sessionName

            #expect(!draft.isValid, "unexpectedly accepted session name: \(sessionName)")
        }
    }

    private func coreDraft(sessionName: String) -> HostDraft {
        var draft = HostDraft(host: Host(address: "box.example", username: "dev", serverKind: .herdrCore))
        draft.sessionName = sessionName
        return draft
    }

    @Test(arguments: ["desktop session", "作業", "O'Brien $project `local`", String(repeating: "a", count: 65)])
    func coreDraftsAcceptNamesTheTUIRefuses(_ name: String) throws {
        #expect(try #require(coreDraft(sessionName: name).makeHost()).sessionName == name)

        var tui = HostDraft(host: Host(address: "box.example", username: "dev", serverKind: .herdrTUI))
        tui.sessionName = name
        #expect(!tui.isValid)
    }

    /// hc's `session()` in paths.rs (v0.1.13) trims the name and reads blank as
    /// `default`.
    @Test(arguments: [
        (" work ", "work"), ("\n\twork\r\n", "work"), ("Team space\t", "Team space"),
        ("", "default"), (" \n\t", "default"),
    ])
    func coreDraftsTrimTheSessionNameAsHcDoes(_ typed: String, _ saved: String) throws {
        #expect(try #require(coreDraft(sessionName: typed).makeHost()).sessionName == saved)
    }

    /// Every name hc's `session()` refuses: `.`, `..`, control characters and
    /// the characters a path can't hold, also once trimmed.
    @Test(arguments: [
        ".", "..", " . ", "\n..\t", "a/b", "a\\b", "a:b", "a*b", "a?b", "a\"b", "a<b", "a>b", "a|b",
        "a\tb", "a\nb", "a\u{7f}b", "a\u{85}b", "a\u{0}b",
    ])
    func coreDraftsRefuseNamesHcRefuses(_ name: String) {
        let draft = coreDraft(sessionName: name)
        #expect(!draft.isValid)
        #expect(draft.makeHost() == nil)
    }

    /// The core takes a space; a native Windows Host's `connect` line does not, so
    /// the form says why before Save rather than the Host after it (#587).
    @Test func aCoreHostFoundOnWindowsRefusesWhatItsConnectLineCannotCarry() throws {
        let draft = coreDraft(sessionName: "hwa1103-main x")
        #expect(draft.sessionNameRefusal() == nil)
        #expect(draft.canSave(editing: nil))

        let refusal = try #require(draft.sessionNameRefusal(onNativeWindows: true))
        #expect(refusal == HerdrCoreSessionName.windowsRefusal("hwa1103-main x"))
        #expect(!refusal.hasSuffix(".."))
        #expect(!draft.canSave(editing: nil, onNativeWindows: true))
        #expect(coreDraft(sessionName: "hwa1103-main").canSave(editing: nil, onNativeWindows: true))
    }

    @Test func aRefusalTheCoreMakesIsShownWhereverTheHostIs() {
        let draft = coreDraft(sessionName: "a/b")
        #expect(draft.sessionNameRefusal() == HerdrCoreSessionName.refusal("a/b"))
        #expect(!draft.canSave(editing: nil))
    }

    @Test func acceptsHerdrSessionNameCharacterSetAndLengthLimit() {
        var draft = HostDraft()
        draft.address = "host.example"
        draft.username = "dev"
        draft.sessionName = String(repeating: "a", count: 60) + "._-9"

        #expect(draft.isValid)
    }

    @Test func passwordUpdateOnlyForPasswordAuthWithAnEntry() {
        var draft = HostDraft()
        draft.authMethod = .password
        draft.password = "hunter2"
        #expect(draft.passwordUpdate == "hunter2")

        // Blank means "keep whatever is stored" when editing.
        draft.password = ""
        #expect(draft.passwordUpdate == nil)

        // The device key path stores no password at all.
        draft.authMethod = .deviceKey
        draft.password = "hunter2"
        #expect(draft.passwordUpdate == nil)
    }

    @Test func newPasswordHostRequiresAPassword() {
        var draft = HostDraft()
        draft.address = "host.example"
        draft.username = "dev"
        draft.authMethod = .password

        #expect(!draft.canSave(editing: nil))

        draft.password = "secret"
        #expect(draft.canSave(editing: nil))
    }

    @Test func blankPasswordOnlyKeepsAnExistingPasswordCredential() {
        let passwordHost = Host.fixture(authMethod: .password)
        let keyHost = Host.fixture(authMethod: .deviceKey)
        var draft = HostDraft(host: passwordHost)

        #expect(draft.canSave(editing: passwordHost))

        draft = HostDraft(host: keyHost)
        draft.authMethod = .password
        #expect(!draft.canSave(editing: keyHost))
    }

    /// The form cannot edit an endpoint, so saving an edit must not drop it:
    /// the Host would silently switch to the user's own herdr.
    @Test func editingAnEndpointHostKeepsItsEndpoint() throws {
        let endpoint = try Self.endpoint()
        let host = Host(
            id: UUID(), name: "Studio app", address: "studio.local", username: "dev",
            herdrEndpoint: endpoint)

        var draft = HostDraft(host: host)
        draft.name = "Renamed"
        let rebuilt = try #require(draft.makeHost(id: host.id))

        #expect(draft.herdrEndpoint == endpoint)
        #expect(rebuilt.herdrEndpoint == endpoint)
        #expect(rebuilt.socketLocation == .absolutePath(endpoint.socketPath))
        #expect(rebuilt.name == "Renamed")
    }

    @Test func draftsWithoutAnEndpointMakeHostsWithoutOne() throws {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"
        #expect(draft.herdrEndpoint == nil)
        #expect(try #require(draft.makeHost()).herdrEndpoint == nil)

        let edited = HostDraft(host: Host.fixture())
        #expect(edited.herdrEndpoint == nil)
        #expect(try #require(edited.makeHost()).herdrEndpoint == nil)
    }

    /// A Pairing Code v2 endpoint, as an app bundling herdr publishes it.
    private static func endpoint() throws -> HerdrEndpoint {
        try #require(
            HerdrEndpoint(
                socketPath: "/Users/dev/Library/Application Support/Example/herdr/herdr.sock",
                executablePath: "/Users/dev/Library/Application Support/Example/bin/herdr"))
    }
}
