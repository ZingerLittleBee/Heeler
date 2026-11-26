import SwiftUI
import UIKit

/// Where the GitHub tab presents Send to Agent, which the Console owns.
struct GitHubSendLink {
    let present: @MainActor (GitHubSendRequest) -> Void
}

/// A pull request or an issue: how it stands, what it says, Send to Agent,
/// and Comment, Approve, Merge and Close from its "⋯" (ADR 0065). Its list
/// row shows at once; the rest comes from a read of the one item, again on
/// a pull and around every write.
struct GitHubItemScreen: View {
    let store: GitHubStore
    let host: GitHubHost
    /// The item as the list showed it when the detail opened.
    let item: GitHubItem
    let send: GitHubSendLink?
    let write: GitHubWriteLink
    /// The picture or video the description opened.
    @State private var shownMedia: GitHubBody.Item?

    var body: some View {
        let state = store.detailState(of: item, on: host)
        let detail = state.detail
        let current = detail?.item ?? store.listItem(item.id, on: host) ?? item
        let viewer = detail?.viewer ?? store.state(of: host).list?.login
        let isConnected = store.isConnected(host)
        let isOffline = !isConnected || state.failure == .offline
        let readFailure = GitHubSubtitle.isShown && !isOffline ? state.failure.flatMap { Self.words(for: $0) } : nil
        List {
            Section {
                GitHubItemHeader(item: current, detail: detail, viewer: viewer)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            // On iOS 26 the line under the title says it, and the page
            // stays where it is.
            if !GitHubSubtitle.isShown,
                let banner = GitHubBannerText(
                    detailFailure: state.failure, isOffline: isOffline, host: host, readAt: detail?.readAt)
            {
                Section {
                    GitHubBanner(text: banner)
                }
            }
            Section {
                GitHubItemFacts(item: current, detail: detail, viewer: viewer, isReading: state.isReading)
            }
            if let detail {
                Section {
                    GitHubBodyView(text: detail.body, media: detail.media, actions: mediaActions)
                }
            } else if state.isReading {
                Section {
                    GitHubBodyView.placeholder
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 8, for: .scrollContent)
        .readableColumnPage()
        .navigationTitle(Text(verbatim: "#\(current.number)"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(GitHubSubtitleLine(subtitle: Self.subtitle(of: state, isConnected: isConnected)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GitHubItemMenu(
                    store: store, host: host, item: item, current: current, detail: detail,
                    readFailure: readFailure, write: write)
            }
        }
        .modifier(GitHubSendBar(isShown: send != nil) {
            Button {
                send?.present(GitHubSendRequest(host: host, item: current))
            } label: {
                Text("Send to Agent…")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: ReadableColumn.width)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        })
        .task(id: DetailTrigger(host: host.id, item: item.id, isConnected: store.isConnected(host))) {
            await store.openDetail(item, on: host)
        }
        .refreshable { await store.reread(item, on: host) }
        .sheet(item: $shownMedia) { shown in
            GitHubMediaViewer(item: shown, resolve: mediaActions.resolve) { shownMedia = nil }
        }
    }

    private var mediaActions: GitHubMediaActions {
        GitHubMediaActions(
            resolve: { [store, host, item] media, refresh in
                await store.mediaURL(media, refresh: refresh, of: item, on: host)
            },
            open: { [$shownMedia] shown in $shownMedia.wrappedValue = shown })
    }

    private struct DetailTrigger: Equatable {
        let host: Host.ID
        let item: GitHubItem.ID
        let isConnected: Bool
    }

    /// The line under the number, from the first frame: the list's row
    /// shows at once, and the detail's read starts with the screen.
    private static func subtitle(of state: GitHubStore.DetailState, isConnected: Bool) -> GitHubSubtitle {
        let readAt = state.detail?.readAt
        guard isConnected else { return .status(GitHubHostStatus(kind: .offline), readAt: readAt) }
        if state.isReading { return .reading }
        if let failure = state.failure {
            let status = GitHubHostStatus(failure: failure, isConnected: true)
            return .status(status ?? GitHubHostStatus(kind: .failed(failure)), readAt: readAt)
        }
        return readAt.map(GitHubSubtitle.read) ?? .reading
    }

    /// gh's words after a failed read, which the "⋯" holds: the line
    /// under the title says only that the read failed. Offline and a rate
    /// limit have no words beyond the line's.
    private static func words(for failure: GitHubReadFailure) -> String? {
        switch failure {
        case .offline, .rateLimited: nil
        case .failed, .timedOut, .notInstalled, .notSignedIn, .unsupported: GitHubBannerText.message(for: failure)
        }
    }
}

/// The one action pinned at the bottom, which the detail scrolls under,
/// with the system's scroll edge effect where there is one.
private struct GitHubSendBar<Bar: View>: ViewModifier {
    let isShown: Bool
    @ViewBuilder let bar: Bar

    func body(content: Content) -> some View {
        if !isShown {
            content
        } else if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom) {
                bar.background(Color(.systemGroupedBackground))
            }
        }
    }
}

// MARK: - Header

private struct GitHubItemHeader: View {
    let item: GitHubItem
    let detail: GitHubItemDetail?
    let viewer: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: GitHubItemRow.symbol(for: item))
                    .foregroundStyle(GitHubItemRow.tint(for: item))
                    .accessibilityLabel(
                        item.kind == .pullRequest
                            ? String(localized: "Pull request", comment: "Read first for a pull request in the GitHub list.")
                            : String(localized: "Issue", comment: "Read first for an issue in the GitHub list."))
                Text(GitHubItemWords.state(of: item))
                    .fontWeight(.semibold)
                    .foregroundStyle(GitHubItemRow.tint(for: item))
                Text(verbatim: "· \(item.repository) #\(item.number)")
                    .foregroundStyle(.secondary)
                    // At accessibility sizes one line holds the owner at most.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text(verbatim: "\(item.repository) #\(item.number)"))
            }
            .font(.subheadline)
            Text(item.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(GitHubItemWords.byline(of: item, detail: detail, viewer: viewer))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Facts

/// The card under the title: Branch, Checks, Review, Changes and Comments
/// for a pull request; Labels, Assignees and Comments for an issue.
private struct GitHubItemFacts: View {
    let item: GitHubItem
    let detail: GitHubItemDetail?
    let viewer: String?
    let isReading: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch item.kind {
        case .pullRequest: pullRequest
        case .issue: issue
        }
    }

    @ViewBuilder
    private var pullRequest: some View {
        let pull = detail?.pullRequest
        LabeledContent("Branch") {
            if let pull {
                // A deleted fork has no owner left to name.
                Text(verbatim: pull.isCrossRepository ? pull.headOwner.map { "\($0):\(pull.headBranch)" } ?? pull.headBranch : pull.headBranch)
                    .font(.body.monospaced())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                pending
            }
        }
        LabeledContent("Checks") { checks }
        LabeledContent("Review") {
            if let pull {
                Text(GitHubItemWords.review(pull.review, viewer: viewer))
            } else if let review = item.review {
                Text(GitHubItemWords.decision(review))
            } else {
                pending
            }
        }
        LabeledContent("Changes") {
            // One Text, so VoiceOver reads the value once and it wraps.
            changes(files: pull?.changedFiles)
                .monospacedDigit()
        }
        comments
    }

    @ViewBuilder
    private var issue: some View {
        LabeledContent("Labels") {
            if item.labels.isEmpty {
                Text("None")
            } else {
                // A value too long to sit beside its label goes under it,
                // where its lines start at the left like the label's.
                Text(verbatim: item.labels.map(\.name).joinedAsPhrases())
                    .lineLimit(2)
            }
        }
        LabeledContent("Assignees") {
            if let detail {
                Text(GitHubItemWords.assignees(detail.assignees, viewer: detail.viewer))
                    .lineLimit(2)
            } else {
                pending
            }
        }
        comments
    }

    private var comments: some View {
        LabeledContent("Comments") {
            Text(item.commentCount, format: .number)
                .monospacedDigit()
        }
    }

    private func changes(files: Int?) -> Text {
        var parts: [Text] = []
        if let files {
            // The catalog's key for a count of files, shared with the Host Helper.
            parts.append(Text("\(files) files"))
        }
        if let additions = item.additions, let deletions = item.deletions {
            parts.append(Text(verbatim: "+\(additions.formatted())").foregroundStyle(GitHubInk.green))
            parts.append(Text(verbatim: "\u{2212}\(deletions.formatted())").foregroundStyle(GitHubInk.red))
        }
        return parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { $0 + Text(verbatim: " ") + $1 }
    }

    /// The glyph, then one Text that VoiceOver reads as a single value
    /// ("3 failing, 12 passed") and that wraps at large sizes.
    private var checks: some View {
        let checks = item.checks ?? GitHubChecks(failing: 0, pending: 0, passing: 0)
        let glyph: (symbol: String, tint: Color)?
        let lead: Text
        let spoken: String
        switch checks.summary {
        case .failing(let count):
            glyph = ("xmark.circle.fill", GitHubInk.red)
            lead = Text("\(count) failing", comment: "How many of a pull request's checks failed, in the GitHub list.")
                .foregroundStyle(GitHubInk.red)
            spoken = String(localized: "\(count) failing", comment: "How many of a pull request's checks failed, in the GitHub list.")
        case .running:
            glyph = ("clock.fill", GitHubInk.amber)
            // Shared with the Background Work bar's count.
            lead = Text("\(checks.pending) running").foregroundStyle(GitHubInk.amber)
            spoken = String(localized: "\(checks.pending) running")
        case .passing:
            glyph = ("checkmark.circle.fill", GitHubInk.green)
            lead = Text("\(checks.passing) passed", comment: "How many of a pull request's checks passed, in its detail.")
            spoken = String(localized: "\(checks.passing) passed", comment: "How many of a pull request's checks passed, in its detail.")
        case .none:
            glyph = nil
            lead = Text("None yet", comment: "A pull request with no checks, in its detail.")
            spoken = String(localized: "None yet", comment: "A pull request with no checks, in its detail.")
        }
        // Passed checks follow failing or running ones.
        let passed: String? =
            switch checks.summary {
            case .failing, .running:
                checks.passing > 0
                    ? String(localized: "\(checks.passing) passed", comment: "How many of a pull request's checks passed, in its detail.")
                    : nil
            case .passing, .none: nil
            }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let glyph {
                Image(systemName: glyph.symbol)
                    .foregroundStyle(glyph.tint)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            (passed.map { lead + Text(verbatim: " · \($0)") } ?? lead)
                .accessibilityLabel([spoken, passed].compactMap(\.self).joined(separator: ", "))
        }
        .monospacedDigit()
    }

    /// A value the detail read has not given yet.
    @ViewBuilder
    private var pending: some View {
        if isReading {
            Text(verbatim: "loading-branch")
                .redacted(reason: .placeholder)
        } else {
            Text(verbatim: "\u{2014}")
                .accessibilityLabel(Text("Unknown"))
        }
    }
}

// MARK: - More

/// The detail's "⋯": the item's address, then what the account can do to
/// it once a detail read says what it is. Close asks first, then runs; a
/// write running on the item turns the button into a spinner.
private struct GitHubItemMenu: View {
    let store: GitHubStore
    let host: GitHubHost
    /// The item the detail opened on, which keys its reads.
    let item: GitHubItem
    /// As the detail shows it now.
    let current: GitHubItem
    let detail: GitHubItemDetail?
    /// gh's words after the detail's read failed, on iOS 26, where nothing
    /// else on screen shows them.
    let readFailure: String?
    let write: GitHubWriteLink

    @State private var isConfirmingClose = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let actions = detail.map(GitHubWrite.actions(for:)) ?? []
        let canWrite = store.isConnected(host)
        Group {
            if store.isWriting(item, on: host) {
                ProgressView()
                    .accessibilityLabel(Text("Working on GitHub"))
            } else {
                Menu {
                    if let url = URL(string: current.url) {
                        Section {
                            Button("Open in Browser", systemImage: "safari") { openURL(url) }
                            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
                        }
                    }
                    if !actions.isEmpty {
                        Section {
                            if actions.contains(.comment) {
                                Button("Comment…", systemImage: "text.bubble") {
                                    write.present(GitHubWriteSheetRequest(host: host, item: item, kind: .compose(.comment)))
                                }
                            }
                            if actions.contains(.approve) {
                                Button("Approve…", systemImage: "checkmark.circle") {
                                    write.present(GitHubWriteSheetRequest(host: host, item: item, kind: .compose(.approve)))
                                }
                            }
                            if actions.contains(.merge) {
                                Button("Merge…", systemImage: "arrow.triangle.merge") {
                                    let request = GitHubWriteSheetRequest(host: host, item: item, kind: .merge)
                                    request.state.deletesBranch = store.settings.mergeDeletesBranch
                                    write.present(request)
                                }
                            }
                            if actions.contains(.close) {
                                Button("Close…", systemImage: "xmark.circle", role: .destructive) {
                                    isConfirmingClose = true
                                }
                            }
                        }
                        .disabled(!canWrite)
                    }
                    // As the list's Host menu shows a failed read: a
                    // section's title, which wraps, over Check Again.
                    if let readFailure {
                        Section(readFailure) {
                            Button("Check Again", systemImage: "arrow.clockwise") {
                                Task { await store.reread(item, on: host) }
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog(
            current.kind == .pullRequest ? Text("Close This Pull Request?") : Text("Close This Issue?"),
            isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            switch current.kind {
            case .pullRequest:
                Button("Close Pull Request", role: .destructive) { close(nil) }
            case .issue:
                Button("Close as Completed", role: .destructive) { close(.completed) }
                Button("Close as Not Planned", role: .destructive) { close(.notPlanned) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(GitHubWriteWords.runsAs(.close, kind: current.kind, host: host, login: detail?.viewer))
        }
    }

    /// The detail shows the item closed when it is; anything else is a page
    /// the tab shows, wherever in it the user is by then.
    private func close(_ reason: GitHubCloseReason?) {
        Task { await store.write(.close(reason), on: item, host: host, shownBy: nil) }
    }
}

// MARK: - Words

/// How the detail says an item's state, byline and people.
enum GitHubItemWords {
    static func state(of item: GitHubItem) -> String {
        switch item.state {
        case .open: String(localized: "GitHub state Open", defaultValue: "Open")
        case .draft: String(localized: "Draft")
        case .merged: String(localized: "Merged")
        case .closed: String(localized: "GitHub state Closed", defaultValue: "Closed")
        }
    }

    /// "You want to merge into main · updated 3h ago".
    static func byline(of item: GitHubItem, detail: GitHubItemDetail?, viewer: String?, now: Date = Date()) -> String {
        let age = GitHubItemRow.age(of: item.updatedAt, now: now)
        let author = item.author ?? String(localized: "A deleted account")
        let isViewers = detail?.isViewers ?? (viewer != nil && item.author == viewer)
        switch item.kind {
        case .issue:
            return isViewers
                ? String(localized: "Opened by you · updated \(age) ago")
                : String(localized: "Opened by \(author) · updated \(age) ago")
        case .pullRequest:
            guard let base = detail?.pullRequest?.baseBranch, !base.isEmpty else {
                return String(localized: "Updated \(age) ago")
            }
            switch item.state {
            case .merged:
                return String(localized: "Merged into \(base) · updated \(age) ago")
            case .closed:
                return String(localized: "Closed without merging · updated \(age) ago")
            case .open, .draft:
                return isViewers
                    ? String(localized: "You want to merge into \(base) · updated \(age) ago")
                    : String(localized: "\(author) wants to merge into \(base) · updated \(age) ago")
            }
        }
    }

    static func review(_ review: GitHubReviewState, viewer: String?) -> String {
        switch review {
        case .requestedOfViewer:
            String(localized: "Your review was requested")
        case .changesRequested(let by):
            String(localized: "Changes requested by \(people(by, viewer: viewer))")
        case .approved(let by):
            String(localized: "Approved by \(people(by, viewer: viewer))")
        case .requested(let of):
            String(localized: "Requested from \(people(of, viewer: viewer))")
        case .notRequested:
            String(localized: "Not requested yet")
        }
    }

    /// The list's word for a review, before the detail says who.
    static func decision(_ decision: GitHubReviewDecision) -> String {
        switch decision {
        case .approved: String(localized: "Approved")
        case .changesRequested: String(localized: "Changes requested")
        case .reviewRequired: String(localized: "Review required")
        }
    }

    /// "You, sam-okafor", or None.
    static func assignees(_ logins: [String], viewer: String) -> String {
        guard !logins.isEmpty else {
            return String(localized: "None")
        }
        // The account first, as "You".
        let ordered = logins.filter { $0 == viewer } + logins.filter { $0 != viewer }
        return people(ordered, viewer: viewer)
    }

    private static func people(_ logins: [String], viewer: String?) -> String {
        logins.map { $0 == viewer ? String(localized: "You", comment: "The signed-in GitHub account, among people.") : $0 }
            .formatted(.list(type: .and))
    }
}
