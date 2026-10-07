import SwiftUI

/// One file's lazy read. Pulling and retrying belong to this file, not the
/// Checkout's list, and leaving cancels every read owned by the presentation.
struct FileDiffView: View {
    let store: FileDiffStore
    @State private var action: Task<Void, Never>?

    var body: some View {
        ZStack {
            switch store.phase {
            case .loading:
                ProgressView("Reading Diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let patch):
                FileDiffDocumentView(
                    patch: patch, file: store.file, refreshError: store.refreshError
                ) {
                    FileDiffFooter(store: store) {
                        action = Task { await store.loadMore() }
                    }
                }
                .refreshable { await store.refresh() }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Read Diff", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        action = Task { await store.refresh() }
                    }
                    .disabled(store.isRefreshing)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom) {
            if case .loaded = store.phase, let readAt = store.readAt {
                FileDiffListChangeNotice(
                    change: store.listChange, readAt: readAt, isRefreshing: store.isRefreshing
                ) {
                    action = Task { await store.reload() }
                }
            }
        }
        .task { await store.appear() }
        .onDisappear {
            action?.cancel()
            store.cancel()
        }
    }
}

/// Flattening the document makes each line a direct lazy child: one large
/// hunk must not cause SwiftUI to lay out every line when its header appears.
private struct FileDiffDocumentView<Footer: View>: View {
    let patch: FilePatch
    /// The Changes list's file: its kind, staging, and line counts.
    let file: ChangedFile
    let refreshError: String?
    let footer: Footer
    private let rows: [Row]
    private let pairedRows: [Row]
    private let pairRowIDByLineID: [Int: Int]
    private let wordChanges: [Int: [Range<Int>]]
    private let numberDigits: Int
    @Namespace private var rotor
    @Environment(\.diffLayoutSettings) private var injectedSettings
    @ScaledMetric(relativeTo: .footnote) private var columnWidth: CGFloat =
        DiffLayoutPolicy.defaultColumnWidth
    @ScaledMetric(relativeTo: .caption2) private var digitWidth: CGFloat =
        DiffLayoutPolicy.defaultDigitWidth
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat =
        DiffLayoutPolicy.defaultGlyphWidth
    @State private var usableWidth: CGFloat?
    /// Not observable: writing it as the user scrolls would rebuild every row.
    @State private var anchor = DiffScrollAnchor<Row.ID>()
    /// Not observable, for the same reason.
    @State private var endRecovery = DiffEndRecovery<Row.ID>()

    init(
        patch: FilePatch, file: ChangedFile, refreshError: String?,
        @ViewBuilder footer: () -> Footer
    ) {
        self.patch = patch
        self.file = file
        self.refreshError = refreshError
        self.footer = footer()
        var rows: [Row] = []
        var maximumNumber = 1
        var wordChanges: [Int: [Range<Int>]] = [:]
        for file in patch.files {
            rows.append(.file(file))
            for (index, hunk) in file.hunks.enumerated() {
                rows.append(.hunk(hunk, unchangedBefore: file.unchangedLinesBefore(hunkAt: index)))
                wordChanges.merge(DiffWordChanges.ranges(in: hunk)) { _, new in new }
                for line in hunk.lines {
                    rows.append(.line(line))
                    maximumNumber = max(maximumNumber, max(line.oldNumber ?? 0, line.newNumber ?? 0))
                }
            }
        }
        self.rows = rows
        self.wordChanges = wordChanges
        numberDigits = String(maximumNumber).count
        var paired: [Row] = []
        var lineMap: [Int: Int] = [:]
        for file in patch.files {
            paired.append(.file(file))
            for (index, hunk) in file.hunks.enumerated() {
                paired.append(.hunk(hunk, unchangedBefore: file.unchangedLinesBefore(hunkAt: index)))
                for side in SideBySideDiff.rows(for: hunk) {
                    paired.append(.pair(side))
                    if let left = side.left { lineMap[left.id] = side.id }
                    if let right = side.right { lineMap[right.id] = side.id }
                }
            }
        }
        self.pairedRows = paired
        self.pairRowIDByLineID = lineMap
    }

    var body: some View {
        let decision = self.decision
        // Freeze the remembered line before this pass replaces row heights.
        // The next frame sample would otherwise record whichever line now
        // sits at the old content offset.
        let _ = anchor.holdIfChanging(
            layoutKey: decision.layout.rawValue, width: usableWidth, columnWidth: columnWidth)
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let refreshError {
                        Text(refreshError)
                            .font(.callout)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground))
                    }
                    if rows.isEmpty {
                        Text("No changes in this file.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(decision.layout == .sideBySide ? pairedRows : rows) { row in
                        // Keep one concrete lazy child even when reference
                        // menus change the row's conditional view structure.
                        VStack(alignment: .leading, spacing: 0) {
                            rowView(row)
                        }
                        .anchorPreference(key: DiffLineFramesKey.self, value: .bounds) { frame in
                            lineFrameAnchor(for: row, frame)
                        }
                        .id(row.id)
                    }
                    footer
                }
                .scrollTargetLayout()
                .coordinateSpace(.named(DiffHatch.coordinateSpace))
                // The rows' own width. Deriving it from the scroll view's
                // safe area counted a sidebar beside the diff twice: the
                // view already excluded it and still reported it as inset.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { usableWidth = $0 }
            }
            .accessibilityIdentifier("file-diff-scroll")
            .backgroundPreferenceValue(DiffLineFramesKey.self) { anchors in
                GeometryReader { proxy in
                    // The reader's origin is the unobscured edge `scrollTo` uses.
                    // `safeAreaInsets.top` still reports the bar, and adding it
                    // selects the next row.
                    let probe: CGFloat = 4
                    let inspection = DiffLineFrames.inspect(
                        in: anchors, probe: probe, pendingLine: anchor.pendingLine, proxy: proxy)
                    let _ = anchor.observe(
                        line: inspection.line.map(Row.ID.line),
                        pendingFrame: inspection.pendingFrame,
                        probe: probe,
                        readerHeight: proxy.size.height)
                    let _ = endRecovery.noteLines(realized: !anchors.isEmpty, lastLine: lastLineRowID)
                    Color.clear
                        .allowsHitTesting(false)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { _, height in
                anchor.noteContainerHeight(height)
            }
            .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 1
                    ? geometry.contentSize.height : nil
            } action: { _, height in
                endRecovery.noteEnd(contentHeight: height)
            }
            .onAppear {
                anchor.adopt(scroll)
                endRecovery.adopt(scroll)
            }
            .onChange(of: decision.layout) { _, layout in
                keepTopLine(for: layout, proxy: scroll)
            }
            .onChange(of: usableWidth) { old, new in
                guard let old, let new, abs(new - old) >= 1 else {
                    anchor.adopt(scroll)
                    return
                }
                keepTopLine(for: resolvedLayout(usableWidth: new, columnWidth: columnWidth), proxy: scroll)
            }
            .onChange(of: columnWidth) { _, columnWidth in
                guard let usableWidth else { return }
                keepTopLine(
                    for: resolvedLayout(usableWidth: usableWidth, columnWidth: columnWidth),
                    proxy: scroll)
            }
            .animation(nil, value: decision.layout)
            .accessibilityRotor("Hunks") {
                ForEach(patch.files) { file in
                    ForEach(file.hunks) { hunk in
                        AccessibilityRotorEntry(Text(hunk.title), id: Row.ID.hunk(hunk.id), in: rotor) {
                            scroll.scrollTo(Row.ID.hunk(hunk.id), anchor: .top)
                        }
                    }
                }
            }
            .accessibilityRotor("Files") {
                ForEach(patch.files) { file in
                    AccessibilityRotorEntry(
                        Text(file.newPath ?? file.oldPath ?? "File"),
                        id: Row.ID.file(file.id), in: rotor
                    ) {
                        scroll.scrollTo(Row.ID.file(file.id), anchor: .top)
                    }
                }
            }
            .toolbar {
                if decision.toggle != .hidden {
                    ToolbarItem(placement: .topBarTrailing) {
                        Picker("Diff Layout", selection: layoutSelection) {
                            ForEach(DiffLayout.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        // Content width; unbounded, it fills the bar's free space.
                        .fixedSize()
                        .accessibilityIdentifier("diff-layout-picker")
                    }
                    // The segmented control draws its own capsule; the bar's
                    // shared glass around it would add a second, offset rim.
                    .toolbarItemBackground(.hidden)
                }
            }
        }
    }

    /// Line and pair rows publish the frame that tracks the readable edge.
    /// File and hunk headers publish nothing.
    private func lineFrameAnchor(for row: Row, _ frame: Anchor<CGRect>) -> [Int: Anchor<CGRect>] {
        switch row {
        case .line(let line): [line.id: frame]
        case .pair(let pair): [pair.id: frame]
        case .file, .hunk: [:]
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .pair(let pair):
            FileDiffSideBySideRow(row: pair, numberDigits: numberDigits, wordChanges: wordChanges)
        case .file(let diffFile):
            fileBar(diffFile)
                .accessibilityAddTraits(.isHeader)
                .accessibilityRotorEntry(id: row.id, in: rotor)
                .diffFileReferenceMenu(diffFile)
        case .hunk(let hunk, let unchangedBefore):
            FileDiffHunkBand(hunk: hunk, unchangedLinesBefore: unchangedBefore)
                .accessibilityAddTraits(.isHeader)
                .accessibilityRotorEntry(id: row.id, in: rotor)
                .diffHunkReferenceMenu(hunk)
        case .line(let line):
            DiffLineRow(
                line: line, numbers: [line.oldNumber, line.newNumber], numberDigits: numberDigits,
                gutterLeading: DiffLayoutPolicy.numberSpacing,
                wordChanges: wordChanges[line.id] ?? [])
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.accessibilityLabel)
                .accessibilityIdentifier("file-diff-line-\(line.id)")
                .diffLineContextMenu(line)
                .diffLineAccessibilityActions(line)
        }
    }

    /// The list's file describes a one-file patch. An edited rename that
    /// git split in two describes each side from the patch itself.
    private func fileBar(_ diffFile: DiffFile) -> FileDiffFileBar {
        let isWholePatch = patch.files.count == 1
        let kind: ChangedFile.Kind =
            if isWholePatch { file.kind }
            else if diffFile.oldPath == nil { .added }
            else if diffFile.newPath == nil { .deleted }
            else { .modified }
        let detail = isWholePatch
            ? file.detail
            : ([kind.title] + [file.staging?.title].compactMap(\.self)).joined(separator: " · ")
        let counts: LineCounts? =
            if diffFile.isBinary { nil }
            else if isWholePatch, let lineCounts = file.lineCounts { lineCounts }
            else if patch.isTruncated { nil }
            else { diffFile.lineCounts }
        return FileDiffFileBar(
            path: diffFile.newPath ?? diffFile.oldPath ?? "File", kind: kind, detail: detail,
            summary: diffFile.summary ?? (diffFile.isBinary ? "Binary file." : nil),
            lineCounts: counts, showsPath: !isWholePatch)
    }

    private enum Row: Identifiable {
        enum ID: Hashable {
            case file(Int)
            case hunk(Int)
            case line(Int)
        }

        case file(DiffFile)
        case hunk(DiffHunk, unchangedBefore: Int?)
        case line(DiffLine)
        case pair(SideBySideRow)

        var id: ID {
            switch self {
            case .file(let file): .file(file.id)
            case .hunk(let hunk, _): .hunk(hunk.id)
            case .line(let line): .line(line.id)
            case .pair(let pair): .line(pair.id)
            }
        }
    }

    private var settings: DiffLayoutSettings {
        injectedSettings ?? .shared
    }

    private var decision: DiffLayoutDecision {
        let settings = settings
        guard settings.offersSideBySide else {
            return DiffLayoutDecision(layout: .unified, toggle: .hidden)
        }
        let preference = settings.layout
        guard let usableWidth else {
            return DiffLayoutDecision(layout: .unified, toggle: .hidden)
        }
        return DiffLayoutPolicy.resolve(
            preference: preference,
            offersSideBySide: true,
            usableWidth: usableWidth,
            columnWidth: columnWidth,
            digitWidth: digitWidth,
            glyphWidth: glyphWidth,
            numberDigits: numberDigits)
    }

    private var layoutSelection: Binding<DiffLayout> {
        let settings = settings
        return Binding(get: { settings.layout }, set: { settings.select($0) })
    }

    /// The last row that shows code, in the layout on screen.
    private var lastLineRowID: Row.ID? {
        (decision.layout == .sideBySide ? pairedRows : rows).last { row in
            switch row {
            case .line, .pair: true
            case .file, .hunk: false
            }
        }?.id
    }

    /// A side-by-side row id is already a unified line id. The other way
    /// maps whichever line is at the top onto the pair that shows it.
    private func anchorTarget(for remembered: Row.ID, layout: DiffLayout) -> Row.ID {
        guard layout == .sideBySide, case .line(let lineID) = remembered,
            let pairID = pairRowIDByLineID[lineID]
        else { return remembered }
        return .line(pairID)
    }

    private func resolvedLayout(usableWidth: CGFloat, columnWidth: CGFloat) -> DiffLayout {
        DiffLayoutPolicy.resolve(
            preference: settings.layout,
            offersSideBySide: settings.offersSideBySide,
            usableWidth: usableWidth,
            columnWidth: columnWidth,
            digitWidth: digitWidth,
            glyphWidth: glyphWidth,
            numberDigits: numberDigits
        ).layout
    }

    private func keepTopLine(for layout: DiffLayout, proxy: ScrollViewProxy) {
        anchor.adopt(proxy)
        guard anchor.needsRestore, let top = anchor.top else { return }
        let target = anchorTarget(for: top, layout: layout)
        guard case .line(let line) = target else {
            anchor.cancelRestore()
            return
        }
        anchor.restore(target, line: line)
    }

}

/// Bounds of the realized diff lines, in the scroll view's coordinates.
/// Only rows on screen publish one, so a long file does not record every line.
private struct DiffLineFramesKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private enum DiffLineFrames {
    struct Inspection {
        var line: Int?
        var pendingFrame: CGRect?
    }

    /// The line whose frame contains the probe, plus the pending row's frame.
    static func inspect(
        in anchors: [Int: Anchor<CGRect>],
        probe: CGFloat,
        pendingLine: Int?,
        proxy: GeometryProxy
    ) -> Inspection {
        var bestID: Int?
        var bestMinY = CGFloat.greatestFiniteMagnitude
        var pendingFrame: CGRect?
        for (id, anchor) in anchors {
            let frame = proxy[anchor]
            if id == pendingLine {
                pendingFrame = frame
            }
            guard frame.minY <= probe, frame.maxY > probe, frame.minY < bestMinY else { continue }
            bestMinY = frame.minY
            bestID = id
        }
        return Inspection(line: bestID, pendingFrame: pendingFrame)
    }
}

/// SwiftUI's lazy stack on iOS 26 can leave the viewport past its last row.
/// Rows it has not measured count at an estimated height; when the real rows
/// are shorter, a jump to the end of that estimate (the scroll indicator
/// dragged to the bottom) lands below every row. Nothing is then realized, so
/// nothing is measured and the estimate never shrinks: the diff stays blank
/// until the reader scrolls back up. Seen as a scroll to the end with no line
/// publishing a frame, and ended by scrolling the last line into view, which
/// measures it. Measured on the iOS 26.5 simulator, not on iOS 27.
@MainActor
private final class DiffEndRecovery<ID: Hashable> {
    private var proxy: ScrollViewProxy?
    private var linesRealized = true
    private var lastLine: ID?
    /// The content height while the viewport reaches its end, else nil.
    private var endHeight: CGFloat?
    /// One recovery per content height, so an estimate the scroll cannot
    /// correct is not retried every frame.
    private var recoveredHeight: CGFloat?
    private var isScheduled = false

    func adopt(_ proxy: ScrollViewProxy) {
        self.proxy = proxy
    }

    func noteLines(realized: Bool, lastLine: ID?) {
        linesRealized = realized
        self.lastLine = lastLine
        schedule()
    }

    func noteEnd(contentHeight: CGFloat?) {
        endHeight = contentHeight
        schedule()
    }

    /// The two signals arrive in either order within one update; the check
    /// waits for both.
    private func schedule() {
        guard !linesRealized, endHeight != nil, !isScheduled else { return }
        isScheduled = true
        Task { [weak self] in
            await Task.yield()
            self?.recover()
        }
    }

    private func recover() {
        isScheduled = false
        guard !linesRealized, let endHeight, endHeight != recoveredHeight,
            let proxy, let lastLine
        else { return }
        recoveredHeight = endHeight
        proxy.scrollTo(lastLine, anchor: .bottom)
    }
}

/// Topmost row. Not observable: publishing it would rebuild every line.
///
/// The remembered line is the one crossing the readable edge, below the top
/// chrome, sampled into this class without invalidating the view. A layout
/// change scrolls that row back. The first jump uses estimated heights; the
/// next settled frames nudge it until the row contains the probe again.
/// A restore always clears, including when its target never appears.
@MainActor
private final class DiffScrollAnchor<ID: Hashable> {
    var top: ID?
    var needsRestore = false
    private(set) var pendingLine: Int?
    private var proxy: ScrollViewProxy?
    private var pending: ID?
    private var live: ID?
    private var generation = 0
    private var frozen = false
    private var seenLayout: String?
    private var seenWidth: CGFloat?
    private var seenColumn: CGFloat?
    private var containerHeight: CGFloat = 0
    private var sampleToken = 0
    private var sampleProbe: CGFloat = 0
    private var sampleContainerHeight: CGFloat = 0
    private var samplePendingFrame: CGRect?
    private var correctionAnchorY: CGFloat = 0

    func adopt(_ proxy: ScrollViewProxy) {
        self.proxy = proxy
    }

    func noteContainerHeight(_ height: CGFloat) {
        guard height > 1 else { return }
        containerHeight = height
    }

    /// Freeze the line sampled before this pass once a real width is on screen.
    /// The first resolved width is the appearance transition, not a switch.
    func holdIfChanging(layoutKey: String, width: CGFloat?, columnWidth: CGFloat) {
        let hadWidth = seenWidth != nil
        let layoutChanged = seenLayout != nil && seenLayout != layoutKey
        let widthChanged: Bool
        if let seenWidth, let width {
            widthChanged = abs(width - seenWidth) >= 1
        } else {
            widthChanged = false
        }
        let columnChanged = seenColumn.map { abs(columnWidth - $0) >= 0.01 } ?? false
        if hadWidth, layoutChanged || widthChanged || columnChanged {
            if !frozen, let live {
                top = live
                frozen = true
                needsRestore = true
            } else if frozen, top != nil {
                // A second switch can arrive before the first restore confirms.
                needsRestore = true
            }
        }
        seenLayout = layoutKey
        if let width { seenWidth = width }
        seenColumn = columnWidth
    }

    /// Latest probe sample. Ignored while a restore is in flight so the new
    /// layout cannot replace the line captured at the change. A sample with
    /// no line means a header is on the edge, so the remembered line is cleared
    /// and a later switch does not scroll back to it.
    func observe(line: ID?, pendingFrame: CGRect?, probe: CGFloat, readerHeight: CGFloat) {
        sampleToken &+= 1
        sampleProbe = probe
        sampleContainerHeight = containerHeight > 1 ? containerHeight : readerHeight
        samplePendingFrame = pendingFrame
        guard !frozen else { return }
        guard let line else {
            live = nil
            top = nil
            return
        }
        live = line
        top = line
    }

    func cancelRestore() {
        generation += 1
        endRestore(generation)
    }

    func restore(_ target: ID, line: Int) {
        top = target
        pending = target
        pendingLine = line
        frozen = true
        needsRestore = false
        correctionAnchorY = 0
        generation += 1
        let generation = generation
        Task { [weak self] in
            await self?.finishRestore(generation)
        }
    }

    private func finishRestore(_ generation: Int) async {
        await Task.yield()
        guard self.generation == generation, pending != nil else { return }
        let tokenBeforeScroll = sampleToken
        scrollPending(anchorY: 0)
        try? await Task.sleep(for: .milliseconds(48))
        guard self.generation == generation, pending != nil else { return }
        var lastMinY: CGFloat?
        var corrections = 0
        var coarseRetries = 0
        var holdStreak = 0
        for _ in 0..<24 {
            guard self.generation == generation, pending != nil else { return }
            if samplePendingFrame == nil, coarseRetries < 5, holdStreak == 0, corrections == 0 {
                scrollPending(anchorY: 0)
                coarseRetries += 1
            }
            try? await Task.sleep(for: .milliseconds(32))
            guard self.generation == generation, pending != nil else { return }
            // Preferences stop once the jump lands. Re-read that same frame
            // so two stable samples can finish without another invalidation.
            guard sampleToken != tokenBeforeScroll else { continue }
            guard let frame = samplePendingFrame,
                frame.height > 1,
                sampleContainerHeight > frame.height + 1
            else { continue }
            let probe = sampleProbe
            let holds = frame.minY <= probe && frame.maxY > probe
            if holds {
                holdStreak += 1
                if holdStreak >= 2 {
                    endRestore(generation)
                    return
                }
                lastMinY = frame.minY
                continue
            }
            holdStreak = 0
            let settled = lastMinY.map { abs(frame.minY - $0) < 0.5 } ?? false
            lastMinY = frame.minY
            guard settled, corrections < 4 else { continue }
            let desiredMinY = probe - min(CGFloat(8), frame.height * 0.5)
            let span = sampleContainerHeight - frame.height
            guard span > 1, desiredMinY.isFinite, frame.minY.isFinite else { continue }
            correctionAnchorY -= (frame.minY - desiredMinY) / span
            correctionAnchorY = min(max(correctionAnchorY, -0.25), 1.25)
            corrections += 1
            lastMinY = nil
            scrollPending(anchorY: correctionAnchorY)
        }
        endRestore(generation)
    }

    private func endRestore(_ generation: Int) {
        guard self.generation == generation else { return }
        pending = nil
        pendingLine = nil
        frozen = false
        needsRestore = false
        if let live { top = live }
    }

    private func scrollPending(anchorY: CGFloat) {
        guard let proxy, let pending else { return }
        withTransaction(Transaction(animation: nil)) {
            proxy.scrollTo(pending, anchor: UnitPoint(x: 0.5, y: anchorY))
        }
    }
}

/// One footer is the integration point for the file's line counts. All
/// too-large wording, including its accessibility text, comes from the store.
private struct FileDiffFooter: View {
    let store: FileDiffStore
    let loadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.truncation == .canLoadMore {
                Text("Showing the first part of this diff.")
                    .foregroundStyle(.secondary)
                Button("Load More", action: loadMore)
                    .disabled(store.isRefreshing)
            } else if store.truncation == .tooLarge {
                Text(store.tooLargeMessage)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(store.tooLargeMessage)
            }
            if store.isRefreshing {
                ProgressView("Refreshing Diff…")
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
