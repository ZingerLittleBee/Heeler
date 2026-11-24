import SwiftUI

/// One pull request or issue in three lines: where it is and how old, its
/// title, and how it stands (ADR 0064).
struct GitHubItemRow: View {
    let item: GitHubItem
    let section: GitHubListSection.Kind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(for: item))
                .foregroundStyle(Self.tint(for: item))
                .font(.body.weight(.medium))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(overLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                status
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "Heeler #712 · riley-dev · 2h": the author only where the request
    /// came from someone else.
    private var overLine: String {
        var parts = ["\(item.repositoryName) #\(item.number)"]
        if section == .reviewRequested, let author = item.author { parts.append(author) }
        parts.append(Self.age(of: item.updatedAt))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var status: some View {
        switch item.kind {
        case .pullRequest: pullRequestStatus
        case .issue: Text(issueStatus)
        }
    }

    private var pullRequestStatus: some View {
        let checks = item.checks?.summary ?? .none
        var rest: [String] = []
        if section == .reviewRequested, let additions = item.additions, let deletions = item.deletions {
            rest.append("+\(additions.formatted()) \u{2212}\(deletions.formatted())")
        } else if let review = item.review, item.state != .draft {
            rest.append(GitHubItemWords.decision(review))
        }
        return HStack(spacing: 4) {
            if item.state == .merged {
                Text("Merged").foregroundStyle(GitHubInk.purple)
            } else {
                if item.state == .draft {
                    Text("Draft")
                    Text(verbatim: "·")
                }
                if let symbol = Self.symbol(for: checks) {
                    Image(systemName: symbol)
                        .foregroundStyle(Self.tint(for: checks))
                        .imageScale(.small)
                }
                Text(Self.title(for: checks))
                if !rest.isEmpty {
                    Text(verbatim: "· \(rest.joined(separator: " · "))")
                }
            }
        }
    }

    /// Labels, then the comment count.
    private var issueStatus: String {
        var parts = item.labels.prefix(3).map(\.name)
        if item.commentCount > 0 {
            parts.append(
                String(localized: "\(item.commentCount) comments", comment: "An issue's comment count in the GitHub list."))
        }
        return parts.isEmpty ? String(localized: "No comments") : parts.joined(separator: " · ")
    }

    // MARK: Glyphs and words

    static func symbol(for item: GitHubItem) -> String {
        switch (item.kind, item.state) {
        case (.pullRequest, .merged): "arrow.triangle.merge"
        case (.pullRequest, .draft): "circle.dashed"
        case (.pullRequest, _): ConsoleTab.gitHubSymbol
        case (.issue, .closed): "checkmark.circle"
        case (.issue, _): "smallcircle.filled.circle"
        }
    }

    static func tint(for item: GitHubItem) -> Color {
        switch item.state {
        case .open: GitHubInk.green
        case .draft: .secondary
        case .merged: GitHubInk.purple
        case .closed: GitHubInk.red
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

    /// "5m", "2h", "3d": the largest whole unit since the last update.
    nonisolated static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let duration: Duration =
            switch seconds {
            case ..<60: .seconds(seconds)
            case ..<3600: .seconds(seconds / 60 * 60)
            case ..<86_400: .seconds(seconds / 3600 * 3600)
            default: .seconds(seconds / 86_400 * 86_400)
            }
        return duration.formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1))
    }

    /// A row's shape while the first read runs.
    static var placeholder: some View {
        GitHubItemRow(
            item: GitHubItem(
                id: "", kind: .pullRequest, repository: "owner/repository", number: 100,
                title: "A pull request title that runs to two lines in the list", url: "",
                author: nil, state: .open, updatedAt: Date(), commentCount: 0,
                checks: GitHubChecks(failing: 0, pending: 0, passing: 1), review: nil,
                additions: nil, deletions: nil, labels: []),
            section: .authored)
            .redacted(reason: .placeholder)
    }
}

/// The GitHub screens' state colours. The system tints are too light for
/// footnote text and small glyphs on white and grouped backgrounds, so
/// light mode uses darker tones that keep 4.5:1; dark mode keeps tones
/// close to the system's.
enum GitHubInk {
    static let green = ink(light: 0x1A7030, dark: 0x30D158)
    static let red = ink(light: 0xC4161C, dark: 0xFF6961)
    static let amber = ink(light: 0x9A4A00, dark: 0xFFD60A)
    static let purple = ink(light: 0x8944AB, dark: 0xD08BFF)

    private static func ink(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}
