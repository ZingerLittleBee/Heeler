import Foundation
import Testing

@testable import Heeler

/// Where a core's Terminals land (ADR 0032), from the Terminals, the desktop
/// app's document, first-seen directories and checkout roots. Expected names
/// follow the Herdr desktop app 0.1.9's own tests of `space_name`, `tab_name`
/// and `folder_name`.
@Suite("herdr-core organization")
struct HerdrCoreOrganizationTests {
    private static func record(
        _ address: String, cwd: String = "/work/app", labels: [String: String] = [:],
        parent: String? = nil, state: String = "live", foregroundCwd: String? = nil
    ) throws -> HerdrCoreTerminalRecord {
        var fields: [String: JSONValue] = [
            "address": .string(address), "cwd": .string(cwd), "state": .string(state),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ]
        if let parent { fields["parent"] = .string(parent) }
        if let foregroundCwd {
            fields["foreground"] = .object([
                "pid": .number(9), "name": .string("zsh"), "cwd": .string(foregroundCwd),
            ])
        }
        return try HerdrCoreWire.typed(.object(fields))
    }

    private static func desktop(_ space: String, _ tab: String? = nil) -> [String: String] {
        var labels = ["herdr.space": space]
        if let tab { labels["herdr.tab"] = tab }
        return labels
    }

    private static func document(_ spaces: [JSONValue]) throws -> HerdrCoreDesktopDocument {
        try #require(HerdrCoreDesktopDocument(value: CoreDesktopJSON.document(spaces)))
    }

    private static func build(
        _ terminals: [HerdrCoreTerminalRecord], document: HerdrCoreDesktopDocument? = nil,
        firstSeen: [String: String] = [:], checkouts: [String: String] = [:], home: String? = nil
    ) -> HerdrCoreOrganization.Result {
        HerdrCoreOrganization.build(
            terminals: terminals, document: document, firstSeenDirectories: firstSeen,
            checkouts: checkouts, home: home)
    }

    /// Each Workspace's name, then its Tabs' names, then each Tab's Panes.
    private static func outline(_ result: HerdrCoreOrganization.Result) -> [String] {
        let snapshot = result.snapshot
        return snapshot.workspaces.map { workspace in
            let tabs = snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
                .map { tab in
                    let panes = snapshot.panes.filter { $0.tabID == tab.tabID }.map(\.paneID)
                    return "\(tab.label)(\(panes.joined(separator: " ")))"
                }
            return "\(workspace.label): \(tabs.joined(separator: ", "))"
        }
    }

    // MARK: The document's spaces and tabs

    @Test func labeledTerminalsLandInTheDocumentsSpacesAndTabsInItsOrderUnderItsNames() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s2", name: "Zeta", tabs: [
                CoreDesktopJSON.tab("tb3", name: "logs"), CoreDesktopJSON.tab("tb4", name: "build"),
            ]),
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")]),
        ])
        let result = Self.build(
            [
                try Self.record("t1", labels: Self.desktop("s1", "tb1")),
                try Self.record("t2", labels: Self.desktop("s2", "tb4")),
                try Self.record("t3", labels: Self.desktop("s2", "tb3")),
            ], document: document)

        #expect(Self.outline(result) == ["Zeta: logs(t3), build(t2)", "Alpha: main(t1)"])
        #expect(result.snapshot.workspaces.map(\.number) == [1, 2])
        // Named spaces need no checkout.
        #expect(result.checkoutDirectories.isEmpty)
    }

    @Test func aTabHoldsItsPanesInTheDocumentsTreeOrder() throws {
        let nested: JSONValue = .object([
            "id": .string("tb1"), "name": .string("main"),
            "root": .object([
                "id": .string("tb1"), "type": .string("row"),
                "children": .array([
                    .object([
                        "id": .string("c"), "type": .string("column"),
                        "children": .array([CoreDesktopJSON.block("t3"), CoreDesktopJSON.block("t1")]),
                    ]),
                    // A mod beside the Terminals holds no Terminal.
                    .object([
                        "id": .string("m"), "type": .string("block"),
                        "content": .object(["mod": .string("board")]),
                    ]),
                    CoreDesktopJSON.block("t2"),
                ]),
            ]),
        ])
        let document = try Self.document([CoreDesktopJSON.space("s1", name: "Alpha", tabs: [nested])])
        let result = Self.build(
            ["t1", "t2", "t3", "t4"].map { address in
                (try? Self.record(address, labels: Self.desktop("s1", "tb1")))
            }.compactMap { $0 }, document: document)

        #expect(Self.outline(result) == ["Alpha: main(t3 t1 t2 t4)"])
    }

    @Test func anUnnamedTabReadsItsPlaceAmongTheDocumentsTabsLikeTheDesktopApp() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [
                CoreDesktopJSON.tab("tb1"), CoreDesktopJSON.tab("tb2", name: "review"), CoreDesktopJSON.tab("tb3"),
            ])
        ])
        let store = ConsolePaneRowBuilder(
            host: Host(address: "box", username: "dev", serverKind: .herdrCore),
            inventory: Self.build(
                [
                    try Self.record("t1", labels: Self.desktop("s1", "tb3")),
                    try Self.record("t2", labels: Self.desktop("s1", "tb2")),
                ], document: document
            ).snapshot)
        let rows = store.terminalRows(agents: [:], liveChange: { _ in nil })

        // The third of three, though the first has no Terminal here.
        #expect(rows["t1"]?.displayTabTitle == "Tab 3")
        #expect(rows["t2"]?.displayTabTitle == "Tab \u{201C}review\u{201D}")
    }

    @Test func aSpaceWithNoTerminalHereIsNotListed() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("empty", name: "Empty", tabs: [CoreDesktopJSON.tab("tb9", name: "nothing")]),
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")]),
        ])
        let result = Self.build(
            [try Self.record("t1", labels: Self.desktop("s1", "tb1"))], document: document)

        #expect(Self.outline(result) == ["Alpha: main(t1)"])
    }

    @Test func aTabTheDocumentDoesNotListFollowsItsOwnAndATerminalWithoutOneGetsItsOwn() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
        ])
        let result = Self.build(
            [
                try Self.record("t1", labels: Self.desktop("s1", "new")),
                try Self.record("t2", labels: Self.desktop("s1", "tb1")),
                try Self.record("t3", labels: Self.desktop("s1", "new")),
                try Self.record("t4", labels: Self.desktop("s1")),
            ], document: document)

        #expect(Self.outline(result) == ["Alpha: main(t2), (t1 t3), (t4)"])
    }

    // MARK: A space nobody named

    @Test func aLabelOnlySpaceTakesItsFirstTerminalsCheckoutFolderAfterTheDocumentsSpaces() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
        ])
        let result = Self.build(
            [
                try Self.record(
                    "t1", cwd: "/work/repo/src/deep", labels: Self.desktop("lonely", "tb7")),
                try Self.record("t2", labels: Self.desktop("s1", "tb1")),
                try Self.record("t3", cwd: "/elsewhere", labels: Self.desktop("lonely", "tb7")),
            ], document: document, checkouts: ["/work/repo/src/deep": "/work/repo"])

        #expect(Self.outline(result) == ["Alpha: main(t2)", "repo: (t1 t3)"])
        #expect(result.checkoutDirectories == ["/work/repo/src/deep"])
    }

    @Test func aSpaceTheDocumentLeftUnnamedIsNamedTheSameWay() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", folder: "/fallback", tabs: [
                CoreDesktopJSON.tab("tb1", terminals: ["t2", "t1"])
            ])
        ])
        let result = Self.build(
            [
                try Self.record("t1", cwd: "/work/one", labels: Self.desktop("s1", "tb1")),
                try Self.record("t2", cwd: "/work/two", labels: Self.desktop("s1", "tb1")),
            ], document: document, checkouts: ["/work/two": "/work/checkout"])

        // The first Terminal in the Tab's tree, as the desktop app reads it.
        #expect(result.snapshot.workspaces.map(\.label) == ["checkout"])
        #expect(result.checkoutDirectories == ["/work/two"])
    }

    @Test func aSpaceFollowsItsFirstTerminalsForegroundDirectory() throws {
        let result = Self.build(
            [
                try Self.record(
                    "t1", cwd: "/work/launch", labels: Self.desktop("lonely"),
                    foregroundCwd: "/work/now")
            ], checkouts: ["/work/now": "/work/now-repo"])

        #expect(result.snapshot.workspaces.map(\.label) == ["now-repo"])
        #expect(result.checkoutDirectories == ["/work/now"])
    }

    @Test func untilItsCheckoutIsKnownASpaceReadsItsFolderAndAFolderOutsideGitStaysThat() throws {
        let terminal = try Self.record("t1", cwd: "/work/plain", labels: Self.desktop("lonely"))

        #expect(Self.build([terminal]).snapshot.workspaces.map(\.label) == ["plain"])
        #expect(
            Self.build([terminal], checkouts: ["/work/plain": "/work/plain"])
                .snapshot.workspaces.map(\.label) == ["plain"])
    }

    @Test(arguments: [
        ("/home/can", "/home/can", "~"),
        ("/home/can/", "/home/can", "~"),
        ("/Users/can/Projects/herdr", "/Users/can", "herdr"),
        ("/", "/home/can", "/"),
        ("", "/home/can", "~"),
        (#"C:\Users\can\src\api"#, #"C:\Users\can"#, "api"),
        (#"\\?\C:\Users\can\src\api\"#, #"C:\Users\can"#, "api"),
        ("C:/Users/can/src/web", #"C:\Users\can"#, "web"),
    ])
    func folderNamesReadAsTheDesktopAppReadsThem(path: String, home: String, name: String) {
        #expect(HerdrCoreOrganization.folderName(path, home: home) == name)
    }

    @Test func aSpaceInTheHomeDirectoryReadsTilde() throws {
        let result = Self.build(
            [try Self.record("t1", cwd: "/home/can", labels: Self.desktop("lonely"))],
            checkouts: ["/home/can": "/home"], home: "/home/can")

        #expect(result.snapshot.workspaces.map(\.label) == ["~"])
        // As in the desktop app, git is not asked about the home folder.
        #expect(result.checkoutDirectories.isEmpty)
    }

    // MARK: Children

    @Test func aChildWithoutDesktopLabelsJoinsItsParentsTabAsAnotherPane() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
        ])
        let result = Self.build(
            [
                try Self.record("t1", labels: Self.desktop("s1", "tb1")),
                try Self.record("t2", cwd: "/somewhere/else", parent: "t1"),
                // Heeler's own labels do not make it a desktop Terminal.
                try Self.record(
                    "t3", cwd: "/somewhere/else", labels: ["heeler.source": "app"], parent: "t1"),
                // A subagent's subagent.
                try Self.record("t4", parent: "t2"),
            ], document: document)

        #expect(Self.outline(result) == ["Alpha: main(t1 t2 t3 t4)"])
        let tabs = result.snapshot.tabs
        #expect(tabs.first?.paneCount == 4)
        #expect(result.snapshot.workspaces.first?.paneCount == 4)
    }

    @Test func aChildOfADerivedTerminalJoinsItsTabAndLeavesNoWorkspaceOfItsOwn() throws {
        let result = Self.build(
            [
                try Self.record("t1", cwd: "/work/app"),
                try Self.record("t2", cwd: "/somewhere/else", parent: "t1"),
            ])

        #expect(Self.outline(result) == ["app: (t1 t2)"])
    }

    @Test func aChildWithDesktopLabelsOfItsOwnFollowsThem() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")]),
            CoreDesktopJSON.space("s2", name: "Beta", tabs: [CoreDesktopJSON.tab("tb2", name: "side")]),
        ])
        let result = Self.build(
            [
                try Self.record("t1", labels: Self.desktop("s1", "tb1")),
                try Self.record("t2", labels: Self.desktop("s2", "tb2"), parent: "t1"),
            ], document: document)

        #expect(Self.outline(result) == ["Alpha: main(t1)", "Beta: side(t2)"])
    }

    @Test func anyHerdrLabelMakesItNoSubagentThoughOnlyASpacePlacesIt() throws {
        let result = Self.build(
            [
                try Self.record("t1", cwd: "/work/app"),
                try Self.record(
                    "t2", cwd: "/work/docs", labels: ["herdr.tab": "tb1"], parent: "t1"),
            ])

        #expect(Self.outline(result) == ["app: (t1)", "docs: (t2)"])
    }

    @Test func aChildWhoseParentIsGoneOrLoopsKeepsADerivedWorkspace() throws {
        let result = Self.build(
            [
                try Self.record("t1", state: "finished"),
                try Self.record("t2", cwd: "/work/one", parent: "t1"),
                try Self.record("t3", cwd: "/work/two", parent: "t9"),
                try Self.record("t4", cwd: "/work/loop", parent: "t5"),
                try Self.record("t5", cwd: "/work/loop", parent: "t4"),
            ])

        #expect(Self.outline(result) == ["one: (t2)", "two: (t3)", "loop: (t4), (t5)"])
    }

    // MARK: Every other Terminal

    @Test func aTerminalWithoutDesktopLabelsKeepsItsDerivedWorkspaceAfterTheSpaces() throws {
        let document = try Self.document([
            CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")])
        ])
        let result = Self.build(
            [
                try Self.record("t1", cwd: "/moved/on"),
                try Self.record("t2", labels: Self.desktop("s1", "tb1")),
            ], document: document, firstSeen: ["t1": "/first/seen"])

        #expect(Self.outline(result) == ["Alpha: main(t2)", "seen: (t1)"])
        #expect(
            result.snapshot.workspaces.last?.workspaceID
                == HerdrCoreOrganization.workspaceID(directory: "/first/seen"))
    }

    @Test func labelsWithoutADocumentStillGroupByTheirSpace() throws {
        let result = Self.build(
            [
                try Self.record("t1", cwd: "/work/a", labels: Self.desktop("s1", "tb1")),
                try Self.record("t2", cwd: "/work/b", labels: Self.desktop("s1", "tb1")),
                try Self.record("t3", cwd: "/work/c", labels: Self.desktop("s1", "tb2")),
            ])

        #expect(Self.outline(result) == ["a: (t1 t2), (t3)"])
    }

    // MARK: Reading the document

    @Test func theDocumentReadsOmittedFieldsAndUnknownOnesAsTheDesktopAppDoes() throws {
        let value: JSONValue = .object([
            "future": .bool(true),
            "spaces": .array([
                .object([
                    "id": .string("s"), "color": .string("red"),
                    "tabs": .array([.object(["id": .string("t")])]),
                ])
            ]),
        ])
        let document = try #require(HerdrCoreDesktopDocument(value: value))

        #expect(document.spaces.map(\.id) == ["s"])
        #expect(document.spaces.first?.name == "")
        #expect(document.spaces.first?.folder == "")
        #expect(document.spaces.first?.tabs.map(\.id) == ["t"])
        #expect(document.spaces.first?.tabs.first?.terminals == [])
        #expect(HerdrCoreDesktopDocument(value: .object([:]))?.spaces == [])
    }

    @Test func nothingWrittenOrSomethingUnreadableIsNoDocument() {
        #expect(HerdrCoreDesktopDocument(value: .null) == nil)
        #expect(HerdrCoreDesktopDocument(value: .string("layout")) == nil)
        #expect(HerdrCoreDesktopDocument(value: .object(["spaces": .string("none")])) == nil)
    }
}
