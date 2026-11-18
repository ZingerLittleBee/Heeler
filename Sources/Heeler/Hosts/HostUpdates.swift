import Foundation

/// Why an update did not leave the newer version in place.
struct HostUpdateFailure: Equatable, Sendable {
    let message: String
    /// The Host's own words, when it said why.
    var detail: String?
}

/// One Heeler Plugin or Host Helper on one Host, as Updates and Host detail
/// list it (ADR 0048).
struct HostUpdateItem: Identifiable, Equatable, Sendable {
    enum Component: Hashable, Sendable {
        case plugin
        case helper

        var name: String {
            switch self {
            case .plugin: String(localized: "Heeler Plugin")
            case .helper: String(localized: "Host Helper")
            }
        }
    }

    /// A plugin belongs to one Herdr TUI Server; a Helper to its Host, however
    /// many herdr-core and tmux Servers are on there.
    enum ID: Hashable, Sendable {
        case plugin(Host.ID)
        case helper(HostMachine.ID)
    }

    enum State: Equatable, Sendable {
        /// Nothing newer in this app.
        case current
        /// Installed in some way an update does not fit: not installed yet,
        /// disabled, linked from a checkout, damaged. Its Server's page says
        /// what to do.
        case other
        case updateAvailable
        /// Behind another update on the same Host.
        case waiting
        case updating
        /// The update ended without an answer, and what the Host holds is
        /// being read again.
        case readingBack
        /// Updated since Updates was last closed.
        case updated
        /// The update changed nothing, or nothing that shows.
        case failed(HostUpdateFailure)
        /// The update left a Helper that needs Repair.
        case damaged(HostUpdateFailure)

        /// Still to be dealt with: what the card and the badge count.
        var isOutstanding: Bool { isReady || isMoving }

        /// An action can start on it.
        var isReady: Bool {
            switch self {
            case .updateAvailable, .failed, .damaged: true
            case .current, .other, .waiting, .updating, .readingBack, .updated: false
            }
        }

        var isMoving: Bool {
            switch self {
            case .waiting, .updating, .readingBack: true
            case .current, .other, .updateAvailable, .updated, .failed, .damaged: false
            }
        }

        var failure: HostUpdateFailure? {
            switch self {
            case .failed(let failure), .damaged(let failure): failure
            case .current, .other, .updateAvailable, .waiting, .updating, .readingBack, .updated: nil
            }
        }
    }

    let id: ID
    let component: Component
    /// The record its update dials, and whose page shows the rest.
    let record: Host.ID
    /// Which Servers it serves: `Herdr TUI · ci`, or `herdr-core, tmux`.
    let scope: String
    /// What the Host holds, as a row says it: a version, or a standing such
    /// as Not Installed.
    let installed: String
    /// What this app carries.
    let bundled: PluginVersion
    var state: State
    /// Something other than an update asks for the user on the Server's page.
    var needsAttention = false
    /// A Helper whose reading offers Repair.
    var offersRepair = false
    /// What the Host goes without until it updates.
    var notes: [String] = []

    /// The plugin of one Herdr TUI Server, nil where none can be listed: a
    /// Host whose plugin was never read, or that takes none.
    static func plugin(
        _ status: HeelerPluginStatus?, on record: Host,
        bundled: PluginVersion = HeelerPluginCompatibility.bundled
    ) -> HostUpdateItem? {
        guard let status else { return nil }
        let presentation = HeelerPluginPresentation(
            status, session: record.sessionName, endpoint: record.herdrEndpoint, bundled: bundled)
        let state: State
        var installed = presentation.value
        var notes: [String] = []
        switch status {
        case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable:
            return nil
        case .notInstalled:
            state = .other
        case .installed:
            if HeelerPluginPresentation.unattendedUpdate(for: status, on: record, bundled: bundled) != nil,
                let version = status.confirmedVersion
            {
                state = .updateAvailable
                installed = "\(version)"
                // The newest two say enough under a list of several Hosts.
                notes = HeelerPluginFeature.requirements(
                    HeelerPluginFeature.allCases.filter { $0.minimumVersion <= bundled }, installed: version
                ).suffix(2).map(\.note)
            } else if let version = status.confirmedVersion, version >= bundled, presentation.notice == nil {
                state = .current
            } else {
                state = .other
            }
        }
        return HostUpdateItem(
            id: .plugin(record.id), component: .plugin, record: record.id,
            scope: record.serverKey?.label ?? record.serverKind.displayName,
            installed: installed, bundled: bundled, state: state,
            needsAttention: state == .other && presentation.notice?.tone == .warning, notes: notes)
    }

    /// A Host's Helper, nil where it has none to list: a Host it does not run
    /// on, or whose Helper was never read.
    static func helper(
        _ reading: HostHelperReading?, on machine: HostMachine.ID, through record: Host, scope: String
    ) -> HostUpdateItem? {
        guard let reading, reading.unsupportedPlatform == nil else { return nil }
        let presentation = reading.presentation
        let state: State
        var installed = presentation.value
        var needsAttention = false
        switch reading.integrity {
        case .intact(let version) where reading.installAction == .update:
            state = .updateAvailable
            installed = "\(version)"
        case .intact(let version) where version < reading.bundled:
            // Older, and nothing here can update it: the Host has no Node.js.
            state = .other
            needsAttention = true
        case .intact(let version), .newer(let version):
            // A Helper that is current may still ask for linger or a repair,
            // which its sheet explains.
            state = .current
            installed = "\(version)"
            needsAttention = presentation.needsAttention
        case .absent, .damaged:
            state = .other
            needsAttention = presentation.needsAttention
        }
        return HostUpdateItem(
            id: .helper(machine), component: .helper, record: record.id, scope: scope,
            installed: installed, bundled: reading.bundled, state: state, needsAttention: needsAttention,
            offersRepair: reading.installAction == .repair)
    }
}

extension ServerKind {
    /// Whether a Server of this kind is served by its Host's Helper, where a
    /// Herdr TUI Server has its plugin. A Rex Server has neither, so Updates
    /// never reads, lists or updates anything for it (ADR 0049).
    var usesHostHelper: Bool {
        switch self {
        case .herdrCore, .tmux: true
        case .herdrTUI, .rex, .unconfirmed: false
        }
    }
}

/// Every Host's Plugin and Helper at one moment, and what the Hosts tab says
/// of them: the card over the list, the tab's badge, a row's tag and the
/// Updates page's button.
struct HostUpdatesSnapshot: Equatable, Sendable {
    struct Group: Identifiable, Equatable, Sendable {
        let id: HostMachine.ID
        let name: String
        let items: [HostUpdateItem]
    }

    enum Run: Equatable, Sendable {
        case idle
        /// `done` of `total` updates begun since the Hosts were last all still.
        case running(done: Int, total: Int)
        /// Everything took. Shown for a moment, then idle.
        case finished
    }

    enum Card: Equatable, Sendable {
        /// `components` are the kinds among the updates, for naming them.
        case available(updates: Int, hosts: Int, components: Set<HostUpdateItem.Component>)
        case updating(position: Int, total: Int, hosts: [String])
        case finished([HostUpdateItem.Component: PluginVersion])
        /// Nothing left to start, and these did not take: `Host · Component`.
        case failed([String])
    }

    enum Badge: Equatable, Sendable {
        case count(Int)
        /// Something failed and nothing is moving.
        case failed
    }

    enum Tag: Equatable, Sendable {
        case updates(Int)
        case updating
        case failed
    }

    enum PrimaryAction: Equatable, Sendable {
        case updateAll
        case tryAgain
        case repair
    }

    var groups: [Group] = []
    var run = Run.idle

    var items: [HostUpdateItem] { groups.flatMap(\.items) }

    var outstanding: [HostUpdateItem] { items.filter(\.state.isOutstanding) }

    /// The Hosts with something to update, in catalog order.
    var behind: [Group] {
        groups.compactMap { group in
            let listed = group.items.filter { $0.state.isOutstanding || $0.state == .updated }
            return listed.isEmpty ? nil : Group(id: group.id, name: group.name, items: listed)
        }
    }

    func group(_ id: HostMachine.ID) -> Group? {
        groups.first { $0.id == id }
    }

    func item(_ id: HostUpdateItem.ID) -> (group: Group, item: HostUpdateItem)? {
        for group in groups {
            if let item = group.items.first(where: { $0.id == id }) { return (group, item) }
        }
        return nil
    }

    /// `2 of 3`, counting the update under way.
    var progress: (position: Int, total: Int)? {
        guard case .running(let done, let total) = run else { return nil }
        return (min(done + 1, total), total)
    }

    var card: Card? {
        if let progress {
            let hosts = groups.filter { group in group.items.contains { $0.state == .updating || $0.state == .readingBack } }
            return .updating(position: progress.position, total: progress.total, hosts: hosts.map(\.name))
        }
        if run == .finished {
            var versions: [HostUpdateItem.Component: PluginVersion] = [:]
            for item in items where item.state == .updated || item.state == .current {
                versions[item.component] = item.bundled
            }
            return .finished(versions)
        }
        let outstanding = outstanding
        guard !outstanding.isEmpty else { return nil }
        if !items.contains(where: { $0.state == .updateAvailable }) {
            let failed = groups.flatMap { group in
                group.items.filter { $0.state.failure != nil }.map { "\(group.name) · \($0.component.name)" }
            }
            if !failed.isEmpty { return .failed(failed) }
        }
        return .available(
            updates: outstanding.count,
            hosts: groups.filter { group in group.items.contains(where: \.state.isOutstanding) }.count,
            components: Set(outstanding.map(\.component)))
    }

    var badge: Badge? {
        let outstanding = outstanding
        guard !outstanding.isEmpty else { return nil }
        if outstanding.contains(where: { $0.state.failure != nil }), !outstanding.contains(where: \.state.isMoving) {
            return .failed
        }
        return .count(outstanding.count)
    }

    func tag(for machine: HostMachine.ID) -> Tag? {
        let outstanding = group(machine)?.items.filter(\.state.isOutstanding) ?? []
        guard !outstanding.isEmpty else { return nil }
        let isMoving = outstanding.contains(where: \.state.isMoving)
        if outstanding.contains(where: { $0.state.failure != nil }), !isMoving { return .failed }
        return isMoving ? .updating : .updates(outstanding.count)
    }

    /// What the page's one button does, nil while a run is under way or
    /// nothing is left.
    var primaryAction: PrimaryAction? {
        guard progress == nil else { return nil }
        let ready = items.filter(\.state.isReady)
        if ready.contains(where: { $0.state == .updateAvailable }) { return .updateAll }
        if ready.contains(where: { if case .failed = $0.state { true } else { false } }) { return .tryAgain }
        return ready.isEmpty ? nil : .repair
    }
}

extension HostUpdatesSnapshot.Card {
    var title: String {
        switch self {
        case .available(let updates, _, _):
            String(
                localized: "\(updates) Updates Available",
                comment: "Title of the card over the Hosts list. Argument: how many Plugin and Helper updates wait.")
        case .updating(let position, let total, _):
            String(
                localized: "Updating \(position) of \(total)…",
                comment: "Arguments: which update is running, then how many were started.")
        case .finished:
            String(localized: "All Up to Date")
        case .failed(let names):
            String(
                localized: "\(names.count) Updates Failed",
                comment: "Title of the card over the Hosts list once updates failed. Argument: how many.")
        }
    }

    var subtitle: String {
        switch self {
        case .available(_, let hosts, let components):
            switch (components.contains(.plugin), components.contains(.helper)) {
            case (true, false):
                return String(
                    localized: "Heeler Plugin on \(hosts) Hosts",
                    comment: "Under the updates card's title: only plugins have updates. Argument: on how many Hosts.")
            case (false, true):
                return String(
                    localized: "Host Helper on \(hosts) Hosts",
                    comment: "Under the updates card's title: only Helpers have updates. Argument: on how many Hosts.")
            default:
                return String(
                    localized: "Plugin and Helper on \(hosts) Hosts",
                    comment: "Under the updates card's title: plugins and Helpers have updates. Argument: on how many Hosts.")
            }
        case .updating(_, _, let hosts):
            return hosts.formatted(.list(type: .and, width: .narrow))
        case .finished(let versions):
            return [HostUpdateItem.Component.plugin, .helper].compactMap { component in
                versions[component].map { "\(component.name) \($0)" }
            }.joined(separator: " · ")
        case .failed(let names):
            return names.formatted(.list(type: .and, width: .narrow))
        }
    }
}

extension HostUpdatesSnapshot.PrimaryAction {
    var title: String {
        switch self {
        case .updateAll: String(localized: "Update All")
        case .tryAgain: String(localized: "Try Again")
        case .repair: String(localized: "Repair")
        }
    }
}

/// The user guide's steps for updating on the Host itself, for an update that
/// keeps failing from the app. The guide is written in English and Simplified
/// Chinese; every other language reads the English one, as the READMEs link
/// it.
enum HostUpdateGuide {
    /// The steps for `component`, or with none the guide's table of failures.
    /// Each fragment is a heading of `docs/guides/updates.md` or its
    /// `zh/updates.md` as GitHub slugs it, which the docs site keeps. Apps
    /// already released hold these links, so those headings stay as they are.
    static func url(
        for component: HostUpdateItem.Component?,
        localization: String = Bundle.main.preferredLocalizations.first ?? "en"
    ) -> URL? {
        let isChinese = localization == "zh-Hans"
        var url = URLComponents()
        url.scheme = "https"
        url.host = "docs.heeler.bybee.dev"
        url.path = isChinese ? "/zh/updates" : "/updates"
        url.fragment =
            switch component {
            case .plugin?: isChinese ? "手动更新-heeler-插件" : "update-the-heeler-plugin-by-hand"
            case .helper?: isChinese ? "手动更新-host-helper" : "update-the-host-helper-by-hand"
            case nil: isChinese ? "更新失败时" : "when-an-update-fails"
            }
        return url.url
    }
}
