import SwiftUI
import UIKit

/// Sheet presentation for the 3-tab Swarm console: standard form sizing on
/// regular width (never re-measuring scroll geometry on every frame) and
/// expandable bottom detents on compact width.
private struct ChatSwarmSheetPresentationModifier: ViewModifier {
    let presentation: ConsoleSheetPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        switch presentation {
        case .form:
            content
                .presentationSizing(.form)
                .presentationBackground(ConsoleStatusSheetPresentationModifier.formBackground)
        case .inheritedSheet:
            content
                .presentationDetents([.fraction(0.6), .large])
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

private struct ChatSwarmHeaderStatusBar: View, Equatable {
    let summary: ChatSwarmHeaderSummary

    var body: some View {
        HStack(spacing: 8) {
            ChatSwarmStatusDots(statuses: summary.dotStatuses)

            Text(
                verbatim: headerSummaryText(
                    active: summary.activeCount,
                    waiting: summary.waitingCount,
                    posts: summary.postCount)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 0)

            if summary.isOffline {
                Text("Offline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.stopped))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ChatBackgroundWorkPalette.statusWash(.stopped), in: Capsule())
            } else if summary.hasSystemAlerts {
                Text("Needs attention")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ChatBackgroundWorkPalette.statusWash(.failed), in: Capsule())
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
/// read-only Worker sub-conversation view.
struct ChatSwarmSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case board
        case members
        case overview

        var id: String { rawValue }
    }

    private struct BoardBlocksTaskKey: Equatable {
        var swarmID: String
        var boardRevision: Int
        var channel: String?
        var expandedBriefs: Set<Int>
    }

    let chat: AgentChatStore
    let isHostConnected: Bool
    let sheetPresentation: ConsoleSheetPresentation

    @State private var selectedTab: Tab
    @State private var selectedChannel: String?
    @State private var expandedBriefs: Set<Int> = []
    @State private var highlightedSeq: Int?
    @State private var pendingScrollSeq: Int?
    @State private var scrollRequest: ChatSwarmScrollRequest<Int>?
    @State private var scrollNonce = 0
    @State private var disclosureSeq: Int?
    @State private var showsKilledMembers = false
    @State private var path: [String] = []
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
            .navigationDestination(for: String.self) { memberName in
                ChatSwarmWorkerDetailView(
                    chat: chat,
                    memberName: memberName,
                    isHostConnected: isHostConnected)
            }
        }
        .modifier(ChatSwarmSheetPresentationModifier(presentation: sheetPresentation))
        .accessibilityIdentifier("chat.swarm.sheet")
        .onChange(of: chat.agySwarm == nil) { _, isNil in
            if isNil { dismiss() }
        }
    }

    private func rootPage(swarm: AgySwarmSnapshot) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
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
            .padding(.bottom, 10)
            .background(Color(uiColor: .systemGroupedBackground))

            Divider()
                .opacity(0.45)

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

    // MARK: - Board Tab

    private func boardPage(swarm: AgySwarmSnapshot) -> some View {
        let posts = filteredPosts(in: swarm)
        let boardModel = chat.swarmBoard
        let listState = boardModel.buildState(
            swarmID: swarm.id,
            channel: selectedChannel,
            posts: posts,
            knownSeqs: swarm.knownPostSeqs,
            expandedBriefs: expandedBriefs,
            highlightedSeq: highlightedSeq)
        let blocksKey = BoardBlocksTaskKey(
            swarmID: swarm.id,
            boardRevision: swarm.boardRevision,
            channel: selectedChannel,
            expandedBriefs: expandedBriefs)

        return VStack(spacing: 0) {
            if !swarm.channels.isEmpty {
                channelFilterBar(channels: swarm.channels)
                Divider().opacity(0.35)
            }

            if posts.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "No Board Posts Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Assignments and findings posted by swarm members appear here."))
                        .padding(.vertical, 36)
                }
            } else {
                ChatSwarmListView(
                    state: listState,
                    scrollRequest: scrollRequest,
                    disclosureAnchor: disclosureSeq,
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
                        toggleExpand: { toggleBrief(item.id) },
                        jumpToSeq: { target in jumpToMessage(target) })
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
        .task(id: blocksKey) {
            boardModel.ensureBlocks(
                swarmID: swarm.id,
                posts: posts,
                expandedBriefs: expandedBriefs)
        }
    }

    private func filteredPosts(in swarm: AgySwarmSnapshot) -> [AgySwarmSnapshot.BoardMessage] {
        guard let selectedChannel else { return swarm.boardPosts }
        return swarm.boardPosts.filter { $0.channel == selectedChannel }
    }

    private func channelFilterBar(channels: [AgySwarmSnapshot.Channel]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                channelChip(label: String(localized: "All"), value: nil, isArchived: false)
                channelChip(label: "#main", value: AgySwarmParser.mainChannel, isArchived: false)
                ForEach(channels) { ch in
                    channelChip(label: "#\(ch.name)", value: ch.name, isArchived: ch.isArchived)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func channelChip(label: String, value: String?, isArchived: Bool) -> some View {
        let isSelected = selectedChannel == value
        return Button {
            disclosureSeq = nil
            selectedChannel = value
        } label: {
            Text(verbatim: label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isSelected
                        ? ChatSwarmPalette.accentInk
                        : (isArchived ? Color(uiColor: .tertiaryLabel) : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? ChatSwarmPalette.accentWash : Color.primary.opacity(0.06),
                    in: Capsule())
                .overlay {
                    if isSelected {
                        Capsule().stroke(ChatSwarmPalette.accentInk.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func toggleBrief(_ seq: Int) {
        disclosureSeq = seq
        if expandedBriefs.contains(seq) {
            expandedBriefs.remove(seq)
        } else {
            expandedBriefs.insert(seq)
        }
    }

    private func jumpToMessage(_ seq: Int) {
        if let swarm = chat.agySwarm,
            let targetMsg = swarm.boardPosts.first(where: { $0.seq == seq }),
            selectedChannel != nil,
            selectedChannel != targetMsg.channel
        {
            selectedChannel = nil
            pendingScrollSeq = seq
            return
        }
        scrollAndHighlight(seq)
    }

    private func scrollAndHighlight(_ seq: Int) {
        disclosureSeq = nil
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
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(coordinators) { coordinator in
                    memberCardButton(coordinator)
                }

                if !active.isEmpty {
                    memberSection(
                        title: String(localized: "Active"),
                        count: active.count,
                        highlightsCount: true,
                        members: active)
                }

                if !waiting.isEmpty {
                    memberSection(
                        title: String(localized: "Waiting"),
                        count: waiting.count,
                        highlightsCount: false,
                        members: waiting)
                }

                if !killed.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                showsKilledMembers.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("Stopped")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                Text(verbatim: "\(killed.count)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.stopped))
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 1.5)
                                    .background(ChatBackgroundWorkPalette.statusWash(.stopped), in: Capsule())
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showsKilledMembers ? 90 : 0))
                            }
                            .padding(.horizontal, 4)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        if showsKilledMembers {
                            ForEach(killed) { member in
                                memberCardButton(member)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }

    private func memberSection(
        title: String, count: Int, highlightsCount: Bool, members: [AgySwarmSnapshot.Member]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(
                        highlightsCount
                            ? ChatBackgroundWorkPalette.statusInk(.running)
                            : ChatBackgroundWorkPalette.statusInk(.stopped))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .background(
                        highlightsCount
                            ? ChatBackgroundWorkPalette.statusWash(.running)
                            : ChatBackgroundWorkPalette.statusWash(.stopped),
                        in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            ForEach(members) { member in
                memberCardButton(member)
            }
        }
    }

    @ViewBuilder
    private func memberCardButton(_ member: AgySwarmSnapshot.Member) -> some View {
        let canOpenWorker = !member.isCoordinator && ConversationReference.canonicalUUID(member.conversationID) != nil
        if member.isCoordinator {
            Button {
                dismiss()
            } label: {
                ChatSwarmMemberCard(member: member, showsChevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.swarm.member.\(member.name)")
        } else if canOpenWorker {
            Button {
                path.append(member.name)
            } label: {
                ChatSwarmMemberCard(member: member, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.swarm.member.\(member.name)")
        } else {
            ChatSwarmMemberCard(member: member, showsChevron: false)
                .accessibilityIdentifier("chat.swarm.member.\(member.name)")
        }
    }

    // MARK: - Overview Tab

    private func overviewPage(swarm: AgySwarmSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !swarm.systemAlerts.isEmpty {
                    systemAlertsSection(swarm: swarm)
                }

                if let overview = swarm.overview {
                    narratorOverviewSection(overview: overview)
                } else {
                    computedOverviewSection(swarm: swarm)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
    }

    private func systemAlertsSection(swarm: AgySwarmSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(String(localized: "Attention"))

            ForEach(swarm.systemAlerts) { alert in
                let canOpen = ConversationReference.canonicalUUID(alert.conversationID) != nil
                Button {
                    if canOpen { path.append(alert.member) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: alert.kind == .stuck ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(verbatim: "@\(alert.member)")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: alertBadgeTitle(alert.kind))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(ChatBackgroundWorkPalette.statusWash(.failed), in: Capsule())
                            }
                            Text(verbatim: alert.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 4)

                        if canOpen {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                                .padding(.top, 4)
                        }
                    }
                    .padding(12)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: ChatBackgroundWorkStyle.card)
                    .overlay {
                        ChatBackgroundWorkStyle.card
                            .stroke(Color(uiColor: AgentStatusPalette.red).opacity(0.32), lineWidth: 1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
            }
        }
    }

    private func alertBadgeTitle(_ kind: AgySwarmSnapshot.SystemAlert.Kind) -> String {
        switch kind {
        case .quota: String(localized: "Quota")
        case .error: String(localized: "Error")
        case .stuck: String(localized: "No progress")
        }
    }

    private func narratorOverviewSection(overview: AgySwarmSnapshot.NarratorOverview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if !overview.headline.isEmpty {
                    Text(verbatim: overview.headline)
                        .font(.body.weight(.semibold))
                }
                if let phase = overview.phase {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(
                            value: Double(phase.index),
                            total: Double(max(1, phase.total)))
                            .progressViewStyle(.linear)
                            .tint(ChatSwarmPalette.accentInk)
                        HStack {
                            Text(verbatim: phase.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: "\(phase.index)/\(phase.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let seq = overview.asOfSeq, seq > 0 {
                    Text("Updated at #\(seq)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
            .overlay {
                ChatBackgroundWorkStyle.card
                    .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
            }

            if !overview.attention.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading(String(localized: "Decisions & Blockers"))
                    ForEach(overview.attention) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: item.title)
                                .font(.subheadline.weight(.semibold))
                            if !item.why.isEmpty {
                                Text(verbatim: item.why)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
                        .overlay {
                            ChatBackgroundWorkStyle.card
                                .stroke(
                                    item.severity == "high"
                                        ? Color(uiColor: AgentStatusPalette.yellow).opacity(0.35)
                                        : Color(uiColor: .separator).opacity(0.34),
                                    lineWidth: 1)
                        }
                    }
                }
            }

            if !overview.workstreams.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading(String(localized: "Workstreams"))
                    ForEach(overview.workstreams) { stream in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: stream.title)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 4)
                                Text(verbatim: stream.state)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            if !stream.owners.isEmpty {
                                Text(verbatim: stream.owners.map { "@\($0)" }.joined(separator: "  "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(ChatSwarmPalette.accentInk)
                            }
                            if !stream.note.isEmpty {
                                Text(verbatim: stream.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
                        .overlay {
                            ChatBackgroundWorkStyle.card
                                .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
                        }
                    }
                }
            }

            if !overview.milestones.isEmpty {
                bulletListCard(title: String(localized: "Milestones"), items: overview.milestones, icon: "checkmark.circle.fill", tint: ChatBackgroundWorkPalette.statusInk(.completed))
            }

            if !overview.risks.isEmpty {
                bulletListCard(title: String(localized: "Risks"), items: overview.risks, icon: "exclamationmark.circle.fill", tint: ChatBackgroundWorkPalette.statusInk(.running))
            }
        }
    }

    private func bulletListCard(
        title: String, items: [AgySwarmSnapshot.NarratorOverview.Milestone], icon: String, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(title)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(tint)
                        Text(verbatim: item.text)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
            .overlay {
                ChatBackgroundWorkStyle.card
                    .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
            }
        }
    }

    private func computedOverviewSection(swarm: AgySwarmSnapshot) -> some View {
        let highlights = swarm.boardPosts.filter {
            $0.isMarkedDone || $0.isMarkedStall || ($0.mentionsCoordinator && !$0.isBrief)
        }.suffix(6)
        let workers = swarm.taskWorkers
        let activeCount = workers.count { $0.status == .working }
        let waitingCount = workers.count { $0.status == .waiting }

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: swarm.displayTitle)
                    .font(.headline)

                HStack(spacing: 12) {
                    statTile(
                        value: "\(activeCount)",
                        label: String(localized: "Active"),
                        tint: activeCount > 0 ? ChatBackgroundWorkPalette.statusInk(.running) : .primary)
                    statTile(
                        value: "\(waitingCount)",
                        label: String(localized: "Waiting"),
                        tint: .primary)
                    statTile(
                        value: "\(swarm.postCount)",
                        label: String(localized: "Posts"),
                        tint: ChatSwarmPalette.accentInk)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
            .overlay {
                ChatBackgroundWorkStyle.card
                    .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
            }

            if !swarm.channels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading(String(localized: "Channels"))
                    ForEach(swarm.channels) { channel in
                        Button {
                            selectedChannel = channel.name
                            selectedTab = .board
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: "#\(channel.name)")
                                    .font(.subheadline.weight(.semibold).monospaced())
                                    .foregroundStyle(ChatSwarmPalette.accentInk)
                                if !channel.topic.isEmpty {
                                    Text(verbatim: channel.topic)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                            }
                            .padding(12)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: ChatBackgroundWorkStyle.card)
                            .overlay {
                                ChatBackgroundWorkStyle.card
                                    .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading(String(localized: "Key Updates"))
                    ForEach(Array(highlights)) { post in
                        Button {
                            selectedChannel = nil
                            pendingScrollSeq = post.seq
                            selectedTab = .board
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: "#\(post.seq)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(ChatSwarmPalette.accentInk)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: "@\(post.agent)")
                                            .font(.caption.weight(.semibold))
                                        if post.isMarkedDone {
                                            Text("Done")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.completed))
                                        } else if post.isMarkedStall {
                                            Text("Stall")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                                        }
                                    }
                                    Text(verbatim: post.singleLinePreview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                                    .padding(.top, 2)
                            }
                            .padding(12)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: ChatBackgroundWorkStyle.card)
                            .overlay {
                                ChatBackgroundWorkStyle.card
                                    .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func statTile(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }
}

// MARK: - Board Message Card

struct ChatSwarmBoardCard: View {
    let row: ChatSwarmBoardRow
    let toggleExpand: () -> Void
    let jumpToSeq: (Int) -> Void

    private var message: AgySwarmSnapshot.BoardMessage { row.message }

    private var isCoordinator: Bool {
        message.agent.caseInsensitiveCompare("coordinator") == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(verbatim: "#\(message.seq)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(isCoordinator ? ChatSwarmPalette.coordinatorInk : ChatSwarmPalette.accentInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isCoordinator ? ChatSwarmPalette.coordinatorWash : ChatSwarmPalette.accentWash,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text(verbatim: "@\(message.agent)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isCoordinator ? ChatSwarmPalette.coordinatorInk : .primary)

                if let recipient = message.recipientSummary {
                    Text(verbatim: "→ \(recipient)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if message.channel != AgySwarmParser.mainChannel {
                    badge(text: "#\(message.channel)", ink: ChatSwarmPalette.accentInk, wash: ChatSwarmPalette.accentWash)
                }
                if message.isBrief {
                    badge(
                        text: String(localized: "Brief"),
                        ink: ChatBackgroundWorkPalette.statusInk(.stopped),
                        wash: ChatBackgroundWorkPalette.statusWash(.stopped))
                } else if message.isMarkedDone {
                    badge(
                        text: String(localized: "Done"),
                        ink: ChatBackgroundWorkPalette.statusInk(.completed),
                        wash: ChatBackgroundWorkPalette.statusWash(.completed))
                } else if message.isMarkedStall {
                    badge(
                        text: String(localized: "Stall"),
                        ink: ChatBackgroundWorkPalette.statusInk(.failed),
                        wash: ChatBackgroundWorkPalette.statusWash(.failed))
                }

                if let clock = message.displayTime {
                    Text(verbatim: clock)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if row.isCollapsedBrief {
                Text(verbatim: message.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: toggleExpand) {
                    Text("Show full brief")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChatSwarmPalette.accentInk)
                }
                .buttonStyle(.plain)
            } else {
                if let blocks = row.blocks {
                    ChatMarkdownView(blocks: blocks)
                        .font(.subheadline)
                } else {
                    Text(verbatim: message.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if message.shouldCollapseBrief {
                    Button(action: toggleExpand) {
                        Text("Show less")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ChatSwarmPalette.accentInk)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !row.citedSeqs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(row.citedSeqs, id: \.self) { seq in
                        Button {
                            jumpToSeq(seq)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.turn.up.left")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(verbatim: "#\(seq)")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                            }
                            .foregroundStyle(ChatSwarmPalette.accentInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(ChatSwarmPalette.accentWash, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ChatBackgroundWorkStyle.card
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    if row.isHighlighted {
                        ChatBackgroundWorkStyle.card
                            .fill(ChatSwarmPalette.accentWash)
                    }
                }
        }
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(borderColor, lineWidth: row.isHighlighted ? 1.5 : 1)
        }
        .accessibilityIdentifier("chat.swarm.post.\(message.seq)")
    }

    private var borderColor: Color {
        if row.isHighlighted {
            return ChatSwarmPalette.accentInk
        }
        if message.isMarkedStall {
            return Color(uiColor: AgentStatusPalette.red).opacity(0.30)
        }
        if isCoordinator {
            return ChatSwarmPalette.coordinatorInk.opacity(0.28)
        }
        return Color(uiColor: .separator).opacity(0.34)
    }

    private func badge(text: String, ink: Color, wash: Color) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(wash, in: Capsule())
    }
}

// MARK: - Member Card

struct ChatSwarmMemberCard: View {
    let member: AgySwarmSnapshot.Member
    let showsChevron: Bool

    private static let innerBox = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                ChatSwarmMemberStatusPill(status: member.status, isStuck: member.isStuck)

                Text(verbatim: "@\(member.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(member.isKilled ? .secondary : .primary)
                    .lineLimit(1)

                if member.isCoordinator {
                    roleBadge(String(localized: "Coordinator"), isCoordinator: true)
                } else if member.isRoleWorker {
                    roleBadge(member.role, isCoordinator: false)
                } else if !member.workspaceMode.isEmpty, member.workspaceMode != "inherit" {
                    roleBadge(member.workspaceMode, isCoordinator: false)
                }

                Spacer(minLength: 4)

                if member.isCoordinator {
                    Text("Main Chat")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }

            HStack(spacing: 8) {
                if let model = member.displayModel {
                    Text(verbatim: model)
                        .lineLimit(1)
                    Text(verbatim: "·")
                }
                Text(verbatim: statsText)
                    .monospacedDigit()
                if !member.isCoordinator, !member.isKilled, member.unread > 0 {
                    Text("+\(member.unread) unread")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(ChatSwarmPalette.accentInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(ChatSwarmPalette.accentWash, in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let failure = member.failure {
                Text(verbatim: failure.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(ChatBackgroundWorkPalette.statusWash(.failed), in: Self.innerBox)
            } else if let activity = member.activity, !activity.isEmpty {
                Text(verbatim: activity)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
                    .overlay {
                        Self.innerBox.stroke(ChatBackgroundWorkPalette.terminalBorder, lineWidth: 1)
                    }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ChatBackgroundWorkStyle.card
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    if member.status == .working {
                        ChatBackgroundWorkStyle.card.fill(
                            LinearGradient(
                                colors: [Color(uiColor: AgentStatusPalette.yellow).opacity(0.06), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
                    }
                }
        }
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(cardBorder, lineWidth: 1)
        }
        .contentShape(.rect)
    }

    private var statsText: String {
        let stepsLabel = String(localized: "\(member.steps) steps")
        let postsLabel = String(localized: "\(member.posts) posts")
        return "\(stepsLabel) · \(postsLabel)"
    }

    private var cardBorder: Color {
        switch member.status {
        case .working:
            return Color(uiColor: AgentStatusPalette.yellow).opacity(0.32)
        case .error:
            return Color(uiColor: AgentStatusPalette.red).opacity(0.32)
        case .waiting, .killed:
            return Color(uiColor: .separator).opacity(0.34)
        }
    }

    private func roleBadge(_ text: String, isCoordinator: Bool) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isCoordinator ? ChatSwarmPalette.coordinatorInk : ChatSwarmPalette.accentInk)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(
                isCoordinator ? ChatSwarmPalette.coordinatorWash : ChatSwarmPalette.accentWash,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ChatSwarmMemberStatusPill: View {
    let status: AgySwarmSnapshot.MemberStatus
    var isStuck = false

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(verbatim: label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(wash, in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        if isStuck {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 9.5, weight: .semibold))
        } else {
            switch status {
            case .working:
                ChatBackgroundWorkSpinningArc(size: 11, lineWidth: 1.9)
            case .waiting:
                Image(systemName: "pause.fill")
                    .font(.system(size: 8.5, weight: .bold))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .bold))
            case .killed:
                Image(systemName: "stop.fill")
                    .font(.system(size: 8.5, weight: .bold))
            }
        }
    }

    private var label: String {
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

    private var ink: Color {
        isStuck ? ChatBackgroundWorkPalette.statusInk(.failed) : ChatSwarmPalette.memberStatusInk(status)
    }

    private var wash: Color {
        isStuck ? ChatBackgroundWorkPalette.statusWash(.failed) : ChatSwarmPalette.memberStatusWash(status)
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
        chat.agySwarm?.boardPosts.first { post in
            post.isBrief && post.mentions.contains { $0.caseInsensitiveCompare(memberName) == .orderedSame }
        }
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
            workerHeaderCard(member: member)
        case .assignment(let post, let isExpanded, let blocks):
            assignmentCard(post: post, isExpanded: isExpanded, blocks: blocks)
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
        case .entry(let entry, let isExpanded, let blocks):
            ChatSwarmWorkerEntryView(
                entry: entry,
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

    private func workerHeaderCard(member: AgySwarmSnapshot.Member) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ChatSwarmMemberStatusPill(status: member.status, isStuck: member.isStuck)
                if let model = member.displayModel {
                    Text(verbatim: model)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                let stepsLabel = String(localized: "\(member.steps) steps")
                let postsLabel = String(localized: "\(member.posts) posts")
                Text(verbatim: "\(stepsLabel) · \(postsLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Read-only view of this worker's sub-conversation. Send messages in the main Chat to guide the coordinator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(Color(uiColor: .separator).opacity(0.34), lineWidth: 1)
        }
    }

    private func assignmentCard(
        post: AgySwarmSnapshot.BoardMessage,
        isExpanded: Bool,
        blocks: [ChatMarkdownBlock]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                disclosureItem = .assignment
                isAssignmentExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChatSwarmPalette.accentInk)
                    Text("Assignment (#\(post.seq))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ChatSwarmPalette.accentInk)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let blocks {
                    ChatMarkdownView(blocks: blocks)
                        .font(.footnote)
                } else {
                    Text(verbatim: post.text)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(verbatim: post.singleLinePreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(ChatSwarmPalette.accentInk.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct ChatSwarmWorkerEntryView: View {
    let entry: ChatEntry
    let isExpanded: Bool
    let blocks: [ChatMarkdownBlock]?
    let toggle: () -> Void

    private static let innerBox = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        switch entry.content {
        case .user(let message):
            Text(verbatim: message.displayText)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.secondary, in: .rect(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .reasoning(let reasoning):
            if !reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: toggle) {
                        HStack(spacing: 6) {
                            Image(systemName: "brain")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Thinking")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        if let blocks {
                            ChatMarkdownView(blocks: blocks, isMuted: true)
                                .font(.footnote)
                        } else {
                            Text(verbatim: reasoning.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75), in: Self.innerBox)
            }

        case .tool(let tool):
            toolCard(tool)

        case .assistant(let message):
            Group {
                if let blocks {
                    ChatMarkdownView(blocks: blocks)
                        .font(.subheadline)
                } else {
                    Text(verbatim: message.text)
                        .font(.body)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)

        case .notice(let notice):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(
                        notice.kind == .error ? ChatBackgroundWorkPalette.statusInk(.failed) : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: notice.title)
                        .font(.caption.weight(.semibold))
                    if let detail = notice.detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

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

    private func toolCard(_ tool: ChatToolActivity) -> some View {
        let canExpand = (tool.preview != nil && !(tool.preview?.text.isEmpty ?? true)) || tool.fileChanges != nil
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if canExpand { toggle() }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    toolStatusIcon(tool.status)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: tool.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? 4 : 1)
                            .multilineTextAlignment(.leading)
                        if let subtitle = tool.subtitle, !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? 4 : 1)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 4)

                    if let diff = tool.diff {
                        HStack(spacing: 4) {
                            Text(verbatim: "+\(diff.added)")
                                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.completed))
                            Text(verbatim: "-\(diff.removed)")
                                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                        }
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    }

                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)

            if isExpanded {
                if let changes = tool.fileChanges, !changes.files.isEmpty {
                    Text(verbatim: changes.copyText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
                } else if let preview = tool.preview?.text, !preview.isEmpty {
                    Text(verbatim: preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Self.innerBox)
        .overlay {
            Self.innerBox.stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func toolStatusIcon(_ status: ChatToolActivity.Status) -> some View {
        switch status {
        case .running, .awaitingApproval:
            ChatBackgroundWorkSpinningArc(size: 11, lineWidth: 1.8)
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.running))
        case .succeeded, .started:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.completed))
        case .failed, .declined:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
        case .interrupted, .notCompleted, .noResult, .chatInstead:
            Image(systemName: "minus.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
