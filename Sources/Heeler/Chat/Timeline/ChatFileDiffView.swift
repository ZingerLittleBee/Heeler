import SwiftUI
import UIKit

/// A changed file's held hunks as the diff views draw them: numbered lines,
/// with the unchanged lines between hunks counted. One gutter numbers each
/// line as Claude Code's terminal does: a removed line by its old number,
/// every other line by its new one.
struct ChatFileDiff: Equatable {
    struct Hunk: Identifiable, Equatable {
        /// Unchanged lines between the hunk before and this one; nil for
        /// the first, or when they touch.
        var unchangedBefore: Int?
        var diff: DiffHunk

        var id: Int { diff.id }
    }

    var hunks: [Hunk]
    /// The file's lines it doesn't hold.
    var hiddenLines: Int
    /// Digits in the widest line number drawn.
    var numberDigits: Int
    /// Changed words per line id.
    var wordChanges: [Int: [Range<Int>]]

    init(_ file: ChatFileChange) {
        var hunks: [Hunk] = []
        var shown = 0
        var widest = 0
        var wordChanges: [Int: [Range<Int>]] = [:]
        var previous: ChatDiffHunk?
        for (index, recorded) in file.hunks.enumerated() {
            var old = recorded.oldStart
            var new = recorded.newStart
            var lines: [DiffLine] = []
            for text in recorded.lines {
                if ChatDiffHunk.isNewlineMarker(text) {
                    if !lines.isEmpty { lines[lines.count - 1].missingNewline = true }
                    continue
                }
                let line: DiffLine
                switch text.first {
                case "+":
                    line = DiffLine(id: shown, kind: .added, oldNumber: nil, newNumber: new, text: Self.code(of: text))
                    new += 1
                case "-":
                    line = DiffLine(id: shown, kind: .removed, oldNumber: old, newNumber: nil, text: Self.code(of: text))
                    old += 1
                default:
                    line = DiffLine(id: shown, kind: .context, oldNumber: old, newNumber: new, text: Self.code(of: text))
                    old += 1
                    new += 1
                }
                widest = max(widest, Self.number(of: line) ?? 0)
                lines.append(line)
                shown += 1
            }
            if !lines.isEmpty {
                let diff = DiffHunk(
                    id: index, oldStart: recorded.oldStart, oldCount: recorded.oldLines,
                    newStart: recorded.newStart, newCount: recorded.newLines, section: "", lines: lines)
                let gap = previous.map { recorded.oldStart - ($0.oldStart + $0.oldLines) }
                hunks.append(Hunk(unchangedBefore: gap.flatMap { $0 > 0 ? $0 : nil }, diff: diff))
                wordChanges.merge(DiffWordChanges.ranges(in: diff)) { first, _ in first }
            }
            previous = recorded
        }
        self.hunks = hunks
        hiddenLines = max(file.lineCount - shown, 0)
        numberDigits = String(widest).count
        self.wordChanges = wordChanges
    }

    /// The number a line shows in the gutter.
    static func number(of line: DiffLine) -> Int? {
        line.kind == .removed ? line.oldNumber : line.newNumber
    }

    /// A recorded line without its sign, or a carriage return a CRLF file
    /// leaves at its end.
    private static func code(of text: String) -> String {
        var code = "+- ".contains(text.first ?? "x") ? text.dropFirst() : text[...]
        if code.last == "\r" { code = code.dropLast() }
        return String(code)
    }
}

extension ChatFileChange {
    /// The recorded lines `hunks` holds.
    var heldLineCount: Int {
        hunks.reduce(0) { $0 + $1.diffLineCount }
    }
}

extension ChatFileChanges {
    /// What shows instead of files when Claude Code says only one thing: it
    /// skipped the diff, or took none and names no file.
    var soleNote: String? {
        if isSkipped { return "File diff skipped for this git command." }
        guard files.isEmpty, isUnavailable || isShared else { return nil }
        guard isUnavailable else { return Self.sharedNote }
        return moreFiles > 0
            ? "File diff unavailable for this command; \(Self.count(moreFiles)) changed."
            : "File diff unavailable for this command."
    }

    /// The lines under the files: how many more changed, then why the
    /// changes may not all be the command's own edits.
    var notes: [String] {
        guard soleNote == nil else { return [] }
        var notes: [String] = []
        if moreFiles > 0 {
            let more =
                files.isEmpty
                ? "\(Self.count(moreFiles)) changed (binary, mode only or too large to show)"
                : "… \(moreFiles) more \(moreFiles == 1 ? "file" : "files") changed"
            notes.append(isUnavailable ? more + " (part of the diff is unavailable)" : more)
        }
        if movesWorkingTree {
            notes.append("A git step in this command can move the working tree, so these may be its changes, not edits.")
        }
        if isShared { notes.append(Self.sharedNote) }
        return notes
    }

    static let sharedNote =
        "Another command ran in this repository at the same time; a change made by either may show under either result."

    private static func count(_ files: Int) -> String {
        "\(files) \(files == 1 ? "file" : "files")"
    }
}

/// The files a Bash command changed, under its row, as Claude Code's
/// terminal lists them: one line per file, whose diff opens in place.
struct ChatFileChangesList: View {
    let changes: ChatFileChanges
    let expandedFiles: Set<String>
    let read: ChatToolActivity.OutputRead?
    /// What an open file says while its lines were never read; nil when
    /// they can't be.
    let missingOutputText: String?
    let actions: ChatFileActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = changes.soleNote {
                ChatFileChangesNote(text: note)
            } else {
                ForEach(changes.files.indices, id: \.self) { index in
                    let file = changes.files[index]
                    let isExpanded = expandedFiles.contains(file.path)
                    VStack(alignment: .leading, spacing: 6) {
                        ChatFileChangeLine(
                            file: file, path: changes.displayPath(of: file), isExpanded: isExpanded
                        ) { actions.toggle(file.path) }
                        if isExpanded {
                            ChatInlineFileDiff(
                                file: file, read: read, missingOutputText: missingOutputText, actions: actions)
                        }
                    }
                }
                ForEach(changes.notes, id: \.self) { note in
                    ChatFileChangesNote(text: note)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a changed file's controls do, by the file's recorded path.
struct ChatFileActions {
    var toggle: (String) -> Void
    var showAll: (String) -> Void
    /// Tries a failed read of the row's line again.
    var retry: () -> Void
}

private struct ChatFileChangesNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One changed file: what happened to it, its path and its line counts. A
/// file with lines opens its diff.
private struct ChatFileChangeLine: View {
    let file: ChatFileChange
    let path: String
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        if file.lineCount > 0 {
            Button(action: toggle) {
                label
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the diff" : "Shows the diff")
        } else {
            label
                .accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(file.lineCount > 0 ? 1 : 0)
                .accessibilityHidden(true)
            Text("\(Text(file.kind.label).foregroundStyle(.secondary)) \(Text(verbatim: path).fontDesign(.monospaced))")
                .font(.footnote)
                .lineLimit(isExpanded ? nil : 2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChatDiffBadge(diff: ChatDiffStats(added: file.added, removed: file.removed))
        }
    }
}

/// A changed file's diff in its row: what `ChatFileChanges.rowLimits`
/// allow, the 40 lines Claude Code's terminal shows, then the footer.
struct ChatInlineFileDiff: View {
    let file: ChatFileChange
    let read: ChatToolActivity.OutputRead?
    let missingOutputText: String?
    let actions: ChatFileActions

    var body: some View {
        let diff = ChatFileDiff(file.keeping(ChatFileChanges.rowLimits))
        let footer = ChatFileDiffFooter(file: file, read: read, missingOutputText: missingOutputText)
        VStack(alignment: .leading, spacing: 6) {
            if !diff.hunks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ChatFileDiffRows(diff: diff)
                }
                .clipShape(.rect(cornerRadius: 8))
            }
            if footer != .empty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let more = footer.moreLines {
                            Text(verbatim: more)
                        }
                        if let status = footer.status {
                            Text(verbatim: status)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    switch footer.action {
                    case .viewAll?:
                        Button("View All") { actions.showAll(file.path) }
                            .font(.caption.weight(.semibold))
                    case .tryAgain?:
                        Button("Try Again", action: actions.retry)
                            .font(.caption.weight(.semibold))
                    case nil:
                        EmptyView()
                    }
                }
            }
        }
    }
}

/// What follows a changed file's diff in its row: how many lines it leaves
/// out, how reading them stands, and what the user can do.
struct ChatFileDiffFooter: Equatable {
    enum Action: Equatable {
        /// The sheet shows more than the row: lines past its limits, or the
        /// rest of a line it cut.
        case viewAll
        /// The read failed in a way that reading again could fix.
        case tryAgain
    }

    var moreLines: String?
    var status: String?
    var action: Action?

    static let empty = ChatFileDiffFooter()

    private init() {}

    init(file: ChatFileChange, read: ChatToolActivity.OutputRead?, missingOutputText: String?) {
        let shown = file.keeping(ChatFileChanges.rowLimits)
        let hidden = max(file.lineCount - shown.heldLineCount, 0)
        if hidden > 0 { moreLines = "… \(hidden) more \(hidden == 1 ? "line" : "lines")" }
        let canShowAll = shown.heldLineCount < file.heldLineCount || shown.isLineCut && !file.isLineCut
        if canShowAll { action = .viewAll }
        guard !file.isComplete else { return }
        switch read {
        case nil:
            // Every open file that lacks lines asks for them; a row that
            // can't be read has no text.
            status = missingOutputText
        case .loading?:
            status = "Loading output…"
        case .read?:
            break
        case .failed(let message)?:
            status = message
            if !canShowAll { action = .tryAgain }
        case .unavailable(let message)?:
            status = message
        }
    }
}

/// A diff's hunks, one numbered line per row, with the unchanged lines
/// between hunks counted. Put in a stack: a lazy one loads lines as they
/// scroll in.
struct ChatFileDiffRows: View {
    let diff: ChatFileDiff

    var body: some View {
        ForEach(diff.hunks) { hunk in
            if let gap = hunk.unchangedBefore {
                ChatDiffGap(count: gap)
            }
            ForEach(hunk.diff.lines) { line in
                DiffLineRow(
                    line: line, numbers: [ChatFileDiff.number(of: line)], numberDigits: diff.numberDigits,
                    gutterLeading: DiffLayoutPolicy.numberSpacing, wordChanges: diff.wordChanges[line.id] ?? [])
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.accessibilityLabel)
            }
        }
    }
}

/// The unchanged lines between two hunks.
private struct ChatDiffGap: View {
    let count: Int

    var body: some View {
        Text(verbatim: "⋯ " + FileDiffHunkBand.unchangedSummary(count))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(Color(uiColor: DiffPalette.hunkText))
            .padding(.horizontal, DiffLayoutPolicy.numberSpacing)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: DiffPalette.hunkBand))
    }
}

/// A changed file's whole diff, as far as its row holds it, on a screen of
/// its own.
struct ChatFileDiffSheet: View {
    let file: ChatFileChange
    let path: String

    var body: some View {
        let diff = ChatFileDiff(file)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Text(file.kind.label).foregroundStyle(.secondary)) \(Text(verbatim: path).fontDesign(.monospaced))")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChatDiffBadge(diff: ChatDiffStats(added: file.added, removed: file.removed))
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                ChatFileDiffRows(diff: diff)
                if diff.hiddenLines > 0 {
                    Text(verbatim: "… \(diff.hiddenLines) more \(diff.hiddenLines == 1 ? "line" : "lines")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            }
        }
        .background(Color(uiColor: DiffPalette.background))
        .accessibilityIdentifier("chat.file-diff")
    }
}

/// Shows a changed file's whole diff in a sheet, as Select Text does.
@MainActor
enum ChatFileDiffPresenter {
    static func present(_ file: ChatFileChange, path: String, from sourceView: UIView) {
        guard let presenting = sourceView.nearestPresentingViewController else { return }
        let host = UIHostingController(rootView: ChatFileDiffSheet(file: file, path: path))
        host.title = (path as NSString).lastPathComponent
        host.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak host] _ in host?.dismiss(animated: true) })
        let navigation = UINavigationController(rootViewController: host)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        presenting.present(navigation, animated: true)
    }
}
