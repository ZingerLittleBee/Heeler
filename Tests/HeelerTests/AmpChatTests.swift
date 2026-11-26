import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Amp Chat")
struct AmpChatTests {
    @Test func foregroundAndDirectoryBelongToOneProcess() throws {
        let pid = 101
        let amp = PaneProcessInfoProcess(name: "amp", pid: pid)
        let one = PaneProcessInfo(paneID: "pane", foregroundProcesses: [amp])
        #expect(AmpPluginLocation.foreground(one) == pid)
        let two = PaneProcessInfo(paneID: "pane", foregroundProcesses: [amp, .init(name: "amp", pid: 102)])
        #expect(AmpPluginLocation.foreground(two) == nil)
        var facts = HostProcessReader.Facts()
        facts.start = .value("123")
        facts.variables = ["HOME": .value("/users/test"), "XDG_CONFIG_HOME": .value("/data/amp-config")]
        #expect(AmpPluginLocation(pid: pid, facts: facts)?.directory == "/data/amp-config/amp/plugins")
        facts.variables["XDG_CONFIG_HOME"] = .unset
        #expect(AmpPluginLocation(pid: pid, facts: facts)?.directory == "/users/test/.config/amp/plugins")
        facts.variables["XDG_CONFIG_HOME"] = .unavailable
        #expect(AmpPluginLocation(pid: pid, facts: facts) == nil)
    }

    @Test func repeatedMessagesAndUpdatedToolResultsKeepTheirOwnIDs() throws {
        func line(_ index: UInt64, _ json: String) -> ChatLine { .init(offset: index, data: Data(json.utf8)) }
        let first = line(0, #"{"id":"n:1","role":"user","blocks":[{"type":"text","text":"same"}]}"#)
        let second = line(3, #"{"id":"s:1","role":"user","blocks":[{"type":"text","text":"same"}]}"#)
        let call = line(1, #"{"id":"s:a","role":"assistant","blocks":[{"type":"tool_use","call":"x","name":"Read","text":"file"}]}"#)
        let done = line(2, #"{"id":"s:b","role":"user","blocks":[{"type":"tool_result","call":"x","status":"done","text":"ok"}]}"#)
        var reducer = AmpTranscriptReducer()
        reducer.append([second])
        reducer.prepend([first, call, done])
        reducer.append([done, second])
        let result = reducer.transcript(.init())
        #expect(result.entries.count == 3)
        #expect(result.recordedPrompts.map(\.text) == ["same", "same"])
        #expect(Set(result.entries.map(\.id)).count == 3)
        guard case .tool(let tool) = result.entries[1].content else { Issue.record("Missing tool call"); return }
        #expect(tool.status == .succeeded)
        #expect(tool.preview?.text == "ok")
    }

    @Test func terminalDraftAndCommandPaletteHoldChatSend() async throws {
        let ready = try ScreenFixture.text("amp-01-idle")
        let screens = [
            ready.replacingOccurrences(of: "│        ", with: "│ draft  "),
            try ScreenFixture.text("amp-02-command-palette"),
            "Unknown screen",
        ]
        let rules = ChatSendRules(program: .amp, commands: [])
        #expect(rules.outgoingText("hello") == "hello")
        for value in screens {
            let policy = ComposerDeliveryPolicy.chat(rules: rules, activity: { .idle },
                readScreen: { ANSIScreenDecoder.decode(value) })
            guard case .inputNotReady = await policy.preflight?("hello") else {
                Issue.record("An occupied or unrecognized screen must hold Amp Send"); continue
            }
        }
    }

    @Test func installationDistinguishesAnAbsentDirectoryFromAnOccupiedPath() async throws {
        var facts = HostProcessReader.Facts()
        facts.start = .value("123")
        facts.variables = ["HOME": .value("/home/test"), "XDG_CONFIG_HOME": .unset]
        let location = try #require(AmpPluginLocation(pid: 123, facts: facts))
        func files(_ list: @escaping @Sendable (RemoteFileListingRequest) async throws -> RemoteFileListing?) -> ChatHostFiles {
            ChatHostFiles(status: { _ in nil }, list: list, read: { _ in throw AmpChatProblem.unreachable },
                          home: { "/home/test" })
        }
        #expect(try await location.installationProblem(files { _ in throw TransportError.hostFileUnreadable(status: 2) }) == .missing)
        #expect(try await location.installationProblem(files { _ in
            .init(entries: [.init(name: "heeler-chat.js", status: .init(kind: .symlink, size: 0))])
        }) == .conflict)
    }
}
