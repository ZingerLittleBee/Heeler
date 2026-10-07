import SwiftUI

/// Chat's Background Work over the Composer (ADR 0020): up to three rows,
/// running work first, then "+N more"; one line while the Composer is open
/// or a Blocked card stands in its place. Every row opens the sheet that
/// lists it all; nothing here stops work. Empty when there is nothing to
/// list, so its height drops to zero.
struct ChatBackgroundWorkStrip: View {
    let work: ChatBackgroundWork
    let isHostConnected: Bool
    let isCondensed: Bool
    /// Opens the sheet at a row's id, or at no row.
    let open: (String?) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        if !work.rows.isEmpty {
            // Only a running row's time moves, so only then does it tick.
            if presentation(at: .now).ticks {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(presentation(at: context.date))
                }
            } else {
                content(presentation(at: .now))
            }
        }
    }

    private func presentation(at now: Date) -> ChatBackgroundWorkPresentation {
        ChatBackgroundWorkPresentation(
            work: work, isHostConnected: isHostConnected, now: now, locale: locale, calendar: calendar)
    }

    @ViewBuilder
    private func content(_ presentation: ChatBackgroundWorkPresentation) -> some View {
        Group {
            if isCondensed, let summary = presentation.summary {
                ChatBackgroundWorkSummaryLine(summary: summary, open: { open(nil) })
            } else {
                ChatBackgroundWorkRows(presentation: presentation, open: open)
            }
        }
        // The Composer card's inset, so the edges line up.
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

enum ChatBackgroundWorkStyle {
    /// Rounder than a banner, less than the Composer card below it.
    static let card = RoundedRectangle(cornerRadius: 18, style: .continuous)
    static let hint = "Shows all background work."
}

private struct ChatBackgroundWorkRows: View {
    let presentation: ChatBackgroundWorkPresentation
    let open: (String?) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.stripRows) { row in
                Button { open(row.id) } label: {
                    ChatBackgroundWorkRowLabel(row: row, glyphColumn: glyphColumn)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityHint(ChatBackgroundWorkStyle.hint)
                .accessibilityAddTraits(row.status == .running ? [.isButton, .updatesFrequently] : .isButton)
                .accessibilityIdentifier("chat.background-work.\(row.id)")
            }
            if presentation.overflow > 0 {
                Button { open(nil) } label: {
                    Text("+\(presentation.overflow) more")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        // Under the titles, as the list's next line.
                        .padding(.leading, glyphColumn + 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("\(presentation.overflow) more")
                .accessibilityHint(ChatBackgroundWorkStyle.hint)
                .accessibilityIdentifier("chat.background-work.more")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: ChatBackgroundWorkStyle.card)
        .overlay { ChatBackgroundWorkStyle.card.stroke(Color.secondary.opacity(0.16), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background work")
        .accessibilityIdentifier("chat.background-work")
    }
}

/// One row: its state, its name and kind, and how far along it is. At
/// accessibility sizes the name takes its own line.
private struct ChatBackgroundWorkRowLabel: View {
    let row: ChatBackgroundWorkPresentation.Row
    let glyphColumn: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 36

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ChatBackgroundWorkGlyph(status: row.status)
                .frame(width: glyphColumn)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    HStack(spacing: 6) {
                        caption
                        meta
                    }
                }
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title
                        .layoutPriority(1)
                    caption
                }
                Spacer(minLength: 8)
                meta
            }
        }
    }

    private var title: some View {
        Text(verbatim: row.title)
            .font(.subheadline)
            // A Workflow's name is an identifier, as a command is.
            .fontDesign(row.kind == .workflow ? .monospaced : nil)
            .foregroundStyle(row.status == .completed || row.status == .stopped ? .secondary : .primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var caption: some View {
        Text(verbatim: row.caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Never wraps and keeps its digits' width, so a tick can't move the
    /// row or the conversation above it.
    private var meta: some View {
        HStack(spacing: 6) {
            if let fraction = row.fraction {
                if !row.status.isFinished {
                    ProgressView(value: Double(min(fraction.done, fraction.total)), total: Double(max(fraction.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(.secondary)
                        .frame(width: barWidth)
                }
                Text(verbatim: "\(fraction.done)/\(fraction.total)")
            }
            if let time = row.time {
                Text(verbatim: time)
            } else if let note = row.note {
                Text(verbatim: note)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// The rows condensed to one line, which opens the sheet.
private struct ChatBackgroundWorkSummaryLine: View {
    let summary: ChatBackgroundWorkPresentation.Summary
    let open: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 18

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ChatBackgroundWorkGlyph(status: summary.status)
                    .frame(width: glyphColumn)
                Text(verbatim: summary.text)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: ChatBackgroundWorkStyle.card)
            .overlay { ChatBackgroundWorkStyle.card.stroke(Color.secondary.opacity(0.16), lineWidth: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Background work")
        .accessibilityValue(summary.accessibilityValue)
        .accessibilityHint(ChatBackgroundWorkStyle.hint)
        .accessibilityAddTraits(summary.status == .running ? [.isButton, .updatesFrequently] : .isButton)
        .accessibilityIdentifier("chat.background-work.summary")
    }
}

/// A row's state as tool rows draw theirs. The label says it in words.
struct ChatBackgroundWorkGlyph: View {
    let status: ChatBackgroundWorkPresentation.Status

    var body: some View {
        Group {
            switch status {
            case .running:
                // On a symbol's baseline, so it sits on a line of text as
                // the other glyphs do.
                Image(systemName: "circle")
                    .hidden()
                    .overlay {
                        ProgressView()
                            .controlSize(.mini)
                    }
            case .unconfirmed, .quiet:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .completed:
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            case .stopped:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}
