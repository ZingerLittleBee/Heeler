import SwiftUI
import UIKit

/// Where the GitHub tab presents Send to Agent, which the Console owns.
struct GitHubSendLink {
    let present: @MainActor (GitHubSendRequest) -> Void
}

/// A pull request or an issue: how it stands, what it says, Send to Agent,
/// and Comment, Approve, Merge and Close from its "⋯" (ADR 0064). Its list
/// row shows at once; the rest comes from a read of the one item, again on
/// a pull and around every write.
struct GitHubItemScreen: View {
    let store: GitHubStore
    let host: GitHubHost
    /// The item as the list showed it when the detail opened.
    let item: GitHubItem
    let send: GitHubSendLink?

    @State private var writeSheet: GitHubWriteSheetRequest?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let state = store.detailState(of: item, on: host)
        let detail = state.detail
        let current = detail?.item ?? store.listItem(item.id, on: host) ?? item
        let viewer = detail?.viewer ?? store.state(of: host).list?.login
        let isOffline = !store.isConnected(host) || state.failure == .offline
        List {
            Section {
                GitHubItemHeader(item: current, detail: detail, viewer: viewer)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            if let banner = GitHubBannerText(
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
                    GitHubItemBody(text: detail.body)
                }
            } else if state.isReading {
                Section {
                    GitHubItemBody.placeholder
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 8, for: .scrollContent)
        .readableColumnPage()
        .navigationTitle(Text(verbatim: "#\(current.number)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GitHubItemMenu(
                    store: store, host: host, item: item, current: current, detail: detail,
                    sheet: $writeSheet)
            }
        }
        .sheet(item: $writeSheet) { request in
            GitHubWriteSheet(request: request, store: store, host: host, item: item)
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
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
    }

    private struct DetailTrigger: Equatable {
        let host: Host.ID
        let item: GitHubItem.ID
        let isConnected: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: GitHubItemRow.symbol(for: item))
                    .foregroundStyle(GitHubItemRow.tint(for: item))
                Text(GitHubItemWords.state(of: item))
                    .fontWeight(.semibold)
                    .foregroundStyle(GitHubItemRow.tint(for: item))
                Text(verbatim: "· \(item.repository) #\(item.number)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                Text(verbatim: pull.isCrossRepository ? "\(pull.headOwner ?? ""):\(pull.headBranch)" : pull.headBranch)
                    .font(.body.monospaced())
                    .lineLimit(1)
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
            HStack(spacing: 6) {
                if let pull {
                    // The catalog's key for a count of files, shared with the Host Helper.
                    Text("\(pull.changedFiles) files")
                }
                if let additions = item.additions, let deletions = item.deletions {
                    Text(verbatim: "+\(additions.formatted())").foregroundStyle(.green)
                    Text(verbatim: "\u{2212}\(deletions.formatted())").foregroundStyle(.red)
                }
            }
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
                Text(verbatim: item.labels.map(\.name).joinedAsPhrases())
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        LabeledContent("Assignees") {
            if let detail {
                Text(GitHubItemWords.assignees(detail.assignees, viewer: detail.viewer))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
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

    @ViewBuilder
    private var checks: some View {
        let checks = item.checks ?? GitHubChecks(failing: 0, pending: 0, passing: 0)
        HStack(spacing: 4) {
            switch checks.summary {
            case .failing(let count):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).imageScale(.small)
                Text("\(count) failing", comment: "How many of a pull request's checks failed, in the GitHub list.")
                    .foregroundStyle(.red)
                passed(checks.passing)
            case .running:
                Image(systemName: "clock.fill").foregroundStyle(.yellow).imageScale(.small)
                // Shared with the Background Work bar's count.
                Text("\(checks.pending) running")
                    .foregroundStyle(.yellow)
                passed(checks.passing)
            case .passing:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
                Text("\(checks.passing) passed", comment: "How many of a pull request's checks passed, in its detail.")
            case .none:
                Text("None yet", comment: "A pull request with no checks, in its detail.")
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func passed(_ count: Int) -> some View {
        if count > 0 {
            Text(verbatim: "·")
            Text("\(count) passed", comment: "How many of a pull request's checks passed, in its detail.")
        }
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

// MARK: - Body

/// What the author wrote, laid out as Chat lays out Markdown.
private struct GitHubItemBody: View {
    let text: String

    var body: some View {
        let markdown = Self.markdown(text)
        Group {
            if markdown.isEmpty {
                Text("No description provided.")
                    .foregroundStyle(.secondary)
            } else {
                ChatMarkdownView(blocks: ChatMarkdown.blocks(from: markdown))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }

    /// GitHub keeps the line ends a browser sent, and hides HTML comments
    /// (a template's instructions) when it renders.
    static func markdown(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var placeholder: some View {
        Text(verbatim: "A description that is still being read from GitHub, a few lines long.")
            .redacted(reason: .placeholder)
            .padding(.vertical, 6)
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
    @Binding var sheet: GitHubWriteSheetRequest?

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
                                    sheet = GitHubWriteSheetRequest(kind: .compose(.comment))
                                }
                            }
                            if actions.contains(.approve) {
                                Button("Approve…", systemImage: "checkmark.circle") {
                                    sheet = GitHubWriteSheetRequest(kind: .compose(.approve))
                                }
                            }
                            if actions.contains(.merge) {
                                Button("Merge…", systemImage: "arrow.triangle.merge") {
                                    sheet = GitHubWriteSheetRequest(kind: .merge)
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

    /// The detail shows the item closed when it is; anything else opens a
    /// page that says what happened.
    private func close(_ reason: GitHubCloseReason?) {
        Task {
            guard let result = await store.write(.close(reason), on: item, host: host) else { return }
            let isClosed = result.detail.map { $0.item.state == .closed || $0.item.state == .merged } ?? false
            switch result.outcome {
            case .finished(exitStatus: 0, _) where isClosed, .unknown where isClosed:
                return
            default:
                sheet = GitHubWriteSheetRequest(kind: .closeResult(result))
            }
        }
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
