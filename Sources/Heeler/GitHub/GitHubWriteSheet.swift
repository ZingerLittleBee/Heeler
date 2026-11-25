import SwiftUI

/// A sheet the detail's "⋯" opens, Comment, Approve or Merge, or a write's
/// result for the tab to show: a Close's that did not plainly close the
/// item, or one whose sheet had gone.
struct GitHubWriteSheetRequest: Identifiable {
    enum Kind {
        /// Comment or Approve.
        case compose(GitHubWrite.Action)
        case merge
        case result(GitHubWriteResult)
    }

    let id = UUID()
    let host: GitHubHost
    /// The item as the detail showed it, which keys its reads.
    let item: GitHubItem
    let kind: Kind
    /// The sheet's state, kept with the request above the tab rather than
    /// in the sheet's views: the draft, the choices and a write in flight.
    let state = GitHubWriteSheetState()
}

/// What a write sheet holds while it is open.
@Observable
final class GitHubWriteSheetState {
    /// What the user has typed in a Comment or Approve sheet.
    var text = ""
    var chosenMethod: GitHubMergeMethod?
    /// Merge's Delete Branch, which starts as the user last left it
    /// (`GitHubSettings.mergeDeletesBranch`).
    var deletesBranch = true
    fileprivate var phase = GitHubWritePhase.editing(notRun: nil)
}

/// Where the detail opens its write sheets: above the detail, where Send to
/// Agent's request lives, so a sheet and its draft outlive a layout change.
struct GitHubWriteLink {
    let present: @MainActor (GitHubWriteSheetRequest) -> Void
}

/// Where a sheet's write stands.
private enum GitHubWritePhase: Equatable {
    /// The form, with why the last try ran nothing.
    case editing(notRun: String?)
    case working
    /// What gh did, as the read after it shows.
    case done(GitHubWriteResult)

    var isWorking: Bool { self == .working }

    var isDone: Bool {
        if case .done = self { true } else { false }
    }
}

/// One write sheet, by its request. `close` ends that request, and no
/// other one shown since.
struct GitHubWriteSheet: View {
    let request: GitHubWriteSheetRequest
    let store: GitHubStore
    let close: () -> Void

    var body: some View {
        switch request.kind {
        case .compose(let action):
            GitHubComposeSheet(
                store: store, host: request.host, item: request.item, action: action, presence: request.id,
                state: request.state, close: close)
        case .merge:
            GitHubMergeSheet(
                store: store, host: request.host, item: request.item, presence: request.id, state: request.state,
                close: close)
        case .result(let result):
            NavigationStack {
                GitHubWriteResultView(
                    host: request.host, result: result, typed: result.write.typed, namesHost: true, done: close)
                    .navigationTitle(GitHubWriteWords.sheetTitle(result.write.action))
                    .navigationBarTitleDisplayMode(.inline)
            }
            // A result page at full height, its Done in sight.
            .presentationDetents([.large])
        }
    }
}

/// Presents the GitHub tab's write sheets from above the tab, as Send to
/// Agent is, and then, once each, the results that came after their screen
/// had gone (ADR 0065).
struct GitHubWriteSheetPresenter: ViewModifier {
    @Binding var request: GitHubWriteSheetRequest?
    let store: GitHubStore
    /// The GitHub tab is the one shown and none of the Console's sheets is
    /// up. A waiting result shows only then: a sheet such as Send to Agent
    /// can end by opening another tab, and the result would land over it.
    let mayShowResult: () -> Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content
            .onAppear(perform: showNext)
            .onChange(of: mayShowResult()) { showNext() }
            .onChange(of: store.reports) { showNext() }
            .sheet(item: $request, onDismiss: showNext) { shown in
                // The presentation it opened with: following a size class
                // that changes under it would build the sheet again.
                ConsoleSheetContent(ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)) {
                    presentation in
                    GitHubWriteSheet(request: shown, store: store) {
                        // A write that ends after its sheet gave way to
                        // another leaves that one open.
                        if request?.id == shown.id { request = nil }
                    }
                    .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
                }
            }
    }

    /// Shows the oldest waiting result once the update that asked is over.
    /// Send to Agent closes in the same update in which it opens an Agent,
    /// and the Console leaves the GitHub tab only in that update's
    /// `onChange`s, which may come after this one's.
    private func showNext() {
        Task { @MainActor in
            guard mayShowResult(), request == nil, let report = store.takeReport() else { return }
            request = GitHubWriteSheetRequest(
                host: report.host, item: report.result.item, kind: .result(report.result))
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
    /// The request's: shows the result while the sheet is open.
    let presence: UUID
    @Bindable var state: GitHubWriteSheetState
    let close: () -> Void

    @FocusState private var isEditing: Bool

    var body: some View {
        let detail = store.detailState(of: item, on: host).detail
        let current = detail?.item ?? item
        NavigationStack {
            Group {
                if case .done(let result) = state.phase {
                    GitHubWriteResultView(host: host, result: result, typed: state.text) { close() }
                } else {
                    form(current, login: detail?.viewer)
                }
            }
            .navigationTitle(GitHubWriteWords.sheetTitle(action))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A result page ends with its own Done.
                    if case .done = state.phase {
                        EmptyView()
                    } else {
                        Button("Cancel") { close() }
                            .disabled(state.phase.isWorking)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if state.phase.isWorking {
                        ProgressView()
                    } else if case .editing = state.phase {
                        Button(action == .comment ? String(localized: "Post") : String(localized: "Approve")) {
                            submit()
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        // The result page at full height: without the keyboard a partial
        // sheet would put its Done below the fold.
        .presentationDetents(state.phase.isDone ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(state.phase.isWorking)
        .onAppear { store.present(presence) }
        .onDisappear { store.leave(presence) }
    }

    private var canSubmit: Bool {
        action == .approve || !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func form(_ current: GitHubItem, login: String?) -> some View {
        List {
            if case .editing(let reason?) = state.phase {
                GitHubNotRunSection(action: action, reason: reason)
            }
            Section {
                TextEditor(text: $state.text)
                    .focused($isEditing)
                    .frame(minHeight: 140)
                    .disabled(state.phase.isWorking)
                    .overlay(alignment: .topLeading) {
                        if state.text.isEmpty {
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
        guard case .editing = state.phase, canSubmit else { return }
        let write: GitHubWrite = action == .comment ? .comment(state.text) : .approve(state.text)
        state.phase = .working
        Task {
            let result: GitHubWriteResult
            switch await store.write(write, on: item, host: host, shownBy: presence) {
            case .ranNothing:
                state.phase = .editing(notRun: GitHubWriteWords.busy)
                return
            case .screenGone:
                // It may have posted: the form never comes back for a second tap.
                close()
                return
            case .result(let shown):
                result = shown
            }
            switch result.outcome {
            case .notRun(let reason):
                state.phase = .editing(notRun: reason)
            case .finished(exitStatus: 0, _):
                close()
            case .finished, .unknown:
                state.phase = .done(result)
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

    /// The request's: shows the result while the sheet is open.
    let presence: UUID
    @Bindable var state: GitHubWriteSheetState
    let close: () -> Void

    var body: some View {
        let detail = store.detailState(of: item, on: host).detail
        NavigationStack {
            Group {
                if case .done(let result) = state.phase {
                    GitHubWriteResultView(host: host, result: result, typed: nil) { close() }
                } else {
                    form(detail)
                }
            }
            .navigationTitle(GitHubWriteWords.sheetTitle(.merge))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A result page ends with its own Done.
                    if case .done = state.phase {
                        EmptyView()
                    } else {
                        Button("Cancel") { close() }
                            .disabled(state.phase.isWorking)
                    }
                }
            }
        }
        // Full height: seven tenths of a 6.3-inch iPhone held the form at
        // the default text size with no room to spare, and of an SE cut
        // the button off below Delete Branch.
        .presentationDetents([.large])
        .interactiveDismissDisabled(state.phase.isWorking)
        .onAppear { store.present(presence) }
        .onDisappear { store.leave(presence) }
    }

    private func method(in settings: GitHubMergeSettings?) -> GitHubMergeMethod? {
        state.chosenMethod.flatMap { settings?.allowed.contains($0) == true ? $0 : nil } ?? settings?.initial
    }

    @ViewBuilder
    private func form(_ detail: GitHubItemDetail?) -> some View {
        let current = detail?.item ?? item
        let pull = detail?.pullRequest
        let settings = pull?.mergeSettings
        let method = method(in: settings)
        let warning = GitHubWriteWords.mergeWarning(item: current, pull: pull)
        List {
            if case .editing(let reason?) = state.phase {
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
                    // Under the item line it lost the header trait the
                    // section gives a header of its own.
                    Text("Method")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if let pull, !pull.isCrossRepository {
                Section {
                    if pull.mergeSettings.deletesBranch {
                        Toggle("Delete Branch", isOn: .constant(true))
                            .disabled(true)
                    } else {
                        Toggle("Delete Branch", isOn: $state.deletesBranch)
                            .disabled(state.phase.isWorking)
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
                    Text(state.phase.isWorking ? String(localized: "Merging…") : (method?.title ?? String(localized: "Merge")))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.phase.isWorking || method == nil || pull?.headCommit == nil)
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
            state.chosenMethod = candidate
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
        .disabled(state.phase.isWorking)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Merges the head the sheet showed, so a commit pushed since is not
    /// merged unseen.
    private func merge(_ method: GitHubMergeMethod?, pull: GitHubPullRequestDetail?) {
        guard case .editing = state.phase, let method, let pull, let headCommit = pull.headCommit else { return }
        let offersDeleteBranch = !pull.isCrossRepository && !pull.mergeSettings.deletesBranch
        let deleteBranch = offersDeleteBranch && state.deletesBranch
        if offersDeleteBranch { store.settings.rememberMergeDeletesBranch(state.deletesBranch) }
        state.phase = .working
        Task {
            let result: GitHubWriteResult
            switch await store.write(
                .merge(method, deleteBranch: deleteBranch, headCommit: headCommit), on: item, host: host,
                shownBy: presence)
            {
            case .ranNothing:
                state.phase = .editing(notRun: GitHubWriteWords.busy)
                return
            case .screenGone:
                // It may have merged: the form never comes back for a second tap.
                close()
                return
            case .result(let shown):
                result = shown
            }
            if case .notRun(let reason) = result.outcome {
                state.phase = .editing(notRun: reason)
            } else {
                state.phase = .done(result)
            }
        }
    }
}

// MARK: - Pieces

/// The item a sheet acts on, above its form.
private struct GitHubWriteItemLine: View {
    let item: GitHubItem
    /// The Host, under the title, where nothing around the line names it.
    var hostName: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: GitHubItemRow.symbol(for: item))
                .foregroundStyle(GitHubItemRow.tint(for: item))
            VStack(alignment: .leading, spacing: 2) {
                // One Text, like Send to Agent's: side by side, the title kept
                // one line and lost most of itself. The header is secondary
                // already; `.secondary` again dimmed the repository to 1.8:1.
                (Text(verbatim: "\(item.repositoryName) #\(item.number)  ")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    + Text(item.title).foregroundStyle(Color(uiColor: .label)))
                    .lineLimit(dynamicTypeSize >= .xxxLarge ? 4 : 2)
                if let hostName {
                    Text("On \(hostName)")
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
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
    /// Names the Host under the item: a result shown after its sheet has
    /// gone can land over another item's detail, or over no item at all.
    var namesHost = false
    let done: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let page = GitHubWriteWords.page(for: result)
        ScrollView {
            VStack(alignment: page.style == .merged ? .center : .leading, spacing: 12) {
                // The item the page's words refer to.
                GitHubWriteItemLine(item: result.detail?.item ?? result.item, hostName: namesHost ? host.name : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                // Kept on screen so a refused, lost or unsent comment can be
                // copied; the tab shows an unsent one after its sheet has gone.
                if [.unknown, .refused, .notRun].contains(page.style), let typed, !typed.isEmpty {
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
                    // The row the write began from when the read after failed too.
                    if page.style == .unknown || page.style == .unread,
                        let url = URL(string: (result.detail?.item ?? result.item).url)
                    {
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
                .accessibilityAddTraits(.isHeader)
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
            .accessibilityAddTraits(.isHeader)
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
            /// gh exited without one, and the item could not be read after.
            case unread
            case unknown
            /// Nothing ran.
            case notRun

            var symbol: String {
                switch self {
                case .merged: "arrow.triangle.merge"
                case .refused: "xmark.circle"
                case .pending: "clock"
                case .unread: "info.circle"
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
                case .pending, .unread: .secondary
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
        let check =
            switch action {
            case .comment, .approve:
                String(localized: "Check the conversation on GitHub before you try again.")
            case .merge, .close:
                String(localized: "Check it on GitHub before you try again.")
            }
        switch result.outcome {
        case .notRun(let reason):
            return Page(style: .notRun, title: notRunTitle(action), summary: reason)
        case .finished(let status, let printed):
            let shown = printed.isEmpty ? nil : printed
            // Silence from a gh that succeeded needs no sentence.
            let said: String? =
                switch (shown, status) {
                case (nil, 0): nil
                case (nil, _): String(localized: "gh printed nothing. It stopped with status \(Int(status)).")
                default: String(localized: "This is what gh printed.")
                }
            // With no read after it, nothing says whether the change shows.
            if status == 0, result.detail == nil {
                let unconfirmed =
                    isPullRequest
                    ? String(localized: "gh reported success, but Heeler could not read the pull request again to confirm it.")
                    : String(localized: "gh reported success, but Heeler could not read the issue again to confirm it.")
                return Page(
                    style: .unread, title: String(localized: "gh Finished"),
                    summary: [unconfirmed, result.readFailure.map(GitHubBannerText.message(for:)), check]
                        .compactMap { $0 }.joinedAsSentences(),
                    printed: shown, caption: said)
            }
            if status == 0 {
                return Page(
                    style: .pending,
                    title: action == .merge ? String(localized: "Not Merged Yet") : String(localized: "Not Closed Yet"),
                    printed: shown,
                    caption: [String(localized: "gh finished without an error."), stillOpen, said]
                        .compactMap { $0 }.joinedAsSentences())
            }
            return Page(
                style: .refused, title: refusedTitle(action, isPullRequest: isPullRequest), printed: shown,
                caption: [said, stillOpen ?? readFailed].compactMap { $0 }.joinedAsSentences())
        case .unknown(let reason):
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
