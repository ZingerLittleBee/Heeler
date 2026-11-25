import SwiftUI

/// One pull request or issue in two parts (ADR 0065): an over line with its
/// state glyph, where it is and how old, and how it stands at the trailing
/// end; then its title across the row. An issue with labels adds them on a
/// third line.
struct GitHubItemRow: View {
    let item: GitHubItem
    let context: GitHubRowContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes a line that fits a phone holds a word or
        // two, so the lines wrap rather than cut off what they say, and the
        // status goes under the over line rather than squeeze it.
        let wraps = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if wraps {
                    overLine(wraps: true)
                    status
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        overLine(wraps: false)
                        Spacer(minLength: 0)
                        // Never cut off: the repository and the author give
                        // way first.
                        status?.fixedSize()
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(item.title)
                .font(.body.weight(.medium))
                .lineLimit(wraps ? 4 : 2)
            if let labels {
                Text(verbatim: labels)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(wraps ? nil : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Every row's separator starts at its text, rather than where the
        // list guesses its first text begins.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The row as VoiceOver reads it, in the order a glance takes it in:
    /// what it is, its title, where, how it stands, then its checks and
    /// review or its labels and comments, and when it last changed.
    private var accessibilityText: String {
        var parts = [
            item.kind == .pullRequest
                ? String(localized: "Pull request", comment: "Read first for a pull request in the GitHub list.")
                : String(localized: "Issue", comment: "Read first for an issue in the GitHub list."),
            item.title,
            "\(item.repositoryName) #\(item.number)",
            GitHubItemWords.state(of: item),
        ]
        if let author = context.shownAuthor(of: item) {
            parts.append(String(localized: "Opened by \(author)", comment: "Who opened a pull request or an issue, read in the GitHub list."))
        }
        switch item.kind {
        case .pullRequest:
            if item.state == .open || item.state == .draft {
                let checks = item.checks?.summary ?? .none
                if case .none = checks {
                    parts.append(Self.title(for: checks))
                } else {
                    parts.append(
                        String(
                            localized: "checks \(Self.title(for: checks))",
                            comment: "How a pull request's checks stand, read in the GitHub list: checks 3 failing."))
                }
                // A merged or closed pull request's line says only that.
                if let rest = pullRequestRest { parts.append(rest) }
            }
        case .issue:
            parts += item.labels.prefix(3).map(\.name)
            parts.append(
                item.commentCount > 0
                    ? String(
                        localized: "\(item.commentCount) comments", comment: "An issue's comment count in the GitHub list.")
                    : String(localized: "No comments"))
        }
        parts.append(String(localized: "Updated \(Self.age(of: item.updatedAt, width: .wide)) ago"))
        return parts.joined(separator: ", ")
    }

    /// "Heeler #712 · riley-dev · 2h" after the state glyph: the author
    /// where it is someone else and the list is not of one person's items.
    /// On one line a long repository or author name gives way, never the
    /// number or the age.
    @ViewBuilder
    private func overLine(wraps: Bool) -> some View {
        let author = context.shownAuthor(of: item)
        let age = Self.age(of: item.updatedAt)
        let glyph = Text(Image(systemName: Self.symbol(for: item))).foregroundStyle(Self.tint(for: item))
        if wraps {
            glyph
                + Text(verbatim: " " + ["\(item.repositoryName) #\(item.number)", author, age].compactMap(\.self)
                    .joined(separator: " · "))
        } else {
            HStack(spacing: 0) {
                glyph.padding(.trailing, 5).layoutPriority(2)
                Text(verbatim: item.repositoryName).layoutPriority(1)
                Text(verbatim: " #\(item.number)").layoutPriority(2)
                if let author {
                    Text(verbatim: " · \(author)").layoutPriority(1)
                }
                Text(verbatim: " · \(age)").layoutPriority(2)
            }
            .lineLimit(1)
        }
    }

    /// How the item stands, in one word at the over line's end. A pull
    /// request: its checks' glyph, then what asks for attention (your
    /// review, the change size, the review decision), else the checks'
    /// word; with no checks, Draft for a draft, else that ask alone. Merged
    /// and closed say only that, in their colours. An issue: its comment
    /// count, if any.
    private var status: Text? {
        switch item.kind {
        case .pullRequest:
            if item.state == .merged {
                return Text("Merged").foregroundStyle(GitHubInk.purple)
            }
            if item.state == .closed {
                return Text(GitHubItemWords.state(of: item)).foregroundStyle(GitHubInk.red)
            }
            let checks = item.checks?.summary ?? .none
            if let symbol = Self.symbol(for: checks) {
                return Text(Image(systemName: symbol)).font(.caption2).foregroundStyle(Self.tint(for: checks))
                    + Text(verbatim: " \(pullRequestRest ?? Self.title(for: checks))")
            }
            if item.state == .draft { return Text("Draft") }
            return pullRequestRest.map { Text(verbatim: $0) }
        case .issue:
            guard item.commentCount > 0 else { return nil }
            return Text(Image(systemName: "bubble.left")).font(.caption2)
                + Text(verbatim: " \(item.commentCount.formatted())")
        }
    }

    /// After the checks: where someone else asks for your review, that, or
    /// the change size in a list of what asks for it; otherwise the review
    /// decision.
    private var pullRequestRest: String? {
        if context.asksViewer(item) {
            if context.isReviewList, let additions = item.additions, let deletions = item.deletions {
                // A no-break space: the two counts wrap as one.
                return "+\(additions.formatted())\u{00A0}\u{2212}\(deletions.formatted())"
            }
            return String(
                localized: "Needs your review",
                comment: "At the end of a GitHub list row's first line: the pull request asks for the account's review.")
        }
        if let review = item.review, item.state != .draft {
            return GitHubItemWords.decision(review)
        }
        return nil
    }

    /// An issue's first three labels, on a line of their own.
    private var labels: String? {
        guard item.kind == .issue, !item.labels.isEmpty else { return nil }
        return item.labels.prefix(3).map(\.name).joined(separator: " · ")
    }

    // MARK: Glyphs and words

    static func symbol(for item: GitHubItem) -> String {
        switch (item.kind, item.state) {
        case (.pullRequest, .merged): "arrow.triangle.merge"
        case (.pullRequest, .draft): "circle.dashed"
        case (.pullRequest, _): ConsoleTab.gitHubSymbol
        case (.issue, .closed): item.closedReason == .notPlanned ? "circle.slash" : "checkmark.circle"
        case (.issue, _): "smallcircle.filled.circle"
        }
    }

    /// GitHub's: a closed pull request red, an issue closed as completed
    /// purple, and one not planned grey.
    static func tint(for item: GitHubItem) -> Color {
        switch (item.kind, item.state) {
        case (_, .open): GitHubInk.green
        case (_, .draft): .secondary
        case (_, .merged): GitHubInk.purple
        case (.pullRequest, .closed): GitHubInk.red
        case (.issue, .closed): item.closedReason == .notPlanned ? GitHubInk.grey : GitHubInk.purple
        }
    }

    private static func symbol(for checks: GitHubChecks.Summary) -> String? {
        switch checks {
        case .failing: "xmark.circle.fill"
        case .running: "clock.fill"
        case .passing: "checkmark.circle.fill"
        case .none: nil
        }
    }

    private static func tint(for checks: GitHubChecks.Summary) -> Color {
        switch checks {
        case .failing: GitHubInk.red
        case .running: GitHubInk.amber
        case .passing: GitHubInk.green
        case .none: .secondary
        }
    }

    private static func title(for checks: GitHubChecks.Summary) -> String {
        switch checks {
        case .failing(let count):
            String(localized: "\(count) failing", comment: "How many of a pull request's checks failed, in the GitHub list.")
        case .running: String(localized: "Running")
        case .passing: String(localized: "Passing")
        case .none: String(localized: "No checks yet")
        }
    }

    /// "5m", "2h", "3d": the largest whole unit since the last update;
    /// "2 hours" with a wide width, as VoiceOver reads it.
    nonisolated static func age(
        of date: Date, now: Date = Date(), width: Duration.UnitsFormatStyle.UnitWidth = .narrow
    ) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let duration: Duration =
            switch seconds {
            case ..<60: .seconds(seconds)
            case ..<3600: .seconds(seconds / 60 * 60)
            case ..<86_400: .seconds(seconds / 3600 * 3600)
            default: .seconds(seconds / 86_400 * 86_400)
            }
        return duration.formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: width, maximumUnitCount: 1))
    }

    /// A row's shape while the first read runs: an over line with a
    /// status, and a title of two lines.
    static var placeholder: some View {
        GitHubItemRow(
            item: GitHubItem(
                id: "", kind: .pullRequest, repository: "owner/repository", number: 100,
                title: "A pull request title that runs to two lines in the list", url: "",
                author: nil, state: .open, updatedAt: Date(), commentCount: 0,
                checks: GitHubChecks(failing: 0, pending: 0, passing: 1), review: nil,
                additions: nil, deletions: nil, labels: []),
            context: GitHubRowContext())
            .redacted(reason: .placeholder)
            // Redacted, its label reads as a run of blank glyphs; the line
            // under the title, or before iOS 26 the section's "Reading
            // from…" heading, says what is happening.
            .accessibilityHidden(true)
    }
}

/// What the list around a row says of it, which its words leave out or add.
struct GitHubRowContext: Equatable {
    /// The account gh is signed in to, whose own items name no author.
    var viewer: String?
    /// The list holds what one person created.
    var isByAuthor = false
    /// The list holds what asks for the account's review.
    var isReviewList = false

    init(viewer: String? = nil, filter: GitHubListFilter = GitHubListFilter()) {
        self.viewer = viewer
        isByAuthor = filter.person?.role == .author
        isReviewList = filter.person == GitHubListFilter.Person(role: .reviewRequested, login: nil)
    }

    /// The author the over line names, if any.
    func shownAuthor(of item: GitHubItem) -> String? {
        guard !isByAuthor, let author = item.author, author != viewer else { return nil }
        return author
    }

    /// An open pull request someone else opened asks for the account's review.
    func asksViewer(_ item: GitHubItem) -> Bool {
        item.asksViewerToReview == true && (item.state == .open || item.state == .draft)
            && (viewer == nil || item.author != viewer)
    }
}

/// The GitHub screens' state colours. The system tints are too light for
/// footnote text and small glyphs on white and grouped backgrounds, so
/// light mode uses darker tones that keep 4.5:1; dark mode keeps tones
/// close to the system's. Red is the app's error ink.
enum GitHubInk {
    static let green = ink(light: 0x1A7030, dark: 0x30D158)
    static let red = Color.errorInk
    static let amber = ink(light: 0x9A4A00, dark: 0xFFD60A)
    static let purple = ink(light: 0x8944AB, dark: 0xD08BFF)
    static let grey = ink(light: 0x59636E, dark: 0x9198A1)

    private static func ink(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}
