import SwiftUI

/// A sheet the detail's "⋯" opens: Comment, Approve or Merge, or what a
/// Close came to when there is something to read.
struct GitHubWriteSheetRequest: Identifiable {
    enum Kind {
        /// Comment or Approve.
        case compose(GitHubWrite.Action)
        case merge
        /// A Close that did not plainly close the item.
        case closeResult(GitHubWriteResult)
    }

    let id = UUID()
    let kind: Kind
}

/// Where a sheet's write stands.
private enum GitHubWritePhase: Equatable {
    /// The form, with why the last try ran nothing.
    case editing(notRun: String?)
    case working
    /// What gh did, as the read after it shows.
    case done(GitHubWriteResult)

    var isWorking: Bool { self == .working }
}

/// Presents the detail's write sheets with the Console's sheet sizing.
struct GitHubWriteSheet: View {
    let request: GitHubWriteSheetRequest
    let store: GitHubStore
    let host: GitHubHost
    let item: GitHubItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch request.kind {
        case .compose(let action):
            GitHubComposeSheet(store: store, host: host, item: item, action: action)
                .presentationDetents([.medium, .large])
        case .merge:
            let detail = store.detailState(of: item, on: host).detail
            let warns = GitHubWriteWords.mergeWarning(item: detail?.item ?? item, pull: detail?.pullRequest) != nil
            // A warning pushes the button below a partial sheet.
            GitHubMergeSheet(store: store, host: host, item: item)
                .presentationDetents(warns ? [.large] : [.fraction(0.7), .large])
        case .closeResult(let result):
            NavigationStack {
                GitHubWriteResultView(host: host, result: result, typed: nil) { dismiss() }
                    .navigationTitle(GitHubWriteWords.sheetTitle(.close))
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Comment and Approve

/// Comment on any item, or approve a pull request with optional words.
private struct GitHubComposeSheet: View {
    let store: GitHubStore
    let host: GitHubHost
    let item: GitHubItem
    /// `.comment` or `.approve`.
    let action: GitHubWrite.Action

    @State private var text = ""
    @State private var phase = GitHubWritePhase.editing(notRun: nil)
    @FocusState private var isEditing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let detail = store.detailState(of: item, on: host).detail
        let current = detail?.item ?? item
        NavigationStack {
            Group {
                if case .done(let result) = phase {
                    GitHubWriteResultView(host: host, result: result, typed: text) { dismiss() }
                } else {
                    form(current, login: detail?.viewer)
                }
            }
            .navigationTitle(GitHubWriteWords.sheetTitle(action))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A result page ends with its own Done.
                    if case .done = phase {
                        EmptyView()
                    } else {
                        Button("Cancel") { dismiss() }
                            .disabled(phase.isWorking)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase.isWorking {
                        ProgressView()
                    } else if case .editing = phase {
                        Button(action == .comment ? String(localized: "Post") : String(localized: "Approve")) {
                            submit()
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase.isWorking)
    }

    private var canSubmit: Bool {
        action == .approve || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func form(_ current: GitHubItem, login: String?) -> some View {
        List {
            if case .editing(let reason?) = phase {
                GitHubNotRunSection(action: action, reason: reason)
            }
            Section {
                TextEditor(text: $text)
                    .focused($isEditing)
                    .frame(minHeight: 140)
                    .disabled(phase.isWorking)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            (action == .comment ? Text("Leave a comment") : Text("Leave a comment (optional)"))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(Text("Comment"))
            } header: {
                GitHubWriteItemLine(item: current)
            } footer: {
                Text(GitHubWriteWords.runsAs(action, kind: current.kind, host: host, login: login))
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { isEditing = true }
    }

    /// One tap, one write: the phase turns before anything awaits, so a
    /// second tap finds the form working.
    private func submit() {
        guard case .editing = phase, canSubmit else { return }
        let write: GitHubWrite = action == .comment ? .comment(text) : .approve(text)
        phase = .working
        Task {
            guard let result = await store.write(write, on: item, host: host) else {
                phase = .editing(notRun: GitHubWriteWords.busy)
                return
            }
            switch result.outcome {
            case .notRun(let reason):
                phase = .editing(notRun: reason)
            case .finished(exitStatus: 0, _):
                dismiss()
            case .finished, .unknown:
                phase = .done(result)
            }
        }
    }
}

// MARK: - Merge

/// Merge a pull request: the method, the branch, and the one button that
/// carries the method's name.
private struct GitHubMergeSheet: View {
    let store: GitHubStore
    let host: GitHubHost
    let item: GitHubItem

    @State private var chosenMethod: GitHubMergeMethod?
    @State private var deletesBranch = true
    @State private var phase = GitHubWritePhase.editing(notRun: nil)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let detail = store.detailState(of: item, on: host).detail
        NavigationStack {
            Group {
                if case .done(let result) = phase {
                    GitHubWriteResultView(host: host, result: result, typed: nil) { dismiss() }
                } else {
                    form(detail)
                }
            }
            .navigationTitle(GitHubWriteWords.sheetTitle(.merge))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A result page ends with its own Done.
                    if case .done = phase {
                        EmptyView()
                    } else {
                        Button("Cancel") { dismiss() }
                            .disabled(phase.isWorking)
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase.isWorking)
    }

    private func method(in settings: GitHubMergeSettings?) -> GitHubMergeMethod? {
        chosenMethod.flatMap { settings?.allowed.contains($0) == true ? $0 : nil } ?? settings?.initial
    }

    @ViewBuilder
    private func form(_ detail: GitHubItemDetail?) -> some View {
        let current = detail?.item ?? item
        let pull = detail?.pullRequest
        let settings = pull?.mergeSettings
        let method = method(in: settings)
        let warning = GitHubWriteWords.mergeWarning(item: current, pull: pull)
        List {
            if case .editing(let reason?) = phase {
                GitHubNotRunSection(action: .merge, reason: reason)
            }
            if let warning {
                Section {
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GitHubInk.amber)
                    }
                } header: {
                    GitHubWriteItemLine(item: current)
                }
            }
            Section {
                if let settings, !settings.allowed.isEmpty {
                    ForEach(settings.allowed) { candidate in
                        methodRow(candidate, isSelected: candidate == method)
                    }
                } else {
                    Text("GitHub did not say how this repository merges.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                VStack(alignment: .leading, spacing: 14) {
                    if warning == nil { GitHubWriteItemLine(item: current) }
                    Text("Method")
                }
            }
            if let pull, !pull.isCrossRepository {
                Section {
                    if pull.mergeSettings.deletesBranch {
                        Toggle("Delete Branch", isOn: .constant(true))
                            .disabled(true)
                    } else {
                        Toggle("Delete Branch", isOn: $deletesBranch)
                            .disabled(phase.isWorking)
                    }
                } footer: {
                    if pull.mergeSettings.deletesBranch {
                        Text("This repository deletes a pull request's branch once it is merged.")
                    }
                }
            }
            Section {
                Button {
                    merge(method, pull: pull)
                } label: {
                    Text(phase.isWorking ? String(localized: "Merging…") : (method?.title ?? String(localized: "Merge")))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(phase.isWorking || method == nil || pull?.headCommit == nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(GitHubWriteWords.runsAs(.merge, kind: .pullRequest, host: host, login: detail?.viewer))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private func methodRow(_ candidate: GitHubMergeMethod, isSelected: Bool) -> some View {
        Button {
            chosenMethod = candidate
        } label: {
            HStack {
                Text(candidate.title)
                    .foregroundStyle(Color(uiColor: .label))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .disabled(phase.isWorking)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Merges the head the sheet showed, so a commit pushed since is not
    /// merged unseen.
    private func merge(_ method: GitHubMergeMethod?, pull: GitHubPullRequestDetail?) {
        guard case .editing = phase, let method, let pull, let headCommit = pull.headCommit else { return }
        let deleteBranch = !pull.isCrossRepository && !pull.mergeSettings.deletesBranch && deletesBranch
        phase = .working
        Task {
            guard
                let result = await store.write(
                    .merge(method, deleteBranch: deleteBranch, headCommit: headCommit), on: item, host: host)
            else {
                phase = .editing(notRun: GitHubWriteWords.busy)
                return
            }
            if case .notRun(let reason) = result.outcome {
                phase = .editing(notRun: reason)
            } else {
                phase = .done(result)
            }
        }
    }
}

// MARK: - Pieces

/// The item a sheet acts on, above its form.
private struct GitHubWriteItemLine: View {
    let item: GitHubItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: GitHubItemRow.symbol(for: item))
                .foregroundStyle(GitHubItemRow.tint(for: item))
            // One Text, like Send to Agent's: side by side, the title kept
            // one line and lost most of itself. The header is secondary
            // already; `.secondary` again dimmed the repository to 1.8:1.
            (Text(verbatim: "\(item.repositoryName) #\(item.number)  ")
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                + Text(item.title).foregroundStyle(Color(uiColor: .label)))
                .lineLimit(dynamicTypeSize >= .xxxLarge ? 4 : 2)
        }
        .font(.subheadline)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// Why a write ran nothing, above the form that can try again.
private struct GitHubNotRunSection: View {
    let action: GitHubWrite.Action
    let reason: String

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(GitHubWriteWords.notRunTitle(action))
                        .fontWeight(.semibold)
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GitHubInk.red)
            }
        }
    }
}

/// What a write came to: merged, refused with gh's words, finished
/// without the change showing yet, or unknown.
struct GitHubWriteResultView: View {
    let host: GitHubHost
    let result: GitHubWriteResult
    /// What the user wrote, kept in sight when it may not have been posted.
    let typed: String?
    let done: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let page = GitHubWriteWords.page(for: result)
        ScrollView {
            VStack(alignment: page.style == .merged ? .center : .leading, spacing: 12) {
                header(page)
                if let printed = page.printed {
                    Text(verbatim: printed)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(.background, in: .rect(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: .separator)))
                        .accessibilityLabel(Text("What gh printed"))
                        .accessibilityValue(Text(verbatim: printed))
                }
                if let caption = page.caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(page.style == .merged ? .center : .leading)
                        .padding(.horizontal, 4)
                }
                // Kept on screen so a refused or lost comment can be copied.
                if page.style == .unknown || page.style == .refused, let typed, !typed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What you wrote")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: typed)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                    }
                }
                VStack(spacing: 10) {
                    if page.style == .unknown, let detail = result.detail, let url = URL(string: detail.item.url) {
                        Button {
                            openURL(url)
                        } label: {
                            Text("Open in Browser")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    if page.style == .merged {
                        Button(action: done) {
                            Text("Done").fontWeight(.semibold).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button(action: done) {
                            Text("Done").fontWeight(.semibold).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: ReadableColumn.width)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private func header(_ page: GitHubWriteWords.Page) -> some View {
        if page.style == .merged {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(GitHubInk.purple)
                .accessibilityHidden(true)
            Text(page.title)
                .font(.title2.bold())
            if let summary = page.summary {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            Label {
                Text(page.title)
                    .font(.title3.bold())
            } icon: {
                Image(systemName: page.style.symbol)
                    .foregroundStyle(page.style.tint)
                    .font(.title3)
            }
            if let summary = page.summary {
                Text(summary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Words

/// How the write sheets and their results say things.
enum GitHubWriteWords {
    static var busy: String {
        String(localized: "Another change to this item is still running.")
    }

    static func sheetTitle(_ action: GitHubWrite.Action) -> String {
        switch action {
        case .comment: String(localized: "GitHub sheet Comment", defaultValue: "Comment")
        case .approve: String(localized: "GitHub sheet Approve", defaultValue: "Approve")
        case .merge: String(localized: "GitHub sheet Merge", defaultValue: "Merge")
        case .close: String(localized: "GitHub sheet Close", defaultValue: "Close")
        }
    }

    static func notRunTitle(_ action: GitHubWrite.Action) -> String {
        switch action {
        case .comment: String(localized: "Not Posted")
        case .approve: String(localized: "Not Approved")
        case .merge: String(localized: "Not Merged")
        case .close: String(localized: "Not Closed")
        }
    }

    /// Whose name the write goes out under, and where it runs: "Runs gh pr
    /// merge on Studio Mac as @riley-dev."
    static func runsAs(_ action: GitHubWrite.Action, kind: GitHubItem.Kind, host: GitHubHost, login: String?) -> String {
        let command = GitHubWrite.command(action, for: kind)
        guard let login else { return String(localized: "Runs \(command) on \(host.name).") }
        return String(localized: "Runs \(command) on \(host.name) as @\(login).")
    }

    /// Failing checks and a request for changes, either or both.
    static func mergeWarning(item: GitHubItem, pull: GitHubPullRequestDetail?) -> String? {
        let failing = item.checks?.failing ?? 0
        var changesRequested = item.review == .changesRequested
        if case .changesRequested = pull?.review { changesRequested = true }
        switch (failing > 0, changesRequested) {
        case (true, true):
            return String(localized: "\(failing) checks are failing and changes were requested. GitHub may refuse this merge.")
        case (true, false):
            return String(localized: "\(failing) checks are failing. GitHub may refuse this merge.")
        case (false, true):
            return String(localized: "Changes were requested. GitHub may refuse this merge.")
        case (false, false):
            return nil
        }
    }

    /// A result page's words.
    struct Page: Equatable {
        enum Style: Equatable {
            case merged
            /// gh exited with an error.
            case refused
            /// gh exited without one, and the read does not show the change.
            case pending
            case unknown
            /// Nothing ran.
            case notRun

            var symbol: String {
                switch self {
                case .merged: "arrow.triangle.merge"
                case .refused: "xmark.circle"
                case .pending: "clock"
                case .unknown: "questionmark.circle"
                case .notRun: "exclamationmark.triangle"
                }
            }

            /// The list's state colours: the system's yellow and orange
            /// fall under 3:1 on a white sheet.
            var tint: Color {
                switch self {
                case .merged: GitHubInk.purple
                case .refused, .notRun: GitHubInk.red
                case .pending: .secondary
                case .unknown: GitHubInk.amber
                }
            }
        }

        let style: Style
        let title: String
        /// Under the title.
        var summary: String?
        /// gh's words, as it printed them.
        var printed: String?
        /// Under gh's words.
        var caption: String?
    }

    /// Claims only what gh's status and the read after it show.
    static func page(for result: GitHubWriteResult) -> Page {
        let action = result.write.action
        let isPullRequest = result.item.kind == .pullRequest
        let isOpen = result.detail.map { $0.item.state == .open || $0.item.state == .draft }
        if action == .merge, let detail = result.detail, detail.item.state == .merged {
            var page = Page(style: .merged, title: String(localized: "Merged"), summary: mergedSummary(result, detail))
            if case .finished(let status, let printed) = result.outcome, status != 0 {
                page.printed = printed.isEmpty ? nil : printed
                page.caption = String(localized: "gh stopped with an error after the merge. This is what it printed.")
            }
            return page
        }
        let stillOpen: String? =
            switch (action, isOpen) {
            case (.merge, true): String(localized: "GitHub still shows the pull request open.")
            case (.close, true):
                isPullRequest
                    ? String(localized: "GitHub still shows the pull request open.")
                    : String(localized: "GitHub still shows the issue open.")
            default: nil
            }
        let readFailed = result.readFailure.map {
            String(localized: "Heeler could not read it again afterward. \(GitHubBannerText.message(for: $0))")
        }
        switch result.outcome {
        case .notRun(let reason):
            return Page(style: .notRun, title: notRunTitle(action), summary: reason)
        case .finished(let status, let printed):
            let shown = printed.isEmpty ? nil : printed
            let said =
                shown == nil
                ? String(localized: "gh printed nothing. It stopped with status \(Int(status)).")
                : String(localized: "This is what gh printed.")
            if status == 0 {
                return Page(
                    style: .pending,
                    title: action == .merge ? String(localized: "Not Merged Yet") : String(localized: "Not Closed Yet"),
                    printed: shown,
                    caption: [String(localized: "gh finished without an error."), stillOpen ?? readFailed, said]
                        .compactMap { $0 }.joinedAsSentences())
            }
            return Page(
                style: .refused, title: refusedTitle(action, isPullRequest: isPullRequest), printed: shown,
                caption: [said, stillOpen ?? readFailed].compactMap { $0 }.joinedAsSentences())
        case .unknown(let reason):
            let check =
                switch action {
                case .comment, .approve:
                    String(localized: "Check the conversation on GitHub before you try again.")
                case .merge, .close:
                    String(localized: "Check it on GitHub before you try again.")
                }
            return Page(
                style: .unknown, title: String(localized: "Outcome Unknown"),
                summary: [
                    reason, String(localized: "It may have gone through. Heeler did not send it again."),
                    stillOpen ?? readFailed, check,
                ].compactMap { $0 }.joinedAsSentences())
        }
    }

    private static func refusedTitle(_ action: GitHubWrite.Action, isPullRequest: Bool) -> String {
        switch action {
        case .comment: String(localized: "GitHub Refused the Comment")
        case .approve: String(localized: "GitHub Refused the Approval")
        case .merge: String(localized: "GitHub Refused the Merge")
        case .close:
            isPullRequest
                ? String(localized: "GitHub Refused to Close the Pull Request")
                : String(localized: "GitHub Refused to Close the Issue")
        }
    }

    /// "acme/storefront #214 was squashed into main. The branch
    /// edge-cache-grid was deleted." The method is named only when gh
    /// merged it without an error, the account shows as the merger and the
    /// merge commit's parents agree; the branch, as the read finds it.
    private static func mergedSummary(_ result: GitHubWriteResult, _ detail: GitHubItemDetail) -> String {
        let item = detail.item
        let name = "\(item.repository) #\(item.number)"
        guard let pull = detail.pullRequest else {
            return String(localized: "\(name) was merged.")
        }
        var method: GitHubMergeMethod?
        var askedToDelete = false
        if case .merge(let chosen, let deleteBranch, _) = result.write {
            askedToDelete = deleteBranch
            if case .finished(exitStatus: 0, _) = result.outcome, pull.mergedBy == detail.viewer,
                let parents = pull.mergeCommitParents, (parents == 2) == (chosen == .merge)
            {
                method = chosen
            }
        }
        let base = pull.baseBranch
        let merged =
            switch method {
            case .squash: String(localized: "\(name) was squashed into \(base).")
            case .rebase: String(localized: "\(name) was rebased onto \(base).")
            case .merge, nil: String(localized: "\(name) was merged into \(base).")
            }
        var sentences = [merged]
        if !pull.isCrossRepository, !pull.headBranch.isEmpty {
            if !pull.headBranchExists {
                sentences.append(String(localized: "The branch \(pull.headBranch) was deleted."))
            } else if askedToDelete {
                sentences.append(String(localized: "The branch \(pull.headBranch) is still on GitHub."))
            }
        }
        return sentences.joinedAsSentences()
    }
}
