import SwiftUI
import UIKit

/// Sheet presentation for the 3-tab Swarm console: standard form sizing on
/// regular width (never re-measuring scroll geometry on every frame) and
/// expandable bottom detents on compact width.
private struct ChatSwarmSheetPresentationModifier: ViewModifier {
    let presentation: ConsoleSheetPresentation
    @Binding var detent: PresentationDetent

    @ViewBuilder
    func body(content: Content) -> some View {
        switch presentation {
        case .form:
            content
                .presentationSizing(.form)
                .presentationBackground(ConsoleStatusSheetPresentationModifier.formBackground)
        case .inheritedSheet:
            content
                .presentationDetents([.fraction(0.6), .large], selection: $detent)
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ChatSwarmHeaderSummary: Equatable {
    var activeCount: Int
    var waitingCount: Int
    var postCount: Int
    var isOffline: Bool
    var hasSystemAlerts: Bool
    var dotStatuses: [AgySwarmSnapshot.MemberStatus]

    init(swarm: AgySwarmSnapshot, isHostConnected: Bool) {
        let workers = swarm.taskWorkers
        self.activeCount = workers.count { $0.status == .working }
        self.waitingCount = workers.count { $0.status == .waiting }
        self.postCount = swarm.postCount
        self.isOffline = !isHostConnected || !swarm.isLive
        self.hasSystemAlerts = swarm.hasSystemAlerts
        let nonKilled = workers.filter { !$0.isKilled }
        let source = nonKilled.isEmpty ? workers : nonKilled
        self.dotStatuses = source.map(\.status)
    }
}

/// Under the tabs: a dot for each worker and the counts, then what is
/// wrong with the Swarm, in words at the trailing edge.
private struct ChatSwarmHeaderStatusBar: View, Equatable {
    let summary: ChatSwarmHeaderSummary

    var body: some View {
        HStack(spacing: 8) {
            ChatSwarmStatusDots(statuses: summary.dotStatuses)
                .grayscale(summary.isOffline ? 1 : 0)
                .opacity(summary.isOffline ? 0.5 : 1)

            Text(
                verbatim: headerSummaryText(
                    active: summary.activeCount,
                    waiting: summary.waitingCount,
                    posts: summary.postCount)
            )
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 0)

            if summary.isOffline {
                Text("Offline")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.stopped))
            } else if summary.hasSystemAlerts {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                    Text("Needs attention")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
            }
        }
    }

    private func headerSummaryText(active: Int, waiting: Int, posts: Int) -> String {
        var parts: [String] = []
        if active > 0 {
            parts.append(String(localized: "\(active) active"))
        }
        if waiting > 0 {
            parts.append(String(localized: "\(waiting) waiting"))
        }
        parts.append("#\(posts)")
        return parts.joined(separator: " · ")
    }
}

/// Native 3-tab Swarm Sheet (`Board`, `Members`, `Overview`) plus pushed
/// Post Detail reader and read-only Worker sub-conversation view.
/// The Board is a compact inset-grouped directory (short posts inline, long
/// posts previewed to two lines with a line count) that pushes into a full
/// Markdown reader on tap.
struct ChatSwarmSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case board
        case members
        case overview

        var id: String { rawValue }
    }

    enum Destination: Hashable {
        case worker(String)
        case post(Int)
    }

    let chat: AgentChatStore
    let isHostConnected: Bool
    let sheetPresentation: ConsoleSheetPresentation

    @State private var selectedTab: Tab
    @State private var selectedFilter: ChatSwarmBoardFilter = .all
    @State private var sheetDetent: PresentationDetent = .fraction(0.6)
    @State private var highlightedSeq: Int?
    @State private var pendingScrollSeq: Int?
    @State private var scrollRequest: ChatSwarmScrollRequest<Int>?
    @State private var scrollNonce = 0
    @State private var showsKilledMembers = false
    @State private var path: [Destination] = []
    @Environment(\.dismiss) private var dismiss

    init(
        chat: AgentChatStore,
        isHostConnected: Bool,
        sheetPresentation: ConsoleSheetPresentation,
        initialTab: Tab = .board
    ) {
        self.chat = chat
        self.isHostConnected = isHostConnected
        self.sheetPresentation = sheetPresentation
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let swarm = chat.agySwarm {
                    rootPage(swarm: swarm)
                        .navigationTitle(swarm.displayTitle)
                } else {
                    ContentUnavailableView(
                        "Swarm Unavailable",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("No swarm activity is available for this conversation."))
                        .navigationTitle("Swarm")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .worker(let memberName):
                    ChatSwarmWorkerDetailView(
                        chat: chat,
                        memberName: memberName,
                        isHostConnected: isHostConnected)
                case .post(let seq):
                    ChatSwarmPostDetailView(
                        chat: chat,
                        initialSeq: seq,
                        filter: selectedFilter,
                        openWorker: { memberName in
                            openWorker(memberName)
                        })
                }
            }
        }
        .modifier(ChatSwarmSheetPresentationModifier(presentation: sheetPresentation, detent: $sheetDetent))
        .accessibilityIdentifier("chat.swarm.sheet")
        .onChange(of: chat.agySwarm == nil) { _, isNil in
            if isNil { dismiss() }
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if !isEmpty, sheetDetent != .large {
                withAnimation(.snappy(duration: 0.25)) {
                    sheetDetent = .large
                }
            }
        }
    }

    private func rootPage(swarm: AgySwarmSnapshot) -> some View {
        let filterOptions = selectedTab == .board ? ChatSwarmBoardFilter.options(in: swarm) : []
        let showsFilterBar = !filterOptions.isEmpty
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("Swarm Section", selection: $selectedTab) {
                    Text("Board").tag(Tab.board)
                    Text("Members").tag(Tab.members)
                    Text("Overview").tag(Tab.overview)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("chat.swarm.tabs")

                ChatSwarmHeaderStatusBar(
                    summary: ChatSwarmHeaderSummary(swarm: swarm, isHostConnected: isHostConnected))
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, showsFilterBar ? 4 : 12)

            if showsFilterBar {
                boardFilterBar(options: filterOptions)
            }

            Divider()

            switch selectedTab {
            case .board:
                boardPage(swarm: swarm)
            case .members:
                membersPage(swarm: swarm)
            case .overview:
                overviewPage(swarm: swarm)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// A section's title with how many rows it holds.
    private func counted(_ title: String, _ count: Int) -> String {
        "\(title) · \(count)"
    }

    // MARK: - Board Tab

    private func boardPage(swarm: AgySwarmSnapshot) -> some View {
        let posts = filteredPosts(in: swarm)
        let boardModel = chat.swarmBoard
        let listState = boardModel.buildState(
            swarmID: swarm.id,
            filter: selectedFilter,
            posts: posts,
            knownSeqs: swarm.knownPostSeqs,
            highlightedSeq: highlightedSeq)

        return Group {
            if swarm.boardPosts.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "No Board Posts Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Assignments and findings posted by swarm members appear here."))
                        .padding(.vertical, 36)
                }
            } else if posts.isEmpty {
                ScrollView {
                    ContentUnavailableView {
                        Label("No Matching Posts", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("No posts match the current filter.")
                    } actions: {
                        Button("Show All Posts") {
                            selectedFilter = .all
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 36)
                }
            } else {
                ChatSwarmListView(
                    state: listState,
                    scrollRequest: scrollRequest,
                    initialMeasuredHeights: boardModel.measuredHeights,
                    onMeasure: { seq, height in
                        boardModel.recordMeasuredHeight(height, for: seq)
                    },
                    onForgetMeasurements: { kept in
                        boardModel.forgetMeasuredHeights(keeping: kept)
                    },
                    accessibilityIdentifier: "chat.swarm.board.list"
                ) { item in
                    ChatSwarmBoardCard(
                        row: item.payload,
                        openDetail: { openPost(item.id) })
                }
                .onAppear {
                    if let seq = pendingScrollSeq {
                        pendingScrollSeq = nil
                        scrollAndHighlight(seq)
                    }
                }
                .onChange(of: pendingScrollSeq) { _, seq in
                    guard let seq else { return }
                    pendingScrollSeq = nil
                    scrollAndHighlight(seq)
                }
            }
        }
    }

    private func filteredPosts(in swarm: AgySwarmSnapshot) -> [AgySwarmSnapshot.BoardMessage] {
        guard selectedFilter != .all else { return swarm.boardPosts }
        return swarm.boardPosts.filter { selectedFilter.matches($0) }
    }

    private func boardFilterBar(options: [ChatSwarmBoardFilter.Option]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options) { @Sendable option in
                    MainActorContent {
                        filterChip(option)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    private func filterChip(_ option: ChatSwarmBoardFilter.Option) -> some View {
        let isSelected = selectedFilter == option.filter
        let ink: Color =
            switch option.kind {
            case .done:
                isSelected ? ChatBackgroundWorkPalette.statusInk(.completed) : ChatBackgroundWorkPalette.statusInk(.completed)
            case .stall:
                ChatBackgroundWorkPalette.statusInk(.failed)
            case .archivedChannel:
                isSelected ? .primary : Color(uiColor: .tertiaryLabel)
            case .neutral:
                isSelected ? .primary : .secondary
            }
        let fill: Color =
            switch option.kind {
            case .done where isSelected:
                ChatBackgroundWorkPalette.statusInk(.completed).opacity(0.18)
            case .stall where isSelected:
                ChatBackgroundWorkPalette.statusInk(.failed).opacity(0.18)
            default:
                isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.06)
            }

        return Button {
            selectedFilter = option.filter
        } label: {
            HStack(spacing: 4) {
                if option.kind == .done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                } else if option.kind == .stall {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: option.count.map { "\(option.label) (\($0))" } ?? option.label)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(Capsule().fill(fill))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openPost(_ seq: Int) {
        if sheetDetent != .large {
            withAnimation(.snappy(duration: 0.25)) {
                sheetDetent = .large
            }
        }
        path.append(.post(seq))
    }

    private func openWorker(_ memberName: String) {
        if sheetDetent != .large {
            withAnimation(.snappy(duration: 0.25)) {
                sheetDetent = .large
            }
        }
        path.append(.worker(memberName))
    }

    private func scrollAndHighlight(_ seq: Int) {
        scrollNonce &+= 1
        scrollRequest = ChatSwarmScrollRequest(nonce: scrollNonce, target: seq)
        highlightedSeq = seq
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if highlightedSeq == seq {
                highlightedSeq = nil
            }
        }
    }

    // MARK: - Members Tab

    private func membersPage(swarm: AgySwarmSnapshot) -> some View {
        let coordinators = swarm.nonKilledMembers.filter(\.isCoordinator)
        let active = swarm.nonKilledMembers.filter {
            !$0.isCoordinator && ($0.status == .working || $0.status == .error)
        }
        let waiting = swarm.nonKilledMembers.filter {
            !$0.isCoordinator && $0.status == .waiting
        }
        let killed = swarm.killedMembers

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !coordinators.isEmpty {
                    ChatSheetSection {
                        memberRows(coordinators)
                    }
                }

                if !active.isEmpty {
                    ChatSheetSection(title: counted(String(localized: "Active"), active.count)) {
                        memberRows(active)
                    }
                }

                if !waiting.isEmpty {
                    ChatSheetSection(title: counted(String(localized: "Waiting"), waiting.count)) {
                        memberRows(waiting)
                    }
                }

                if !killed.isEmpty {
                    stoppedMembers(killed)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
    }

    /// The members that were stopped, behind a row that opens them.
    private func stoppedMembers(_ killed: [AgySwarmSnapshot.Member]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showsKilledMembers.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: counted(String(localized: "Stopped"), killed.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ChatSheetDisclosureChevron(isExpanded: showsKilledMembers)
                }
                .padding(.leading, ChatSheetStyle.titleInset)
                // Its chevron under the rows' own.
                .padding(.trailing, ChatSheetStyle.rowInset)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showsKilledMembers {
                ChatSheetSection {
                    memberRows(killed)
                }
            }
        }
        // Closer to the group over it than a titled section stands.
        .padding(.top, -8)
    }

    private func memberRows(_ members: [AgySwarmSnapshot.Member]) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.id) { @Sendable index, member in
            MainActorContent {
                memberRow(member, isDivided: index > 0)
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: AgySwarmSnapshot.Member, isDivided: Bool) -> some View {
        let canOpenWorker = !member.isCoordinator && ConversationReference.canonicalUUID(member.conversationID) != nil
        let row = ChatSwarmMemberRow(member: member, showsChevron: canOpenWorker, isDivided: isDivided)
        if member.isCoordinator {
            Button {
                dismiss()
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.swarm.member.\(member.name)")
        } else if canOpenWorker {
            Button {
                openWorker(member.name)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.swarm.member.\(member.name)")
        } else {
            row
                .accessibilityIdentifier("chat.swarm.member.\(member.name)")
        }
    }

    // MARK: - Overview Tab

    private func overviewPage(swarm: AgySwarmSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !swarm.systemAlerts.isEmpty {
                    systemAlertsSection(swarm.systemAlerts)
                }

                if let overview = swarm.overview {
                    ChatSwarmNarratorOverview(overview: overview)
                } else {
                    computedOverviewSection(swarm: swarm)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
    }

    private func systemAlertsSection(_ alerts: [AgySwarmSnapshot.SystemAlert]) -> some View {
        ChatSheetSection(title: counted(String(localized: "Attention"), alerts.count)) {
            ForEach(Array(alerts.enumerated()), id: \.element.id) { @Sendable index, alert in
                MainActorContent {
                    alertRow(alert, isDivided: index > 0)
                }
            }
        }
    }

    /// What is wrong with a member, and the way to its sub-conversation
    /// where it has one to show.
    @ViewBuilder
    private func alertRow(_ alert: AgySwarmSnapshot.SystemAlert, isDivided: Bool) -> some View {
        let canOpen = ConversationReference.canonicalUUID(alert.conversationID) != nil
        let ink = ChatBackgroundWorkPalette.statusInk(.failed)
        let row = ChatSwarmGlyphRow(isDivided: isDivided, accessory: canOpen ? .opens : .none) {
            Image(systemName: alert.kind == .stuck ? "clock.badge.exclamationmark" : "exclamationmark.triangle")
                .foregroundStyle(ink)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "@\(alert.member)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: alertBadgeTitle(alert.kind))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ink)
                }
                Text(verbatim: alert.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        if canOpen {
            Button {
                openWorker(alert.member)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func alertBadgeTitle(_ kind: AgySwarmSnapshot.SystemAlert.Kind) -> String {
        switch kind {
        case .quota: String(localized: "Quota")
        case .error: String(localized: "Error")
        case .stuck: String(localized: "No progress")
        }
    }

    /// What the board alone says of the Swarm, where no narrator has
    /// written an overview: its counts, its channels and the posts that
    /// report something.
    private func computedOverviewSection(swarm: AgySwarmSnapshot) -> some View {
        let highlights = Array(
            swarm.boardPosts.filter {
                $0.isMarkedDone || $0.isMarkedStall || ($0.mentionsCoordinator && !$0.isBrief)
            }.suffix(6))
        let workers = swarm.taskWorkers
        let activeCount = workers.count { $0.status == .working }
        let waitingCount = workers.count { $0.status == .waiting }
        let channels = swarm.channels

        return VStack(alignment: .leading, spacing: 20) {
            ChatSheetSection {
                HStack(spacing: 0) {
                    ChatSwarmStat(value: activeCount, label: String(localized: "Active"))
                    Divider().padding(.vertical, 12)
                    ChatSwarmStat(value: waitingCount, label: String(localized: "Waiting"))
                    Divider().padding(.vertical, 12)
                    ChatSwarmStat(value: swarm.postCount, label: String(localized: "Posts"))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if !channels.isEmpty {
                ChatSheetSection(title: String(localized: "Channels")) {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { @Sendable index, channel in
                        MainActorContent {
                            channelRow(channel, isDivided: index > 0)
                        }
                    }
                }
            }

            if !highlights.isEmpty {
                ChatSheetSection(title: String(localized: "Key Updates")) {
                    ForEach(Array(highlights.enumerated()), id: \.element.id) { @Sendable index, post in
                        MainActorContent {
                            updateRow(post, isDivided: index > 0)
                        }
                    }
                }
            }
        }
    }

    private func channelRow(_ channel: AgySwarmSnapshot.Channel, isDivided: Bool) -> some View {
        Button {
            selectedFilter = .channel(channel.name)
            selectedTab = .board
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: "#\(channel.name)")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                if !channel.topic.isEmpty {
                    Text(verbatim: channel.topic)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                ChatStripChevron()
            }
            .padding(.horizontal, ChatSheetStyle.rowInset)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .chatRowDivider(isDivided, inset: ChatSheetStyle.rowInset)
        }
        .buttonStyle(.plain)
    }

    private func updateRow(_ post: AgySwarmSnapshot.BoardMessage, isDivided: Bool) -> some View {
        Button {
            openPost(post.seq)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "#\(post.seq)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(verbatim: "@\(post.agent)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if post.isMarkedDone {
                            ChatSwarmPostMark(isDone: true)
                        } else if post.isMarkedStall {
                            ChatSwarmPostMark(isDone: false)
                        }
                    }
                    Text(verbatim: post.singleLinePreview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChatStripChevron()
            }
            .padding(.horizontal, ChatSheetStyle.rowInset)
            .padding(.vertical, 12)
            .contentShape(.rect)
            .chatRowDivider(isDivided, inset: ChatSheetStyle.rowInset)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Rows

/// A sheet row that leads with a glyph: the glyph in a column of its own,
/// on the first line of the text beside it, and what a tap does at the
/// trailing edge.
private struct ChatSwarmGlyphRow<Glyph: View, Content: View>: View {
    enum Accessory {
        case none
        /// The row opens something else.
        case opens
        /// The row opens in place.
        case discloses(isExpanded: Bool)
    }

    var isDivided = false
    var accessory = Accessory.none
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let content: Content

    @ScaledMetric(relativeTo: .callout) private var glyphColumn: CGFloat = ChatSwarmSheetStyle.glyphColumn

    var body: some View {
        HStack(alignment: .center, spacing: ChatSheetStyle.glyphSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: ChatSheetStyle.glyphSpacing) {
                glyph
                    .font(.callout)
                    .frame(width: glyphColumn)
                    .accessibilityHidden(true)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch accessory {
            case .none:
                EmptyView()
            case .opens:
                ChatStripChevron()
            case .discloses(let isExpanded):
                ChatSheetDisclosureChevron(isExpanded: isExpanded)
            }
        }
        .padding(.horizontal, ChatSheetStyle.rowInset)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .chatRowDivider(isDivided, inset: ChatSheetStyle.rowInset + glyphColumn + ChatSheetStyle.glyphSpacing)
    }
}

private enum ChatSwarmSheetStyle {
    /// A sheet row's glyph column, before Dynamic Type scales it.
    static let glyphColumn: CGFloat = 18
}

/// What a member is doing, as one glyph.
private struct ChatSwarmMemberGlyph: View {
    let status: AgySwarmSnapshot.MemberStatus
    let isStuck: Bool

    var body: some View {
        if isStuck {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
        } else {
            switch status {
            case .working:
                ChatBackgroundWorkGlyph(status: .running, size: .large)
            case .waiting:
                Image(systemName: "pause.circle")
                    .foregroundStyle(ChatSwarmPalette.memberStatusInk(.waiting))
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ChatSwarmPalette.memberStatusInk(.error))
            case .killed:
                ChatBackgroundWorkGlyph(status: .stopped, size: .large)
            }
        }
    }
}

extension AgySwarmSnapshot.Member {
    /// What it is doing, as a word.
    fileprivate var statusWord: String {
        if isStuck {
            return String(localized: "Stuck")
        }
        return switch status {
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Waiting")
        case .error: String(localized: "Error")
        case .killed: String(localized: "Stopped")
        }
    }

    /// Its model, where it names one, then how far it has got.
    fileprivate var statsLine: String {
        var parts = [String(localized: "\(steps) steps"), String(localized: "\(posts) posts")]
        if let displayModel {
            parts.insert(displayModel, at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

/// What a post reports of its work: that it is done, or that it stalled.
private struct ChatSwarmPostMark: View {
    let isDone: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isDone ? "checkmark" : "exclamationmark.triangle")
                .accessibilityHidden(true)
            if isDone {
                Text("Done")
            } else {
                Text("Stall")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ChatBackgroundWorkPalette.statusInk(isDone ? .completed : .failed))
        .fixedSize()
    }
}

/// One of the counts that head the Overview where nothing narrates it.
private struct ChatSwarmStat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(value)")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(verbatim: label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ChatSheetStyle.rowInset)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Board Compact Row & Post Detail Reader

/// A compact inset-grouped directory row on the Board: short posts display
/// cleanly inline while long posts preview two lines with a line-count badge
/// and open the full Markdown Post Detail reader on tap.
struct ChatSwarmBoardCard: View {
    let row: ChatSwarmBoardRow
    let openDetail: () -> Void

    private var message: AgySwarmSnapshot.BoardMessage { row.message }

    private var rowShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: row.isFirst ? 14 : 0,
            bottomLeadingRadius: row.isLast ? 14 : 0,
            bottomTrailingRadius: row.isLast ? 14 : 0,
            topTrailingRadius: row.isFirst ? 14 : 0,
            style: .continuous)
    }

    var body: some View {
        Button(action: openDetail) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    heading
                    preview
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if row.opensDetail {
                    HStack(spacing: 6) {
                        if message.lineCount > 2 {
                            Text("\(message.lineCount) lines")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        ChatStripChevron()
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, ChatSheetStyle.rowInset)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                rowShape
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        if row.isHighlighted {
                            rowShape.fill(ChatSwarmPalette.accentWash)
                        }
                    }
            }
            .contentShape(rowShape)
            .chatRowDivider(!row.isFirst, inset: ChatSheetStyle.rowInset)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.swarm.post.\(message.seq)")
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "#\(message.seq)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()

            Text(verbatim: "@\(message.agent)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let route {
                Text(verbatim: route)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if message.isBrief {
                Text("Brief")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .fixedSize()
            } else if message.isMarkedDone {
                ChatSwarmPostMark(isDone: true)
            } else if message.isMarkedStall {
                ChatSwarmPostMark(isDone: false)
            }

            if let clock = message.displayTime {
                Text(verbatim: clock)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if row.opensDetail {
            Text(verbatim: message.singleLinePreview)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        } else {
            Text(verbatim: message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
    }

    /// Whom the post is for, then its channel where that is not the main one.
    private var route: String? {
        var parts: [String] = []
        if let recipient = message.recipientSummary {
            parts.append("→ \(recipient)")
        }
        if message.channel != AgySwarmParser.mainChannel {
            parts.append("#\(message.channel)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Dedicated full-screen Markdown reader for a single Board post, with
/// citation jumping and sequential prev/next paging across the Board.
private struct ChatSwarmPostDetailView: View {
    private struct ParseKey: Equatable {
        var swarmID: String
        var seq: Int
        var boardRevision: Int
    }

    let chat: AgentChatStore
    let initialSeq: Int
    let filter: ChatSwarmBoardFilter
    let openWorker: (String) -> Void

    @State private var currentSeq: Int
    @State private var didCopy = false

    init(
        chat: AgentChatStore,
        initialSeq: Int,
        filter: ChatSwarmBoardFilter,
        openWorker: @escaping (String) -> Void
    ) {
        self.chat = chat
        self.initialSeq = initialSeq
        self.filter = filter
        self.openWorker = openWorker
        _currentSeq = State(initialValue: initialSeq)
    }

    var body: some View {
        let swarm = chat.agySwarm
        let orderedPosts = orderedPosts(in: swarm)
        let currentIndex = orderedPosts.firstIndex { $0.seq == currentSeq }
        let post = currentIndex.map { orderedPosts[$0] } ?? swarm?.boardPosts.first { $0.seq == currentSeq }
        let previousPost: AgySwarmSnapshot.BoardMessage? =
            if let idx = currentIndex, idx > 0 { orderedPosts[idx - 1] } else { nil }
        let nextPost: AgySwarmSnapshot.BoardMessage? =
            if let idx = currentIndex, idx + 1 < orderedPosts.count { orderedPosts[idx + 1] } else { nil }
        let parseKey = ParseKey(
            swarmID: swarm?.id ?? "",
            seq: currentSeq,
            boardRevision: swarm?.boardRevision ?? 0)

        Group {
            if let swarm, let post {
                let cited = post.citedSeqs(in: swarm.knownPostSeqs)
                let blocks = chat.swarmBoard.parsedBlocks(for: post.seq, text: post.text)
                let authorMember = swarm.members.first {
                    !$0.isCoordinator
                        && $0.name.caseInsensitiveCompare(post.agent) == .orderedSame
                        && ConversationReference.canonicalUUID($0.conversationID) != nil
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Color.clear
                                .frame(height: 0)
                                .id("post-top")

                            metadataCard(post: post, citedSeqs: cited, authorMember: authorMember)

                            Group {
                                if let blocks {
                                    ChatMarkdownView(blocks: blocks)
                                } else {
                                    Text(verbatim: post.text)
                                        .font(.body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .textSelection(.enabled)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                        .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: currentSeq) { _, _ in
                        didCopy = false
                        proxy.scrollTo("post-top", anchor: .top)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if orderedPosts.count > 1, let currentIndex {
                        pagerBar(
                            index: currentIndex,
                            total: orderedPosts.count,
                            previous: previousPost,
                            next: nextPost)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = post.text
                            didCopy = true
                            let copiedSeq = post.seq
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                if currentSeq == copiedSeq {
                                    didCopy = false
                                }
                            }
                        } label: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel(didCopy ? String(localized: "Copied") : String(localized: "Copy Post"))
                        .accessibilityIdentifier("chat.swarm.post.detail.copy")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Post Unavailable",
                    systemImage: "doc.text",
                    description: Text("This post is no longer on the board."))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(String(localized: "Post #\(currentSeq)"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chat.swarm.post.detail")
        .task(id: parseKey) {
            guard let swarm else { return }
            let targets = [post, previousPost, nextPost].compactMap(\.self)
            guard !targets.isEmpty else { return }
            chat.swarmBoard.ensureBlocks(swarmID: swarm.id, posts: targets)
        }
    }

    private func orderedPosts(in swarm: AgySwarmSnapshot?) -> [AgySwarmSnapshot.BoardMessage] {
        guard let swarm else { return [] }
        if filter != .all {
            let filtered = swarm.boardPosts.filter { filter.matches($0) }
            if filtered.contains(where: { $0.seq == currentSeq }) {
                return filtered
            }
        }
        return swarm.boardPosts
    }

    private func metadataCard(
        post: AgySwarmSnapshot.BoardMessage,
        citedSeqs: [Int],
        authorMember: AgySwarmSnapshot.Member?
    ) -> some View {
        let routeParts: [String] = {
            var parts: [String] = []
            if let recipient = post.recipientSummary {
                parts.append("→ \(recipient)")
            }
            if post.channel != AgySwarmParser.mainChannel {
                parts.append("#\(post.channel)")
            }
            return parts
        }()

        return ChatSheetSection {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let authorMember {
                        Button {
                            openWorker(authorMember.name)
                        } label: {
                            HStack(spacing: 3) {
                                Text(verbatim: "@\(post.agent)")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.tint)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .layoutPriority(1)
                    } else {
                        Text(verbatim: "@\(post.agent)")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    if !routeParts.isEmpty {
                        Text(verbatim: routeParts.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if post.isBrief {
                        Text("Brief")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else if post.isMarkedDone {
                        ChatSwarmPostMark(isDone: true)
                    } else if post.isMarkedStall {
                        ChatSwarmPostMark(isDone: false)
                    }
                }

                HStack(spacing: 10) {
                    let metaParts: [String] = {
                        var parts: [String] = []
                        if let clock = post.displayTime {
                            parts.append(clock)
                        }
                        if post.lineCount > 0 {
                            parts.append(String(localized: "\(post.lineCount) lines"))
                        }
                        return parts
                    }()
                    if !metaParts.isEmpty {
                        Text(verbatim: metaParts.joined(separator: " · "))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if !citedSeqs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.turn.up.left")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                                ForEach(citedSeqs, id: \.self) { @Sendable seq in
                                    MainActorContent {
                                        Button {
                                            currentSeq = seq
                                        } label: {
                                            Text(verbatim: "#\(seq)")
                                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                                .foregroundStyle(.tint)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Color.accentColor.opacity(0.14),
                                                    in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, ChatSheetStyle.rowInset)
            .padding(.vertical, 11)
        }
    }

    private func pagerBar(
        index: Int,
        total: Int,
        previous: AgySwarmSnapshot.BoardMessage?,
        next: AgySwarmSnapshot.BoardMessage?
    ) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    if let previous {
                        currentSeq = previous.seq
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                        if let previous {
                            Text(verbatim: "#\(previous.seq)")
                                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        } else {
                            Text("Previous")
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(previous == nil)
                .opacity(previous == nil ? 0.4 : 1)
                .accessibilityLabel(String(localized: "Previous post"))
                .accessibilityIdentifier("chat.swarm.post.detail.prev")

                Spacer(minLength: 4)

                Text(verbatim: "\(index + 1) / \(total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button {
                    if let next {
                        currentSeq = next.seq
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let next {
                            Text(verbatim: "#\(next.seq)")
                                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        } else {
                            Text("Next")
                                .font(.footnote.weight(.semibold))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(next == nil)
                .opacity(next == nil ? 0.4 : 1)
                .accessibilityLabel(String(localized: "Next post"))
                .accessibilityIdentifier("chat.swarm.post.detail.next")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

// MARK: - Member Row

/// A member in the Members tab: what it is doing as a glyph, its name and
/// role, how far it has got, then the one line that says what it is on or
/// what stopped it.
private struct ChatSwarmMemberRow: View {
    let member: AgySwarmSnapshot.Member
    let showsChevron: Bool
    let isDivided: Bool

    var body: some View {
        ChatSwarmGlyphRow(isDivided: isDivided, accessory: showsChevron ? .opens : .none) {
            ChatSwarmMemberGlyph(status: member.status, isStuck: member.isStuck)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(verbatim: member.statsLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                note
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(member.statusWord)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "@\(member.name)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(member.isKilled ? .secondary : .primary)
                .lineLimit(1)

            if let role {
                Text(verbatim: role)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if member.isCoordinator {
                Text("Main Chat")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else if !member.isKilled, member.unread > 0 {
                // What it has yet to read, in the tint.
                Text("+\(member.unread) unread")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .fixedSize()
            }
        }
    }

    private var role: String? {
        if member.isCoordinator {
            return String(localized: "Coordinator")
        }
        if member.isRoleWorker, !member.role.isEmpty {
            return member.role
        }
        if !member.workspaceMode.isEmpty, member.workspaceMode != "inherit" {
            return member.workspaceMode
        }
        return nil
    }

    @ViewBuilder
    private var note: some View {
        if let failure = member.failure {
            Text(verbatim: failure.detail)
                .font(.footnote)
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        } else if member.isStuck {
            Text("No transcript updates for over 10 minutes.")
                .font(.footnote)
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                .multilineTextAlignment(.leading)
        } else if let activity = member.activity, !activity.isEmpty {
            // A sentence about the step more often than a command.
            Text(verbatim: activity)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Narrated Overview

/// The Overview a narrator wrote: where the Swarm stands, what waits on a
/// decision, each workstream, and what is behind and ahead.
private struct ChatSwarmNarratorOverview: View {
    let overview: AgySwarmSnapshot.NarratorOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if hasSummary {
                summary
            }
            if !overview.attention.isEmpty {
                decisions
            }
            if !overview.workstreams.isEmpty {
                workstreams
            }
            if !overview.milestones.isEmpty {
                points(String(localized: "Milestones"), overview.milestones, isRisk: false)
            }
            if !overview.risks.isEmpty {
                points(String(localized: "Risks"), overview.risks, isRisk: true)
            }
        }
    }

    private var hasSummary: Bool {
        !overview.headline.isEmpty || overview.phase != nil || (overview.asOfSeq ?? 0) > 0
    }

    private var summary: some View {
        ChatSheetSection {
            VStack(alignment: .leading, spacing: 10) {
                if !overview.headline.isEmpty {
                    Text(verbatim: overview.headline)
                        .font(.headline)
                }
                if let phase = overview.phase {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(
                            value: Double(phase.index),
                            total: Double(max(1, phase.total)))
                            .progressViewStyle(.linear)
                            .tint(ChatSwarmPalette.accentInk)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: phase.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(verbatim: "\(phase.index)/\(phase.total)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let seq = overview.asOfSeq, seq > 0 {
                    Text("Updated at #\(seq)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    /// A decision that weighs on the Swarm leads with a warning; the rest
    /// with a dot.
    private var decisions: some View {
        ChatSheetSection(title: String(localized: "Decisions & Blockers")) {
            ForEach(Array(overview.attention.enumerated()), id: \.element.id) { @Sendable index, item in
                MainActorContent {
                    ChatSwarmGlyphRow(isDivided: index > 0) {
                        if item.severity == "high" {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.running))
                        } else {
                            Circle()
                                .fill(ChatBackgroundWorkPalette.statusInk(.stopped))
                                .frame(width: 6, height: 6)
                                // Mid-height of the title's letters.
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title)
                                .font(.callout)
                            if !item.why.isEmpty {
                                Text(verbatim: item.why)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var workstreams: some View {
        ChatSheetSection(title: String(localized: "Workstreams")) {
            ForEach(Array(overview.workstreams.enumerated()), id: \.element.id) { @Sendable index, stream in
                MainActorContent {
                    ChatSwarmWorkstreamRow(stream: stream, isDivided: index > 0)
                }
            }
        }
    }

    private func points(
        _ title: String, _ items: [AgySwarmSnapshot.NarratorOverview.Milestone], isRisk: Bool
    ) -> some View {
        ChatSheetSection(title: title) {
            ForEach(Array(items.enumerated()), id: \.element.id) { @Sendable index, item in
                MainActorContent {
                    ChatSwarmGlyphRow(isDivided: index > 0) {
                        if isRisk {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.running))
                        } else {
                            ChatBackgroundWorkGlyph(status: .completed, size: .large)
                        }
                    } content: {
                        Text(verbatim: item.text)
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

private struct ChatSwarmWorkstreamRow: View {
    let stream: AgySwarmSnapshot.NarratorOverview.Workstream
    let isDivided: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: stream.title)
                    .font(.callout)
                Spacer(minLength: 4)
                Text(verbatim: stream.state)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !stream.owners.isEmpty {
                Text(verbatim: stream.owners.map { "@\($0)" }.joined(separator: "  "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ChatSwarmPalette.accentInk)
            }
            if !stream.note.isEmpty {
                Text(verbatim: stream.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ChatSheetStyle.rowInset)
        .padding(.vertical, 12)
        .chatRowDivider(isDivided, inset: ChatSheetStyle.rowInset)
    }
}

// MARK: - Worker Read-Only Sub-Conversation Peek

struct ChatSwarmWorkerDetailView: View {
    private struct BlocksTaskKey: Equatable {
        var memberName: String
        var entryCount: Int
        var latestEntryID: ChatEntryID?
        var isAssignmentExpanded: Bool
        var expandedEntries: Set<ChatEntryID>
    }

    let chat: AgentChatStore
    let memberName: String
    let isHostConnected: Bool

    @State private var workerModel = ChatSwarmWorkerModel()
    @State private var transcript: ChatTranscript?
    @State private var failureMessage: String?
    @State private var isLoading = true
    @State private var isAssignmentExpanded = false
    @State private var expandedEntries: Set<ChatEntryID> = []
    @State private var disclosureItem: ChatSwarmWorkerItemID?
    @State private var pollSleeper: Task<Void, Never>?
    @State private var wakePollRequested = false

    private var liveMember: AgySwarmSnapshot.Member? {
        chat.agySwarm?.members.first { $0.name == memberName }
    }

    private var assignmentPost: AgySwarmSnapshot.BoardMessage? {
        chat.agySwarm?.assignmentPost(for: memberName)
    }

    var body: some View {
        let member = liveMember
        let assignment = assignmentPost
        let entries = transcript?.entries
        let listState = workerModel.buildState(
            memberName: memberName,
            member: member,
            assignment: assignment,
            isAssignmentExpanded: isAssignmentExpanded,
            isLoading: isLoading,
            failureMessage: failureMessage,
            entries: entries,
            expandedEntries: expandedEntries)
        let blocksKey = BlocksTaskKey(
            memberName: memberName,
            entryCount: entries?.count ?? 0,
            latestEntryID: entries?.last?.id,
            isAssignmentExpanded: isAssignmentExpanded,
            expandedEntries: expandedEntries)

        ChatSwarmListView(
            state: listState,
            disclosureAnchor: disclosureItem,
            initialMeasuredHeights: workerModel.measuredHeights,
            onMeasure: { id, height in
                workerModel.recordMeasuredHeight(height, for: id)
            },
            onForgetMeasurements: { kept in
                workerModel.forgetMeasuredHeights(keeping: kept)
            },
            accessibilityIdentifier: "chat.swarm.worker.\(memberName)"
        ) { item in
            workerRowView(item.payload)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(Text(verbatim: "@\(memberName)"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(memberName)-\(isHostConnected)") {
            await pollWorkerLoop()
        }
        .task(id: blocksKey) {
            workerModel.ensureBlocks(
                memberName: memberName,
                assignment: assignment,
                isAssignmentExpanded: isAssignmentExpanded,
                entries: entries ?? [],
                expandedEntries: expandedEntries)
        }
        .onChange(of: liveMember?.steps) { _, _ in
            wakePoll()
        }
    }

    @ViewBuilder
    private func workerRowView(_ row: ChatSwarmWorkerRow) -> some View {
        switch row {
        case .header(let member):
            workerHeader(member: member)
        case .assignment(let post, let isExpanded, let blocks):
            assignmentRow(post: post, isExpanded: isExpanded, blocks: blocks)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading worker conversation…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
        case .failure(let message):
            ContentUnavailableView(
                "Can't Show Worker Conversation",
                systemImage: "exclamationmark.bubble",
                description: Text(message))
                .padding(.vertical, 20)
        case .empty:
            ContentUnavailableView(
                "No Steps Recorded Yet",
                systemImage: "ellipsis.bubble",
                description: Text("This worker hasn't written any steps to its transcript yet."))
                .padding(.vertical, 20)
        case .entry(let entry, let isCollapsible, let lineCount, let isExpanded, let blocks):
            ChatSwarmWorkerEntryView(
                entry: entry,
                isCollapsible: isCollapsible,
                lineCount: lineCount,
                isExpanded: isExpanded,
                blocks: blocks,
                toggle: { toggleEntry(entry.id) })
        }
    }

    private func wakePoll() {
        if let pollSleeper {
            pollSleeper.cancel()
        } else {
            wakePollRequested = true
        }
    }

    private func pollWorkerLoop() async {
        await refreshOnce()
        while !Task.isCancelled {
            if wakePollRequested {
                wakePollRequested = false
            } else {
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(2)) }
                pollSleeper = sleeper
                await sleeper.value
                pollSleeper = nil
            }
            guard !Task.isCancelled else { return }
            let wokeEarly = wakePollRequested
            wakePollRequested = false
            if wokeEarly || liveMember?.status == .working {
                await refreshOnce()
            }
        }
    }

    private func refreshOnce() async {
        guard let member = liveMember else {
            isLoading = false
            return
        }
        switch await chat.loadSwarmWorkerTranscript(
            conversationID: member.conversationID,
            isWorking: member.status == .working)
        {
        case .success(let loaded):
            if transcript != loaded {
                transcript = loaded
            }
            failureMessage = nil
            isLoading = false
        case .failure(let error):
            failureMessage = error.message
            isLoading = false
        }
    }

    private func toggleEntry(_ id: ChatEntryID) {
        disclosureItem = .entry(id)
        if expandedEntries.contains(id) {
            expandedEntries.remove(id)
        } else {
            expandedEntries.insert(id)
        }
    }

    /// What the worker is doing and how far it has got, over the note
    /// that this page only reads.
    private func workerHeader(member: AgySwarmSnapshot.Member) -> some View {
        ChatSheetSection(
            footer: String(
                localized:
                    "Read-only view of this worker's sub-conversation. Send messages in the main Chat to guide the coordinator.")
        ) {
            ChatSwarmGlyphRow {
                ChatSwarmMemberGlyph(status: member.status, isStuck: member.isStuck)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: member.statusWord)
                        .font(.callout)
                    Text(verbatim: member.statsLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The brief that set the worker going: two lines of it, or all of it
    /// once opened.
    private func assignmentRow(
        post: AgySwarmSnapshot.BoardMessage,
        isExpanded: Bool,
        blocks: [ChatMarkdownBlock]?
    ) -> some View {
        ChatSheetSection {
            Button {
                disclosureItem = .assignment
                isAssignmentExpanded.toggle()
            } label: {
                ChatSwarmGlyphRow(accessory: .discloses(isExpanded: isExpanded)) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(ChatSwarmPalette.accentInk)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Assignment (#\(post.seq))")
                            .font(.callout)
                        if !isExpanded {
                            Text(verbatim: post.singleLinePreview)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Group {
                    if let blocks {
                        ChatMarkdownView(blocks: blocks)
                    } else {
                        Text(verbatim: post.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, ChatSheetStyle.rowInset)
                .padding(.bottom, 12)
            }
        }
    }
}

/// One step of a worker's sub-conversation. Short prose sits directly on the
/// page; long replies fold behind a compact line-count card and expand in
/// place; a tool call sits on a ground of its own.
private struct ChatSwarmWorkerEntryView: View {
    let entry: ChatEntry
    let isCollapsible: Bool
    let lineCount: Int
    let isExpanded: Bool
    let blocks: [ChatMarkdownBlock]?
    let toggle: () -> Void

    private static let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        switch entry.content {
        case .user(let message):
            userBubble(message.displayText)

        case .reasoning(let reasoning):
            if !reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                thinking(reasoning.text)
            }

        case .tool(let tool):
            ChatSwarmWorkerToolRow(tool: tool, isExpanded: isExpanded, toggle: toggle)

        case .assistant(let message):
            assistantMessage(message.text)

        case .notice(let notice):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: notice.kind == .error ? "exclamationmark.triangle" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(
                        notice.kind == .error ? ChatBackgroundWorkPalette.statusInk(.failed) : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: notice.title)
                        .font(.footnote.weight(.semibold))
                    if let detail = notice.detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .divider(let divider):
            if let detail = divider.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }

        case .plan, .questions:
            EmptyView()
        }
    }

    @ViewBuilder
    private func userBubble(_ text: String) -> some View {
        if isCollapsible {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: text)
                        .font(isExpanded ? .body : .footnote)
                        .lineLimit(isExpanded ? nil : 3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if lineCount > 1 {
                            Text("\(lineCount) lines")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ChatSheetDisclosureChevron(isExpanded: isExpanded)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.secondary, in: Self.cardShape)
                .contentShape(Self.cardShape)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(verbatim: text)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.secondary, in: Self.cardShape)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func assistantMessage(_ text: String) -> some View {
        if isCollapsible {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    HStack(alignment: .center, spacing: 10) {
                        if !isExpanded {
                            Text(verbatim: text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 6) {
                            if lineCount > 1 {
                                Text("\(lineCount) lines")
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            ChatSheetDisclosureChevron(isExpanded: isExpanded)
                        }
                        .fixedSize()
                    }
                    .padding(.horizontal, ChatSheetStyle.rowInset)
                    .padding(.vertical, isExpanded ? 8 : 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                        .padding(.horizontal, ChatSheetStyle.rowInset)
                    Group {
                        if let blocks {
                            ChatMarkdownView(blocks: blocks)
                        } else {
                            Text(verbatim: text)
                                .font(.body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ChatSheetStyle.rowInset)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Self.cardShape)
        } else {
            Group {
                if let blocks {
                    ChatMarkdownView(blocks: blocks)
                } else {
                    Text(verbatim: text)
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The worker's reasoning, behind one quiet line.
    private func thinking(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Thinking")
                        .font(.footnote)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let blocks {
                    ChatMarkdownView(blocks: blocks, isMuted: true)
                } else {
                    Text(verbatim: text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A tool call in a worker's sub-conversation: how it went as a glyph, its
/// title over what it ran or touched, and, opened, the change or the
/// output in the terminal's black.
private struct ChatSwarmWorkerToolRow: View {
    let tool: ChatToolActivity
    let isExpanded: Bool
    let toggle: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 16

    private static let ground = RoundedRectangle(cornerRadius: 12, style: .continuous)

    /// The files the call changed, where it changed any.
    private var changes: ChatFileChanges? {
        guard let changes = tool.fileChanges, !changes.files.isEmpty else { return nil }
        return changes
    }

    private var output: String? {
        guard let text = tool.preview?.text, !text.isEmpty else { return nil }
        return text
    }

    private var canExpand: Bool {
        output != nil || changes != nil
    }

    /// The Antigravity CLI titles a call by its command, path or pattern
    /// and puts its own sentence about the call under that.
    private var titleIsCode: Bool {
        switch tool.kind {
        case .command, .fileEdit, .fileWrite, .fileRead, .search, .listing: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if canExpand {
                Button(action: toggle) {
                    heading
                }
                .buttonStyle(.plain)
            } else {
                heading
            }

            if isExpanded {
                // The list's long press copies the row, so the text here
                // is not selectable.
                if let changes {
                    ChatTerminalChangeLines(
                        lines: changes.copyText.components(separatedBy: "\n"),
                        marks: .leading, isSmall: true, cornerRadius: 8, isSelectable: false)
                        .padding(.bottom, 6)
                } else if let output {
                    ChatTerminalText(text: output, isSmall: true, lineLimit: 30, cornerRadius: 8, isSelectable: false)
                        .padding(.bottom, 6)
                }
            }
        }
        .padding(.horizontal, ChatSheetStyle.rowInset)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Self.ground)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: ChatSheetStyle.glyphSpacing) {
            statusGlyph
                .frame(width: glyphColumn)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: tool.title)
                    .font(titleIsCode ? .system(.footnote, design: .monospaced) : .subheadline)
                    .lineLimit(isExpanded ? 4 : 1)
                    .multilineTextAlignment(.leading)
                if let subtitle = tool.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? 4 : 1)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let diff = tool.diff {
                HStack(spacing: 4) {
                    Text(verbatim: "+\(diff.added)")
                        .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.completed))
                    Text(verbatim: "-\(diff.removed)")
                        .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                }
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .fixedSize()
            }

            if canExpand {
                ChatSheetDisclosureChevron(isExpanded: isExpanded)
            }
        }
        .frame(minHeight: 32)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch tool.status {
        case .running, .awaitingApproval:
            ChatBackgroundWorkGlyph(status: .running, size: .regular)
        case .succeeded, .started:
            ChatBackgroundWorkGlyph(status: .completed, size: .regular)
        case .failed, .declined:
            ChatBackgroundWorkGlyph(status: .failed, size: .regular)
        case .interrupted, .notCompleted, .noResult, .chatInstead:
            Image(systemName: "minus")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
