import Foundation
import SwiftUI
import UIKit

/// An Agents list row's glance at its Agent's Checkout Changes: the line
/// totals of the latest read, the same numbers the Changes header shows for
/// it, or Tide's file counts when no line changed. Nil whenever that read cannot vouch for them: nothing read yet, a
/// clean Checkout, a failed read, a refresh that timed out keeping older
/// content, or line counts git could not produce.
///
/// A count that is only a lower bound keeps its visible text and says
/// "At least" to VoiceOver alone: the header carries the visible qualifier,
/// and the row has no room for one.
struct ChangesBadge: Equatable {
    /// How a count is written: exactly as the header writes it, or shortened
    /// from 1,000 when the row has no room for the exact form.
    enum Style: CaseIterable {
        case exact
        case compact
    }

    let totals: ChangesTotals
    /// The Host capped its status output, so file counts are lower bounds.
    let isStatusTruncated: Bool
    /// Tide's nonzero file counts, as the Tide git item writes them.
    let fileCounts: [TideGitItem.FileCount]

    init?(phase: ChangesStore.Phase, timedOutKeepingContent: Bool) {
        guard case .loaded(let changes) = phase, !timedOutKeepingContent, !changes.isClean,
            changes.totals.linesAreAvailable
        else { return nil }
        totals = changes.totals
        isStatusTruncated = changes.isStatusTruncated
        fileCounts = TideGitItem.fileCounts(changes)
    }

    /// Fixed totals, for a card that stands in for an Agent.
    init(
        totals: ChangesTotals, isStatusTruncated: Bool = false,
        fileCounts: [TideGitItem.FileCount] = []
    ) {
        self.totals = totals
        self.isStatusTruncated = isStatusTruncated
        self.fileCounts = fileCounts
    }

    func addedText(_ style: Style = .exact, locale: Locale = .current) -> String {
        "+" + Self.count(totals.added, style: style, locale: locale)
    }

    /// The minus sign is U+2212, as in the header.
    func removedText(_ style: Style = .exact, locale: Locale = .current) -> String {
        "\u{2212}" + Self.count(totals.removed, style: style, locale: locale)
    }

    /// Zero lines on both sides is still a dirty Checkout (untracked,
    /// binary, mode-only, or pure rename changes); "+0 −0" would read as
    /// clean, so the badge shows Tide's file counts instead, as "+1 !2 ?3".
    var showsFiles: Bool { totals.added == 0 && totals.removed == 0 }

    /// A side with no lines is left out, as "+48" rather than "+48 −0";
    /// the header still writes both.
    var showsAdded: Bool { totals.added > 0 }
    var showsRemoved: Bool { totals.removed > 0 }

    func fileCountText(
        _ count: TideGitItem.FileCount, style: Style = .exact, locale: Locale = .current
    ) -> String {
        count.symbol + Self.count(count.count, style: style, locale: locale)
    }

    /// Always exact.
    var accessibilityValue: String {
        guard showsFiles else {
            return (totals.linesAreComplete ? "" : "At least ")
                + LineCounts.lines(added: totals.added, removed: totals.removed).accessibilityLabel
        }
        var parts: [String] = []
        if totals.trackedFiles > 0 || totals.untrackedItems == 0 {
            parts.append(totals.spokenFiles(statusTruncated: isStatusTruncated))
        }
        if totals.untrackedItems > 0 {
            parts.append(totals.spokenUntracked(statusTruncated: isStatusTruncated))
        }
        return parts.joined(separator: ", ")
    }

    /// Exact counts are grouped as the header groups them. Compact counts
    /// from 1,000 are rounded toward zero so they never overstate, and keep
    /// at most three significant digits, or two below 10,000, where a third
    /// would be no shorter than the exact count: 1.2K, 12.3K, 999K, 1.23M.
    static func count(_ value: Int, style: Style, locale: Locale) -> String {
        guard style == .compact, value >= 1_000,
            let unit = compactUnits.first(where: { value >= $0.scale })
        else { return value.formatted(.number.locale(locale)) }
        let whole = value / unit.scale
        // Past the largest unit; only an overflowed total gets here.
        guard whole < 1_000 else { return "999\(unit.suffix)+" }
        var digits = whole >= 100 ? 0 : whole >= 10 || value < 10_000 ? 1 : 2
        var fraction = (value % unit.scale) / (unit.scale / powerOfTen(digits))
        while digits > 0, fraction % 10 == 0 {
            fraction /= 10
            digits -= 1
        }
        guard digits > 0 else { return "\(whole)\(unit.suffix)" }
        let fractionText = String(fraction)
        let padding = String(repeating: "0", count: max(0, digits - fractionText.count))
        return "\(whole)\(locale.decimalSeparator ?? ".")\(padding)\(fractionText)\(unit.suffix)"
    }

    private static let compactUnits: [(scale: Int, suffix: String)] = [
        (1_000_000_000_000, "T"), (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K"),
    ]

    private static func powerOfTen(_ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * 10 }
    }
}

/// Green additions and red removals, as GitHub and VS Code show a diff
/// summary: the diff's own inks in light, one step lighter in dark, where
/// the diff's would fall under 4.5:1 on a selected row in an elevated
/// sidebar. The status chip in the same row uses green for Done and red for
/// Blocked, so the leading + and − carry the meaning on their own; colour is
/// never the only channel. Each ink keeps at least 4.5:1 on the Agents
/// list's grounds, selected or not, in light and dark appearances.
enum ChangesBadgePalette {
    static let addedInk = DiffPalette.adaptive(light: 0x116329, dark: 0x56D364)
    static let removedInk = DiffPalette.adaptive(light: 0xB42318, dark: 0xFFA198)
}

/// An Agent's Checkout totals, "+12 −7" in green and red, or, when no line
/// changed, Tide's file counts in gray, "+1 !2 ?3", at the trailing end of its Agents list row's
/// last detail line and of Agent detail's status line. Not a control; the row opens the Agent, and the Agent menu
/// opens Changes. Exact totals come first; a line without room takes the
/// shortened form.
struct ChangesRowTotals: View {
    enum Source {
        /// The latest read of an Agent's Checkout.
        case store(ChangesStore)
        /// Fixed totals, as the Agent List Fields preview shows.
        case sample(ChangesBadge)
    }

    let source: Source
    /// The surrounding line's size, so the totals match its text.
    var font: Font = .caption
    /// Where the totals show, as UI tests find them.
    var identifier = "agent-row-changes"
    @Environment(\.locale) private var locale

    init(
        store: ChangesStore, font: Font = .caption,
        identifier: String = "agent-row-changes"
    ) {
        self.init(source: .store(store), font: font, identifier: identifier)
    }

    init(
        source: Source, font: Font = .caption,
        identifier: String = "agent-row-changes"
    ) {
        self.source = source
        self.font = font
        self.identifier = identifier
    }

    /// Whether there is anything to show, for a row that holds only the
    /// totals.
    var hasTotals: Bool { badge != nil }

    private var badge: ChangesBadge? {
        switch source {
        case .store(let store):
            ChangesBadge(phase: store.phase, timedOutKeepingContent: store.timedOutKeepingContent)
        case .sample(let badge):
            badge
        }
    }

    var body: some View {
        if let badge {
            ViewThatFits(in: .horizontal) {
                totals(badge, style: .exact)
                totals(badge, style: .compact)
            }
        }
    }

    private func totals(_ badge: ChangesBadge, style: ChangesBadge.Style) -> some View {
        HStack(spacing: 4) {
            if badge.showsFiles {
                fileCounts(badge, style: style)
            } else {
                if badge.showsAdded {
                    Text(badge.addedText(style, locale: locale))
                        .foregroundStyle(Color(uiColor: ChangesBadgePalette.addedInk))
                }
                if badge.showsRemoved {
                    Text(badge.removedText(style, locale: locale))
                        .foregroundStyle(Color(uiColor: ChangesBadgePalette.removedInk))
                }
            }
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Changes: " + badge.accessibilityValue)
        // VoiceOver hears exact counts either way; this says which one shows.
        .accessibilityIdentifier(identifier + (style == .exact ? ".exact" : ".compact"))
    }

    /// Tide's file counts, gray, as the Tide git item draws them on the status line.
    ///
    /// SwiftUI can build these cells on its async render thread
    /// (FB20692404). A main-actor cell closure checks its isolation on entry,
    /// and on iOS 18 that check traps there (#471), so the closure is
    /// `@Sendable` and takes the locale by value.
    func fileCounts(
        _ badge: ChangesBadge, style: ChangesBadge.Style
    ) -> ForEach<[TideGitItem.FileCount], String, some View> {
        ForEach(badge.fileCounts, id: \.symbol) { @Sendable [locale] count in
            Text(badge.fileCountText(count, style: style, locale: locale))
                .foregroundStyle(.secondary)
        }
    }
}
