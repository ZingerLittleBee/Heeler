import Foundation
import Testing

@testable import HerdrMobile

@Suite("Host draft")
struct HostDraftTests {
    @Test func prefillsFromAnExistingHostAndRoundTripsWithItsID() throws {
        let host = Host(
            id: UUID(), name: "Workbox", address: "box.example", port: 2222,
            username: "dev", authMethod: .password, sessionName: "work",
            socatPath: "/opt/homebrew/bin/socat")

        let draft = HostDraft(host: host)
        let rebuilt = try #require(draft.makeHost(id: host.id))

        #expect(rebuilt == host)
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

    @Test func requiresAnAbsoluteSocatPath() {
        var draft = HostDraft()
        draft.address = "box.example"
        draft.username = "dev"
        draft.socatPath = "socat"
        #expect(!draft.isValid)
        draft.socatPath = "/usr/bin/socat"
        #expect(draft.isValid)
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

    @Test func rejectsSocatPathsThatCannotBeQuotedForTheRemoteShell() {
        for path in ["/tmp/socat'bad", "/tmp/socat\\bad", "/tmp/socat\nbad"] {
            var draft = HostDraft()
            draft.address = "host.example"
            draft.username = "dev"
            draft.socatPath = path

            #expect(!draft.isValid, "unexpectedly accepted socat path: \(path)")
        }
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
}
