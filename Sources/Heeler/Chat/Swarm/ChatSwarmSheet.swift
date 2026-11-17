import SwiftUI
import UIKit

/// Native 3-tab Swarm Sheet (`Board`, `Members`, `Overview`) plus pushed
/// read-only Worker sub-conversation view.
struct ChatSwarmSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case board
        case members
        case overview

        var id: String { rawValue }
    }

    let chat: AgentChatStore
    let isHostConnected: Bool
    let sheetPresentation: ConsoleSheetPresentation

    @State private var selectedTab: Tab
    @State private var selectedChannel: String?
    @State private var expandedBriefs: Set<Int> = []
    @State private var highlightedSeq: Int?
    @State private var pendingScrollSeq: Int?
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
        .modifier(ConsoleStatusSheetPresentationModifier(presentation: sheetPresentation))
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

                statusHeaderLine(swarm: swarm)
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

    private func statusHeaderLine(swarm: AgySwarmSnapshot) -> some View {
        HStack(spacing: 8) {
            ChatSwarmMemberDots(workers: swarm.taskWorkers)

            let activeCount = swarm.activeTaskWorkers.count
            let waitingCount = swarm.waitingTaskWorkers.count
            Text(verbatim: headerSummaryText(active: activeCount, waiting: waitingCount, posts: swarm.postCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if !isHostConnected || !swarm.isLive {
                Text("Offline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.stopped))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ChatBackgroundWorkPalette.statusWash(.stopped), in: Capsule())
            } else if swarm.hasSystemAlerts {
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

    // MARK: - Board Tab

    private func boardPage(swarm: AgySwarmSnapshot) -> some View {
        let posts = filteredPosts(in: swarm)
        let knownSeqs = Set(swarm.boardPosts.map(\.seq))
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
                .consoleSheetPage()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(posts) { message in
                                ChatSwarmBoardCard(
                                    message: message,
                                    knownSeqs: knownSeqs,
                                    isExpanded: expandedBriefs.contains(message.seq),
                                    isHighlighted: highlightedSeq == message.seq,
                                    toggleExpand: { toggleBrief(message.seq) },
                                    jumpToSeq: { target in jumpToMessage(target, in: swarm, proxy: proxy) })
                                    .id(message.seq)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 22)
                    }
                    .defaultScrollAnchor(.bottom)
                    .consoleSheetPage()
                    .onAppear {
                        if let seq = pendingScrollSeq {
                            pendingScrollSeq = nil
                            scrollAndHighlight(seq, proxy: proxy)
                        }
                    }
                    .onChange(of: pendingScrollSeq) { _, seq in
                        guard let seq else { return }
                        pendingScrollSeq = nil
                        scrollAndHighlight(seq, proxy: proxy)
                    }
                }
            }
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
            withAnimation(.snappy(duration: 0.18)) {
                selectedChannel = value
            }
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
        withAnimation(.snappy(duration: 0.2)) {
            if expandedBriefs.contains(seq) {
                expandedBriefs.remove(seq)
            } else {
                expandedBriefs.insert(seq)
            }
        }
    }

    private func jumpToMessage(_ seq: Int, in swarm: AgySwarmSnapshot, proxy: ScrollViewProxy) {
        if let targetMsg = swarm.boardPosts.first(where: { $0.seq == seq }),
            selectedChannel != nil, selectedChannel != targetMsg.channel
        {
            selectedChannel = nil
            pendingScrollSeq = seq
            return
        }
        scrollAndHighlight(seq, proxy: proxy)
    }

    private func scrollAndHighlight(_ seq: Int, proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.26)) {
            proxy.scrollTo(seq, anchor: .center)
            highlightedSeq = seq
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if highlightedSeq == seq {
                withAnimation(.easeOut(duration: 0.25)) {
                    highlightedSeq = nil
                }
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
            VStack(alignment: .leading, spacing: 18) {
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
        .consoleSheetPage()
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
                    narratorOverviewSection(overview: overview, swarm: swarm)
                } else {
                    computedOverviewSection(swarm: swarm)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)
        }
        .consoleSheetPage()
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

    private func narratorOverviewSection(
        overview: AgySwarmSnapshot.NarratorOverview, swarm: AgySwarmSnapshot
    ) -> some View {
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

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: swarm.displayTitle)
                    .font(.headline)

                HStack(spacing: 12) {
                    statTile(
                        value: "\(swarm.activeTaskWorkers.count)",
                        label: String(localized: "Active"),
                        tint: swarm.hasActiveWorkers ? ChatBackgroundWorkPalette.statusInk(.running) : .primary)
                    statTile(
                        value: "\(swarm.waitingTaskWorkers.count)",
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

private struct ChatSwarmBoardCard: View {
    let message: AgySwarmSnapshot.BoardMessage
    let knownSeqs: Set<Int>
    let isExpanded: Bool
    let isHighlighted: Bool
    let toggleExpand: () -> Void
    let jumpToSeq: (Int) -> Void

    private var isCoordinator: Bool {
        message.agent.caseInsensitiveCompare("coordinator") == .orderedSame
    }

    private var shouldCollapseBrief: Bool {
        guard message.isBrief else { return false }
        let newlineCount = message.text.count { $0 == "\n" }
        return newlineCount >= 6 || message.text.count > 360
    }

    private var citedSeqs: [Int] {
        var found: [Int] = []
        for match in message.text.matches(of: #/(?:^|[^\p{L}\p{Nd}_])#(\d{1,5})(?!\d)/#) {
            guard let n = Int(match.1), n != message.seq, knownSeqs.contains(n), !found.contains(n) else {
                continue
            }
            found.append(n)
        }
        return Array(found.prefix(6))
    }

    private var displayTime: String? {
        guard !message.time.isEmpty else { return nil }
        if let space = message.time.lastIndex(of: " ") {
            let clock = message.time[message.time.index(after: space)...]
            return String(clock.prefix(5))
        }
        return message.time
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

                if let clock = displayTime {
                    Text(verbatim: clock)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if shouldCollapseBrief && !isExpanded {
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
                ChatMarkdownView(blocks: ChatMarkdown.blocks(from: message.text))
                    .font(.subheadline)
                    .textSelection(.enabled)

                if shouldCollapseBrief {
                    Button(action: toggleExpand) {
                        Text("Show less")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ChatSwarmPalette.accentInk)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !citedSeqs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(citedSeqs, id: \.self) { seq in
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
                    if isHighlighted {
                        ChatBackgroundWorkStyle.card
                            .fill(ChatSwarmPalette.accentWash)
                    }
                }
        }
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(borderColor, lineWidth: isHighlighted ? 1.5 : 1)
        }
        .accessibilityIdentifier("chat.swarm.post.\(message.seq)")
    }

    private var borderColor: Color {
        if isHighlighted {
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
    let chat: AgentChatStore
    let memberName: String
    let isHostConnected: Bool

    @State private var transcript: ChatTranscript?
    @State private var failureMessage: String?
    @State private var isLoading = true
    @State private var isAssignmentExpanded = false
    @State private var expandedEntries: Set<ChatEntryID> = []

    private var liveMember: AgySwarmSnapshot.Member? {
        chat.agySwarm?.members.first { $0.name == memberName }
    }

    private var assignmentPost: AgySwarmSnapshot.BoardMessage? {
        chat.agySwarm?.boardPosts.first { post in
            post.isBrief && post.mentions.contains { $0.caseInsensitiveCompare(memberName) == .orderedSame }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let member = liveMember {
                    workerHeaderCard(member: member)
                }

                if let assignment = assignmentPost {
                    assignmentCard(post: assignment)
                }

                if isLoading, transcript == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading worker conversation…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
                } else if let failureMessage, transcript == nil {
                    ContentUnavailableView(
                        "Can't Show Worker Conversation",
                        systemImage: "exclamationmark.bubble",
                        description: Text(failureMessage))
                        .padding(.vertical, 20)
                } else if let entries = transcript?.entries, !entries.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            ChatSwarmWorkerEntryView(
                                entry: entry,
                                isExpanded: expandedEntries.contains(entry.id),
                                toggle: { toggleEntry(entry.id) })
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Steps Recorded Yet",
                        systemImage: "ellipsis.bubble",
                        description: Text("This worker hasn't written any steps to its transcript yet."))
                        .padding(.vertical, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(uiColor: .systemGroupedBackground))
        .consoleSheetPage()
        .navigationTitle(Text(verbatim: "@\(memberName)"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chat.swarm.worker.\(memberName)")
        .task(id: "\(memberName)-\(isHostConnected)") {
            await pollWorkerLoop()
        }
        .onChange(of: liveMember?.steps) { _, _ in
            Task { await refreshOnce() }
        }
    }

    private func pollWorkerLoop() async {
        await refreshOnce()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if liveMember?.status == .working {
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
            transcript = loaded
            failureMessage = nil
            isLoading = false
        case .failure(let error):
            failureMessage = error.message
            isLoading = false
        }
    }

    private func toggleEntry(_ id: ChatEntryID) {
        withAnimation(.snappy(duration: 0.2)) {
            if expandedEntries.contains(id) {
                expandedEntries.remove(id)
            } else {
                expandedEntries.insert(id)
            }
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

    private func assignmentCard(post: AgySwarmSnapshot.BoardMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isAssignmentExpanded.toggle()
                }
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
                        .rotationEffect(.degrees(isAssignmentExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isAssignmentExpanded {
                ChatMarkdownView(blocks: ChatMarkdown.blocks(from: post.text))
                    .font(.footnote)
                    .textSelection(.enabled)
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
                        ChatMarkdownView(blocks: ChatMarkdown.blocks(from: reasoning.text), isMuted: true)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75), in: Self.innerBox)
            }

        case .tool(let tool):
            toolCard(tool)

        case .assistant(let message):
            ChatMarkdownView(blocks: ChatMarkdown.blocks(from: message.text))
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatBackgroundWorkStyle.card)
                .textSelection(.enabled)

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
                        .textSelection(.enabled)
                } else if let preview = tool.preview?.text, !preview.isEmpty {
                    Text(verbatim: preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
                        .textSelection(.enabled)
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
