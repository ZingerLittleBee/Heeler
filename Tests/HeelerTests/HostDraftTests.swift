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

        #expect(!host.usesJumpHost)
        #expect(host.jumpAddress.isEmpty)
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

        #expect(host.jumpUsername.isEmpty)
        #expect(host.resolvedJumpUsername == "dev")
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
            var draft = HostDraft()
            draft.address = "host.example"
            draft.username = "dev"
            draft.sessionName = sessionName

            #expect(!draft.isValid, "unexpectedly accepted session name: \(sessionName)")
        }
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

    @Test func duplicateCopiesEveryFieldUnderACopyNameAsANewHost() throws {
        let original = Host(
            id: UUID(), name: "laya-train", address: "100.64.0.7", port: 2201,
            username: "dev", authMethod: .rsaKey, sessionName: "work",
            jumpAddress: "jump.example", jumpPort: 2022, jumpUsername: "tunnel")

        let draft = HostDraft(
            duplicating: original, password: nil, existingNames: ["laya-train"])
        let copy = try #require(draft.makeHost())

        #expect(copy.id != original.id)
        #expect(copy == Host(
            id: copy.id, name: "laya-train copy", address: "100.64.0.7", port: 2201,
            username: "dev", authMethod: .rsaKey, sessionName: "work",
            jumpAddress: "jump.example", jumpPort: 2022, jumpUsername: "tunnel"))
        #expect(draft.canSave(editing: nil))
    }

    @Test func duplicateCarriesThePasswordOnlyForPasswordHosts() {
        let passwordHost = Host.fixture(authMethod: .password)
        let copied = HostDraft(
            duplicating: passwordHost, password: "hunter2", existingNames: [])
        #expect(copied.password == "hunter2")
        #expect(copied.passwordUpdate == "hunter2")
        #expect(copied.canSave(editing: nil))

        // An unreadable stored password leaves the copy unsavable until
        // one is entered, as for any new password Host.
        let unread = HostDraft(duplicating: passwordHost, password: nil, existingNames: [])
        #expect(unread.password.isEmpty)
        #expect(!unread.canSave(editing: nil))

        let keyHost = Host.fixture(authMethod: .deviceKey)
        let keyCopy = HostDraft(duplicating: keyHost, password: "stale", existingNames: [])
        #expect(keyCopy.password.isEmpty)
    }

    @Test func duplicateNameFollowsFinder() {
        #expect(HostDraft.duplicateName(of: "box", existingNames: ["box"]) == "box copy")
        #expect(
            HostDraft.duplicateName(of: "box", existingNames: ["box", "box copy"])
                == "box copy 2")
        #expect(
            HostDraft.duplicateName(
                of: "box", existingNames: ["box", "box copy", "box copy 2", "box copy 4"])
                == "box copy 3")
        // Duplicating a copy continues its series.
        #expect(
            HostDraft.duplicateName(of: "box copy", existingNames: ["box", "box copy"])
                == "box copy 2")
        #expect(
            HostDraft.duplicateName(
                of: "box copy 2", existingNames: ["box", "box copy", "box copy 2"])
                == "box copy 3")
        // A number without the copy marker belongs to the name.
        #expect(HostDraft.duplicateName(of: "ubuntu 22", existingNames: []) == "ubuntu 22 copy")
        #expect(HostDraft.duplicateName(of: "copy", existingNames: []) == "copy copy")
    }

    @Test func duplicateOfAnUnnamedHostCopiesItsDisplayName() throws {
        let original = Host.fixture(name: "", address: "box.example", username: "dev")

        let draft = HostDraft(
            duplicating: original, password: nil,
            existingNames: [original.displayName])

        #expect(try #require(draft.makeHost()).displayName == "dev@box.example copy")
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

    @Test func duplicatingAnEndpointHostKeepsItsEndpoint() throws {
        let endpoint = try Self.endpoint()
        let original = Host(
            name: "Studio app", address: "studio.local", username: "dev", herdrEndpoint: endpoint)

        let draft = HostDraft(
            duplicating: original, password: nil, existingNames: ["Studio app"])
        let copy = try #require(draft.makeHost())

        #expect(copy.id != original.id)
        #expect(copy.name == "Studio app copy")
        #expect(copy.herdrEndpoint == endpoint)
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
