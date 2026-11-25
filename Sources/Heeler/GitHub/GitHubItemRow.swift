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
                    overLine(wraps: false)
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
    /// On one line, with the status at its end, as `GitHubOverLineLayout`
    /// fits them.
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
            GitHubOverLineLayout {
                glyph.padding(.trailing, 5)
                    .layoutValue(key: OverLinePartKey.self, value: .glyph)
                Text(verbatim: item.repositoryName).shortens()
                    .layoutValue(key: OverLinePartKey.self, value: .repository)
                Text(verbatim: String(item.repositoryName.prefix(8)) + "…").hidden()
                    .layoutValue(key: OverLinePartKey.self, value: .repositoryLeast)
                Text(verbatim: " #\(item.number)")
                    .layoutValue(key: OverLinePartKey.self, value: .number)
                if let author {
                    Text(verbatim: " · \(author)").shortens()
                        .layoutValue(key: OverLinePartKey.self, value: .author)
                    Text(verbatim: " · " + String(author.prefix(3)) + "…").hidden()
                        .layoutValue(key: OverLinePartKey.self, value: .authorLeast)
                }
                Text(verbatim: " · \(age)")
                    .layoutValue(key: OverLinePartKey.self, value: .age)
                if let status {
                    status
                        .layoutValue(key: OverLinePartKey.self, value: .status)
                }
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

/// A piece of a row's over line, as `GitHubOverLineLayout` fits it.
private enum OverLinePart {
    case glyph, repository, number, author, age, status
    /// Hidden: the repository's first eight characters, the least it keeps.
    case repositoryLeast
    /// Hidden: the author's first three characters, the least it keeps.
    case authorLeast
}

private struct OverLinePartKey: LayoutValueKey {
    static let defaultValue: OverLinePart? = nil
}

private extension View {
    /// Shortens to whatever width the over line gives it, down to nothing.
    func shortens() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
    }
}

/// A row's over line on one line, with the status at its end. Short of
/// room, the author gives way first, shortening and then leaving with its
/// dot, then the repository, which keeps about eight characters before its
/// number; past that the status goes under the line, as at accessibility
/// sizes. The glyph, the number and the age never shorten.
private struct GitHubOverLineLayout: Layout {
    private static let statusGap: CGFloat = 8
    private static let lineGap: CGFloat = 3

    private struct Placement {
        let subview: LayoutSubview
        let origin: CGPoint
        let proposal: ProposedViewSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for placement in arrange(width: bounds.width, subviews: subviews).placements {
            placement.subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: placement.proposal)
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, placements: [Placement]) {
        func part(_ piece: OverLinePart) -> LayoutSubview? { subviews.first { $0[OverLinePartKey.self] == piece } }
        func ideal(_ piece: OverLinePart) -> CGFloat { part(piece)?.sizeThatFits(.unspecified).width ?? 0 }

        let repository = ideal(.repository)
        let author = ideal(.author)
        let status = part(.status)
        let statusRoom = status == nil ? 0 : ideal(.status) + Self.statusGap
        let fixed = ideal(.glyph) + ideal(.number) + ideal(.age)
        let lineWidth = width ?? fixed + repository + author + statusRoom
        let repositoryLeast = min(repository, ideal(.repositoryLeast))
        let authorLeast = min(author, ideal(.authorLeast))
        // The widths the repository and the author get in a room.
        func fit(_ room: CGFloat) -> (repository: CGFloat, author: CGFloat)? {
            if room >= repository + authorLeast { return (repository, min(author, room - repository)) }
            if room >= repositoryLeast { return (min(repository, room), 0) }
            return nil
        }
        let statusIsBelow: Bool
        let widths: (repository: CGFloat, author: CGFloat)
        if let fitted = fit(lineWidth - fixed - statusRoom) {
            statusIsBelow = false
            widths = fitted
        } else {
            statusIsBelow = status != nil
            let room = lineWidth - fixed
            widths = fit(room) ?? (max(room, 0), 0)
        }

        var line: [(subview: LayoutSubview, proposal: ProposedViewSize, x: CGFloat)] = []
        var x: CGFloat = 0
        for piece in [OverLinePart.glyph, .repository, .number, .author, .age] {
            guard let subview = part(piece) else { continue }
            let proposal: ProposedViewSize =
                switch piece {
                case .repository: ProposedViewSize(width: widths.repository, height: nil)
                case .author: ProposedViewSize(width: widths.author, height: nil)
                default: .unspecified
                }
            line.append((subview, proposal, x))
            x += subview.sizeThatFits(proposal).width
        }
        if let status, !statusIsBelow {
            line.append((status, .unspecified, lineWidth - status.sizeThatFits(.unspecified).width))
        }
        // Every piece on its first baseline.
        let dimensions = line.map { $0.subview.dimensions(in: $0.proposal) }
        let baseline = dimensions.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        var placements: [Placement] = []
        var height: CGFloat = 0
        for (piece, size) in zip(line, dimensions) {
            let y = baseline - size[VerticalAlignment.firstTextBaseline]
            placements.append(Placement(subview: piece.subview, origin: CGPoint(x: piece.x, y: y), proposal: piece.proposal))
            height = max(height, y + size.height)
        }
        if let status, statusIsBelow {
            let proposal = ProposedViewSize(width: min(status.sizeThatFits(.unspecified).width, lineWidth), height: nil)
            placements.append(Placement(subview: status, origin: CGPoint(x: 0, y: height + Self.lineGap), proposal: proposal))
            height += Self.lineGap + status.sizeThatFits(proposal).height
        }
        // The hidden measures take no room.
        for piece in [OverLinePart.repositoryLeast, .authorLeast] {
            if let subview = part(piece) {
                placements.append(Placement(subview: subview, origin: .zero, proposal: .zero))
            }
        }
        return (CGSize(width: lineWidth, height: height), placements)
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
