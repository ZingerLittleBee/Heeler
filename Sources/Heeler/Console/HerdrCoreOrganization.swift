import CryptoKit
import Foundation

/// Fills the Console's snapshot shape from a core's Terminals (ADR 0032). A core
/// has no Workspaces or Tabs. A Terminal labeled `herdr.space` lands in that
/// desktop space and its `herdr.tab`, under the names and order of the desktop
/// app's document. A Terminal with no `herdr.*` label started from inside another
/// joins that Terminal's Tab as another Pane. Every other Terminal lands in a
/// derived Workspace keyed by the directory this device first saw it launched in,
/// as its own Tab. That directory, not the Terminal's current launch directory, is
/// the key: a kept Terminal that restarts elsewhere stays where it is.
///
/// Labels place Terminals and authorize nothing: any process on the core can
/// rewrite them.
enum HerdrCoreOrganization {
    struct Result: Sendable {
        let snapshot: SessionSnapshot
        /// The directories whose Checkouts these Workspaces are in: one for each
        /// Workspace, which also names an unnamed space.
        let checkoutDirectories: [String]
    }

    private struct PlannedTab {
        let id: String
        let label: String
        /// The desktop app's order of its Panes, for a Tab its document lists.
        var treeOrder: [String] = []
        var panes: [HerdrCoreTerminalRecord] = []
    }

    private struct PlannedWorkspace {
        let id: String
        /// Empty for a desktop space nobody named.
        let label: String
        var folder = ""
        var isDesktopSpace = false
        var isAmuxWorktree = false
        /// The directory a derived Workspace is keyed by.
        var keyDirectory = ""
        var tabs: [PlannedTab] = []
    }

    /// Finished Terminals stay out, though the core keeps their records until
    /// they are removed, and so does a space with no Terminal left to show.
    /// `doneTerminals` are those whose Agent reads Done on this device, as long
    /// as it still reports idle or done.
    static func build(
        terminals: [HerdrCoreTerminalRecord],
        document: HerdrCoreDesktopDocument?,
        firstSeenDirectories: [String: String],
        checkouts: [String: HostCheckout],
        home: String?,
        doneTerminals: Set<String> = [],
        amux: AmuxOrganizationDocument? = nil
    ) -> Result {
        let shown = terminals.filter { !$0.hasFinished }
        let shownByAddress = Dictionary(shown.map { ($0.address, $0) }) { first, _ in first }

        let amuxWorktrees = (amux?.spaces ?? []).flatMap { space in
            space.worktrees.map { worktree in
                PlannedWorkspace(
                    id: worktree.workspaceID(coreID: amux?.coreID ?? ""), label: "\(space.name) / \(worktree.name)",
                    isAmuxWorktree: true, keyDirectory: worktree.path,
                    tabs: worktree.tabs.map { tab in
                        PlannedTab(
                            id: tab.tabID, label: tab.name, treeOrder: tab.terminals,
                            panes: tab.terminals.compactMap { shownByAddress[$0] })
                    })
            }
        }
        let assigned = Set(amuxWorktrees.flatMap { $0.tabs.flatMap { $0.panes.map(\.address) } })
        let unassigned = shown.filter { !assigned.contains($0.address) }
        let spaces = plannedSpaces(shown: unassigned, document: document)
        var derived: [PlannedWorkspace] = []
        var children: [String: [HerdrCoreTerminalRecord]] = [:]
        for record in unassigned where desktopLabel("herdr.space", of: record) == nil {
            let host = amux == nil ? placementHost(of: record, shown: shownByAddress) : record
            if host.address != record.address {
                children[host.address, default: []].append(record)
            } else {
                place(
                    record,
                    inDirectory: firstSeenDirectories[record.address] ?? record.cwd,
                    derived: &derived)
            }
        }

        var workspaces: [WorkspaceInfo] = []
        var tabs: [TabInfo] = []
        var panes: [PaneInfo] = []
        var agents: [AgentInfo] = []
        var checkoutDirectories: [String] = []
        let listed = (amuxWorktrees + spaces + derived).filter { workspace in
            workspace.isAmuxWorktree || workspace.tabs.contains { !$0.panes.isEmpty }
        }
        for (position, workspace) in listed.enumerated() {
            let members = workspace.tabs.map { tab in
                ordered(tab).flatMap { [$0] + (children[$0.address] ?? []) }
            }
            // Where the desktop app looks for a space's checkout too.
            let directory =
                workspace.isDesktopSpace
                ? firstTerminal(of: workspace).map(liveDirectory) ?? "" : workspace.keyDirectory
            let isCheckout = !directory.isEmpty && directory != home
            if isCheckout, !checkoutDirectories.contains(directory) {
                checkoutDirectories.append(directory)
            }
            let checkout = isCheckout ? checkouts[directory] : nil
            var label = workspace.label
            if workspace.isDesktopSpace, label.isEmpty {
                let folder = isCheckout ? checkout?.root ?? directory : directory
                label = folderName(folder.isEmpty ? workspace.folder : folder, home: home)
            }
            for (tabPosition, tab) in workspace.tabs.enumerated() {
                tabs.append(
                    TabInfo(
                        agentStatus: .unknown, focused: false, label: tab.label,
                        number: tabPosition + 1, paneCount: members[tabPosition].count,
                        tabID: tab.id, workspaceID: workspace.id))
                for record in members[tabPosition] {
                    var agent = HerdrCoreAgentRule.agent(in: record)
                    if doneTerminals.contains(record.address) { agent = agent?.markedDone }
                    panes.append(pane(record, agent: agent, tabID: tab.id, workspaceID: workspace.id))
                    if let agent {
                        agents.append(
                            agentInfo(record, agent: agent, tabID: tab.id, workspaceID: workspace.id))
                    }
                }
            }
            workspaces.append(
                WorkspaceInfo(
                    activeTabID: workspace.tabs.first { !$0.panes.isEmpty }?.id ?? "",
                    agentStatus: .unknown, focused: false, label: label,
                    number: position + 1, paneCount: members.joined().count,
                    tabCount: members.filter { !$0.isEmpty }.count,
                    workspaceID: workspace.id,
                    worktree: workspace.isAmuxWorktree ? nil : checkout.flatMap(worktreeInfo)))
        }
        return Result(
            snapshot: SessionSnapshot(
                agents: agents, layouts: [], panes: panes, protocolVersion: 0, tabs: tabs,
                version: "", workspaces: workspaces),
            checkoutDirectories: checkoutDirectories)
    }

    /// The main checkout is the repository's identity, as a core has no other.
    private static func worktreeInfo(_ checkout: HostCheckout) -> WorkspaceWorktreeInfo? {
        checkout.mainCheckout.map { mainCheckout in
            WorkspaceWorktreeInfo(
                checkoutPath: checkout.root, isLinkedWorktree: checkout.isLinkedWorktree,
                repoKey: mainCheckout,
                repoName: HerdrCoreWorktrees.repositoryName(mainCheckout: mainCheckout),
                repoRoot: mainCheckout)
        }
    }

    // MARK: Placing one Terminal

    /// The Terminal whose Tab this one's Pane belongs in: itself, unless it has
    /// no `herdr.*` label and something shown started it. A chain that loops
    /// places the Terminal on its own.
    private static func placementHost(
        of record: HerdrCoreTerminalRecord, shown: [String: HerdrCoreTerminalRecord]
    ) -> HerdrCoreTerminalRecord {
        var current = record
        var seen: Set<String> = [record.address]
        while !hasDesktopLabel(current), let address = current.parent, let parent = shown[address] {
            guard seen.insert(address).inserted else { return record }
            current = parent
        }
        return current
    }

    private static func hasDesktopLabel(_ record: HerdrCoreTerminalRecord) -> Bool {
        record.labels.keys.contains { $0.hasPrefix("herdr.") }
    }

    private static func desktopLabel(
        _ name: String, of record: HerdrCoreTerminalRecord
    ) -> String? {
        record.labels[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The document's spaces in its order, then those only labels name, each
    /// holding the shown Terminals labeled into it.
    private static func plannedSpaces(
        shown: [HerdrCoreTerminalRecord], document: HerdrCoreDesktopDocument?
    ) -> [PlannedWorkspace] {
        var spaces = (document?.spaces ?? []).map(plannedSpace)
        for record in shown {
            if let space = desktopLabel("herdr.space", of: record) {
                place(record, inSpace: space, spaces: &spaces)
            }
        }
        return spaces
    }

    /// The Terminal a space is named after and a launch there starts beside:
    /// the first in its Tabs' order and each Tab's tree order. The desktop app
    /// starts one beside the space's focused Pane, which no document records.
    private static func firstTerminal(of space: PlannedWorkspace) -> HerdrCoreTerminalRecord? {
        space.tabs.lazy.compactMap { ordered($0).first }.first
    }

    private static func plannedSpace(_ space: HerdrCoreDesktopDocument.Space) -> PlannedWorkspace {
        PlannedWorkspace(
            id: spaceWorkspaceID(space.id), label: space.name, folder: space.folder,
            isDesktopSpace: true,
            tabs: space.tabs.map {
                PlannedTab(
                    id: desktopTabID(space: space.id, tab: $0.id), label: $0.name,
                    treeOrder: $0.terminals)
            })
    }

    /// A space or Tab the document does not list yet goes after those it does,
    /// unnamed, as the desktop app adopts one. No Tab label makes a Tab of its own.
    private static func place(
        _ record: HerdrCoreTerminalRecord, inSpace space: String,
        spaces: inout [PlannedWorkspace]
    ) {
        let workspaceID = spaceWorkspaceID(space)
        let spaceIndex =
            spaces.firstIndex { $0.id == workspaceID }
            ?? {
                spaces.append(
                    PlannedWorkspace(id: workspaceID, label: "", isDesktopSpace: true))
                return spaces.count - 1
            }()
        let tabID =
            desktopLabel("herdr.tab", of: record).map { desktopTabID(space: space, tab: $0) }
            ?? "tab-\(record.address)"
        if let tabIndex = spaces[spaceIndex].tabs.firstIndex(where: { $0.id == tabID }) {
            spaces[spaceIndex].tabs[tabIndex].panes.append(record)
        } else {
            spaces[spaceIndex].tabs.append(PlannedTab(id: tabID, label: "", panes: [record]))
        }
    }

    /// By first appearance, so the Workspaces' order is stable as Terminals come and go.
    private static func place(
        _ record: HerdrCoreTerminalRecord, inDirectory directory: String,
        derived: inout [PlannedWorkspace]
    ) {
        let tab = PlannedTab(id: "tab-\(record.address)", label: "", panes: [record])
        let id = workspaceID(directory: directory)
        if let index = derived.firstIndex(where: { $0.id == id }) {
            derived[index].tabs.append(tab)
        } else {
            derived.append(
                PlannedWorkspace(
                    id: id, label: label(directory: directory), keyDirectory: directory, tabs: [tab]))
        }
    }

    /// Those in the document's tree in its order, then the rest as listed.
    private static func ordered(_ tab: PlannedTab) -> [HerdrCoreTerminalRecord] {
        guard !tab.treeOrder.isEmpty else { return tab.panes }
        let positions = Dictionary(
            tab.treeOrder.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        return tab.panes.enumerated().sorted { lhs, rhs in
            (positions[lhs.element.address] ?? Int.max, lhs.offset)
                < (positions[rhs.element.address] ?? Int.max, rhs.offset)
        }.map(\.element)
    }

    // MARK: Launching into a Workspace

    /// The desktop space a Workspace id names; nil for a derived Workspace.
    static func desktopSpace(ofWorkspace id: String) -> String? {
        id.hasPrefix(spacePrefix) ? String(id.dropFirst(spacePrefix.count)) : nil
    }

    /// The directory a derived Workspace is keyed by, which is not any Terminal's
    /// current one. Nil when no Terminal shown here lands in it.
    static func keyDirectory(
        ofWorkspace id: String, terminals: [HerdrCoreTerminalRecord],
        firstSeenDirectories: [String: String]
    ) -> String? {
        for record in terminals where !record.hasFinished && desktopLabel("herdr.space", of: record) == nil {
            let directory = firstSeenDirectories[record.address] ?? record.cwd
            if workspaceID(directory: directory) == id { return directory }
        }
        return nil
    }

    /// Where a new Terminal in a space starts when nothing asked for a directory:
    /// where the Terminal the space is named after is now, else the space's
    /// folder. The desktop app keeps that folder from when the space was made and
    /// starts its own new Terminals where a Pane of the space is now.
    static func directory(
        ofSpace space: String, terminals: [HerdrCoreTerminalRecord],
        document: HerdrCoreDesktopDocument?
    ) -> String? {
        let workspaceID = spaceWorkspaceID(space)
        let planned = plannedSpaces(shown: terminals.filter { !$0.hasFinished }, document: document)
            .first { $0.id == workspaceID }
        if let live = planned.flatMap(firstTerminal).map(liveDirectory), !live.isEmpty {
            return live
        }
        if let folder = planned?.folder, !folder.isEmpty { return folder }
        return nil
    }

    /// The Workspace a Terminal with no parent shown lands in.
    static func workspaceID(
        of record: HerdrCoreTerminalRecord, firstSeenDirectories: [String: String]
    ) -> String {
        desktopLabel("herdr.space", of: record).map(spaceWorkspaceID)
            ?? workspaceID(directory: firstSeenDirectories[record.address] ?? record.cwd)
    }

    // MARK: Ids and names

    /// Stable and opaque: the same directory is the same Workspace on every
    /// reconnect and relaunch.
    static func workspaceID(directory: String) -> String {
        "d-" + digest(directory)
    }

    private static let spacePrefix = "space-"

    /// The Workspace id of a desktop space.
    static func spaceWorkspaceID(_ space: String) -> String {
        spacePrefix + space
    }

    /// A Tab's label belongs to its space, and labels can be anything, so the
    /// pair is hashed with a length between them.
    private static func desktopTabID(space: String, tab: String) -> String {
        "dtab-" + digest("\(space.utf8.count):\(space)\(tab)")
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func label(directory: String) -> String {
        directory.isEmpty ? String(localized: "No directory") : RemoteHostPath.lastComponent(of: directory)
    }

    /// Where the desktop app looks for a Terminal's folder, and an Agent's
    /// directory: what runs there now, else where it launched.
    private static func liveDirectory(of record: HerdrCoreTerminalRecord) -> String {
        if let directory = record.foreground?.cwd, !directory.isEmpty { return directory }
        return record.cwd
    }

    /// A folder as the desktop app names it: its last part on either
    /// separator, `~` for the home folder.
    static func folderName(_ path: String, home: String?) -> String {
        let separators: [Character] = ["/", "\\"]
        func trimmed(_ text: String) -> Substring {
            var text = Substring(text)
            while let last = text.last, separators.contains(last) { text.removeLast() }
            return text
        }
        let folder = trimmed(path)
        if path.isEmpty || home.map(trimmed) == folder { return "~" }
        if folder.isEmpty { return String(path.prefix(1)) }
        let parts = folder.split { separators.contains($0) }
        return parts.last.map(String.init) ?? String(folder)
    }

    /// An Agent with no title yet reads as its program, so its first row says
    /// something before the program sets one. Its directory is where its program
    /// runs, as on herdr TUI, not where its Terminal started: the core never
    /// updates a record's `cwd`, so an Agent typed after a `cd` would read the
    /// shell's starting folder. That `cwd` stands in only until a foreground
    /// sample. The Agent's Workspace still follows where its Terminal started.
    private static func agentInfo(
        _ record: HerdrCoreTerminalRecord, agent: HerdrCoreAgent, tabID: String, workspaceID: String
    ) -> AgentInfo {
        let terminalTitle = record.title.isEmpty ? nil : record.title
        let stripped = terminalTitle.map(TerminalTitleGlyphs.strip).flatMap { $0.isEmpty ? nil : $0 }
        return AgentInfo(
            agentStatus: agent.status, focused: false, paneID: record.address, revision: 0, tabID: tabID,
            terminalID: record.address, workspaceID: workspaceID, agent: agent.kind,
            cwd: liveDirectory(of: record),
            foregroundCwd: record.foreground?.cwd, name: record.name, terminalTitle: terminalTitle,
            terminalTitleStripped: stripped ?? AgentNotificationIdentity.kindLabel(agent.kind),
            tokens: record.labels)
    }

    private static func pane(
        _ record: HerdrCoreTerminalRecord, agent: HerdrCoreAgent?, tabID: String, workspaceID: String
    ) -> PaneInfo {
        let terminalTitle = record.title.isEmpty ? nil : record.title
        return PaneInfo(
            agentStatus: agent?.status ?? .unknown, focused: false, paneID: record.address, revision: 0,
            tabID: tabID, terminalID: record.address, workspaceID: workspaceID, agent: agent?.kind,
            cwd: record.cwd, foregroundCwd: record.foreground?.cwd, label: record.name,
            terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitle.map(TerminalTitleGlyphs.strip),
            title: programName(record))
    }

    /// What runs in the Terminal now, else what it launched.
    private static func programName(_ record: HerdrCoreTerminalRecord) -> String? {
        if let foreground = record.foreground?.name, !foreground.isEmpty { return foreground }
        return record.argv.first.flatMap { $0.isEmpty ? nil : RemoteHostPath.lastComponent(of: $0) }
    }
}
