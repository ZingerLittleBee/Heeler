import SwiftUI
import UIKit

/// What the timeline tells its owner.
struct ChatTimelineActions {
    var loadOlder: @MainActor () -> Void = {}
    /// Whether the list follows its newest row; drives Jump to Latest.
    var followingChanged: @MainActor (Bool) -> Void = { _ in }
    /// The first layout that shows content, positioned at its end.
    var firstPositionedLayout: @MainActor () -> Void = {}
    /// An expanded tool row has no output to show, or only its start.
    var loadOutput: @MainActor (ChatEntryID) -> Void = { _ in }
    /// Shown in an expanded tool row whose output was never read.
    var missingOutputText: String = "Output is available when connected."
}

/// Hands a row's interactions back to the controller that owns the list.
struct ChatRowActions {
    var toggle: @MainActor (ChatRowID) -> Void
    var loadOlder: @MainActor () -> Void
    var copy: @MainActor (String) -> Void
    var selectText: @MainActor (String) -> Void
    var missingOutputText: String
    /// Opens or closes one changed file's diff, by its recorded path.
    var toggleFile: @MainActor (ChatRowID, String) -> Void = { _, _ in }
    /// Shows one changed file's whole diff.
    var showFile: @MainActor (ChatRowID, String) -> Void = { _, _ in }
    /// Tries a failed output read again.
    var retryOutput: @MainActor (ChatRowID) -> Void = { _ in }
}

/// The Chat timeline: a collection view of hosted SwiftUI rows that opens at
/// its newest row and stays there while it follows (`ChatFollowLatch`).
///
/// Updates keep the reader's place: a following list is pinned to its end
/// on every layout; otherwise the first visible row that survives the update
/// is put back where it was, which also covers older history arriving above.
@MainActor
final class ChatTimelineController: UIViewController, UICollectionViewDelegate {
    var actions: ChatTimelineActions

    private enum ScrollAnchor {
        case end
        /// Rows on screen, top first, with their top edge's distance from
        /// the visible top. The first one still present after an update
        /// is restored.
        case rows([(ChatRowID, CGFloat)])
    }

    private let layout = ChatTimelineLayout()
    private lazy var collectionView = ChatCollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, ChatRowID>?
    private var applied: ChatTimelineState?
    /// Every built row, folded ones included, so what a folded row has
    /// open survives its fold.
    private var allRows: [ChatRowID: ChatRow] = [:]
    /// The rows the list shows: built rows a fold leaves out of view are
    /// absent, and fold and group headers are present.
    private var rowsByID: [ChatRowID: ChatRow] = [:]
    /// Each folded row, by the shown header that holds it.
    private var owners: [ChatRowID: ChatRowID] = [:]
    /// Turn and group headers the reader opened. Never kept past the
    /// conversation, so every finished turn opens folded.
    private var openHeaders: Set<ChatRowID> = []
    private var expanded: Set<ChatRowID> = []
    /// The changed files whose diffs are open, by recorded path.
    private var expandedFiles: [ChatRowID: Set<String>] = [:]
    /// Bumped from one counter whenever a row opens or closes anything, so
    /// a height measured before can't pass for the new layout.
    private var disclosures: [ChatRowID: Int] = [:]
    private var lastDisclosure = 0
    private var latch = ChatFollowLatch()
    private var reportedFollowing = true
    private var isJumpAnimating = false
    private var hasReportedFirstLayout = false
    /// The older-history state the last automatic request was made in, so
    /// one approach to the top asks once.
    private var requestedOlderAtRowCount: Int?

    /// Whether the list follows its end, for tests.
    var isFollowing: Bool { latch.isFollowing }
    var timeline: ChatCollectionView { collectionView }
    var geometry: ChatTimelineGeometry { layout.geometry }

    /// Where a row's cell sits in the content, for tests; nil off screen.
    func cellFrame(of id: ChatRowID) -> CGRect? {
        guard let index = layout.index(of: id) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0))?.frame
    }

    /// The rows with cells on screen, top first, for tests.
    var visibleRowIDs: [ChatRowID] {
        collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .compactMap { layout.id(at: $0.item) }
    }

    init(actions: ChatTimelineActions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The rows' breathing room inside the list's edges.
    private static let contentInsets = UIEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)

    override func loadView() {
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = Self.contentInsets
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.keyboardDismissMode = .none
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.accessibilityIdentifier = "chat.timeline"
        collectionView.delegate = self
        collectionView.shouldPin = { [weak self] in
            guard let self else { return false }
            return latch.isFollowing && !isJumpAnimating
        }
        layout.itemIDs = { [weak self] in self?.dataSource?.snapshot().itemIdentifiers ?? [] }
        layout.rowInfo = { [weak self] id in
            guard let self, let row = rowsByID[id] else { return nil }
            // What is open, and where the row sits, make a different
            // measurement of the same content.
            var key = Hasher()
            key.combine(row.revision)
            key.combine(disclosures[id] ?? 0)
            key.combine(row.topSpacing)
            key.combine(row.isNested)
            return (row.seed, key.finalize())
        }
        layout.isFollowing = { [weak self] in self?.latch.isFollowing ?? true }

        let registration = UICollectionView.CellRegistration<ChatHostingCell, ChatRowID> {
            [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            let isExpanded = expanded.contains(id)
            let files = expandedFiles[id] ?? []
            let actions = rowActions
            cell.contentConfiguration = UIHostingConfiguration {
                ChatRowView(row: row, isExpanded: isExpanded, expandedFiles: files, actions: actions)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        view = collectionView
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: Self, _: UITraitCollection) in
            self.layout.invalidateLayout()
        }
    }

    private var rowActions: ChatRowActions {
        ChatRowActions(
            toggle: { [weak self] id in self?.toggle(id) },
            loadOlder: { [weak self] in self?.actions.loadOlder() },
            copy: { text in UIPasteboard.general.string = text },
            selectText: { [weak self] text in self?.selectText(text) },
            missingOutputText: actions.missingOutputText,
            toggleFile: { [weak self] id, path in self?.toggleFile(id, path: path) },
            showFile: { [weak self] id, path in self?.showFile(id, path: path) },
            retryOutput: { [weak self] id in self?.retryOutput(id) })
    }

    // MARK: Updates

    func apply(_ state: ChatTimelineState) {
        loadViewIfNeeded()
        guard let dataSource else { return }
        if let applied, applied.generation == state.generation, applied.revision == state.revision {
            return
        }
        let previous = applied
        let oldRows = rowsByID
        applied = state
        allRows = Dictionary(state.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        guard let previous, previous.generation == state.generation else {
            expanded = []
            expandedFiles = [:]
            disclosures = [:]
            openHeaders = []
            requestedOlderAtRowCount = nil
            latch.reset()
            noteFollowing()
            let snapshot = projectedSnapshot()
            UIView.performWithoutAnimation {
                dataSource.applySnapshotUsingReloadData(snapshot)
                collectionView.layoutIfNeeded()
                pinToEnd()
            }
            forgetMeasurements()
            reportFirstLayoutIfReady()
            return
        }

        let anchor = captureAnchor()
        expanded.formIntersection(allRows.keys)
        expandedFiles = expandedFiles.filter { allRows[$0.key] != nil }
        disclosures = disclosures.filter { allRows[$0.key] != nil }
        openHeaders = openHeaders.filter { header in
            switch header {
            case .turn(let id), .group(let id), .liveGroup(let id): allRows[.entry(id)] != nil
            case .liveTurn, .entry, .pending, .olderHistory: false
            }
        }
        var snapshot = projectedSnapshot()
        let changed = changedRows(since: oldRows, in: snapshot)
        snapshot.reconfigureItems(changed)
        // A row expanded while it ran may have output now, and one a fold
        // gave back may never have read it. The request waits for this
        // update to finish, since it changes what the list is built from.
        let wanting = (changed + revealedRows(since: oldRows, in: snapshot)).filter { wantsOutput($0, retrying: false) }
        if !wanting.isEmpty {
            Task { @MainActor [weak self] in
                for id in wanting { self?.requestOutput(id) }
            }
        }
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            restore(anchor)
        }
        forgetMeasurements()
        reportFirstLayoutIfReady()
    }

    /// Folds the applied rows as the open headers say, and makes the
    /// result what the list shows.
    private func projectedSnapshot() -> NSDiffableDataSourceSnapshot<Int, ChatRowID> {
        let output = ChatTimelineProjection.project(
            applied?.rows ?? [], turns: applied?.turns ?? [], signals: applied?.signals ?? ChatTurnSignals(),
            open: openHeaders)
        rowsByID = Dictionary(output.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        owners = output.owners
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatRowID>()
        snapshot.appendSections([0])
        snapshot.appendItems(uniqueIDs(output.rows))
        return snapshot
    }

    /// Shown rows whose content, place or style changed.
    private func changedRows(
        since oldRows: [ChatRowID: ChatRow], in snapshot: NSDiffableDataSourceSnapshot<Int, ChatRowID>
    ) -> [ChatRowID] {
        snapshot.itemIdentifiers.filter { id in
            guard let old = oldRows[id], let row = rowsByID[id] else { return false }
            return old.revision != row.revision || old.placement != row.placement
        }
    }

    /// Shown rows the list did not show before.
    private func revealedRows(
        since oldRows: [ChatRowID: ChatRow], in snapshot: NSDiffableDataSourceSnapshot<Int, ChatRowID>
    ) -> [ChatRowID] {
        snapshot.itemIdentifiers.filter { oldRows[$0] == nil }
    }

    /// Keeps the heights of folded rows too, so opening a fold again lays
    /// out what was measured rather than guesses.
    private func forgetMeasurements() {
        layout.forgetMeasurements(keeping: Set(allRows.keys).union(rowsByID.keys))
    }

    /// Keeps `height` at the top clear of rows at rest, for chrome that
    /// floats over the list's top edge; rows still scroll beneath it. A list
    /// resting at its top stays there.
    func setTopObstruction(_ height: CGFloat) {
        loadViewIfNeeded()
        let top = Self.contentInsets.top + height
        guard collectionView.contentInset.top != top else { return }
        let wasAtTop = collectionView.contentOffset.y <= collectionView.minOffsetY + 0.5
        collectionView.contentInset.top = top
        collectionView.verticalScrollIndicatorInsets.top = height
        if wasAtTop, !latch.isFollowing {
            collectionView.contentOffset.y = collectionView.minOffsetY
        }
        collectionView.setNeedsLayout()
    }

    private func uniqueIDs(_ rows: [ChatRow]) -> [ChatRowID] {
        var seen = Set<ChatRowID>()
        return rows.map(\.id).filter { seen.insert($0).inserted }
    }

    /// Back to the newest row and following, as after a send. Waits for the
    /// layout the send's inset changes cause before pinning.
    func followLatest() {
        latch.reset()
        noteFollowing()
        collectionView.setNeedsLayout()
    }

    /// Jump to Latest: animates from nearby, and first lands one screen
    /// above the end from far away, so no blank screen of unmeasured rows
    /// scrolls past.
    func jumpToLatest() {
        latch.reset()
        noteFollowing()
        collectionView.layoutIfNeeded()
        let end = collectionView.maxOffsetY
        if end - collectionView.contentOffset.y > 2 * collectionView.bounds.height {
            collectionView.contentOffset.y = max(collectionView.minOffsetY, end - collectionView.bounds.height)
            collectionView.layoutIfNeeded()
        }
        if UIAccessibility.isReduceMotionEnabled {
            pinToEnd()
            return
        }
        isJumpAnimating = true
        collectionView.setContentOffset(CGPoint(x: 0, y: collectionView.maxOffsetY), animated: true)
    }

    private func captureAnchor() -> ScrollAnchor {
        if latch.isFollowing { return .end }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height
        let range = layout.geometry.indices(from: visibleTop, to: visibleBottom)
        let rows = range.compactMap { index -> (ChatRowID, CGFloat)? in
            guard let id = layout.id(at: index) else { return nil }
            return (id, layout.geometry.minY(at: index) - visibleTop)
        }
        return rows.isEmpty ? .end : .rows(rows)
    }

    private func restore(_ anchor: ScrollAnchor) {
        switch anchor {
        case .end:
            pinToEnd()
        case .rows(let rows):
            // A row a fold took away puts its header where it was, or at
            // the top when the row started above it.
            let candidates = rows + rows.compactMap { id, offset in owners[id].map { ($0, max(offset, 0)) } }
            for (id, offset) in candidates {
                guard let index = layout.index(of: id) else { continue }
                let visibleTop = layout.geometry.minY(at: index) - offset
                let target = visibleTop - collectionView.adjustedContentInset.top
                collectionView.contentOffset.y = min(
                    max(target, collectionView.minOffsetY), collectionView.maxOffsetY)
                return
            }
            pinToEnd()
        }
    }

    private func pinToEnd() {
        let end = collectionView.maxOffsetY
        if abs(collectionView.contentOffset.y - end) > 0.25 {
            collectionView.contentOffset.y = end
        }
    }

    /// Expands or folds a row, keeping its top edge where it is.
    func toggle(_ id: ChatRowID) {
        guard rowsByID[id]?.isExpandable == true else { return }
        if id.isHeader {
            toggleFold(id)
            return
        }
        disclose(id) {
            if expanded.remove(id) == nil {
                expanded.insert(id)
            }
        }
    }

    /// Opens or closes one changed file's diff in a tool row, keeping the
    /// row's top edge where it is.
    func toggleFile(_ id: ChatRowID, path: String) {
        guard case .tool(let tool)? = rowsByID[id]?.content,
            tool.fileChanges?.files.contains(where: { $0.path == path }) == true
        else { return }
        disclose(id) {
            var files = expandedFiles[id] ?? []
            if files.remove(path) == nil {
                files.insert(path)
            }
            expandedFiles[id] = files.isEmpty ? nil : files
        }
    }

    /// Whether a changed file's diff is open, for tests.
    func isFileExpanded(_ id: ChatRowID, path: String) -> Bool {
        expandedFiles[id]?.contains(path) == true
    }

    /// Applies a change to what a row shows open, reads what it now needs,
    /// and lays the row out again in place.
    private func disclose(_ id: ChatRowID, _ change: () -> Void) {
        guard let dataSource else { return }
        let anchor: ScrollAnchor = latch.isFollowing ? .end : .rows([(id, rowTop(id))])
        change()
        lastDisclosure += 1
        disclosures[id] = lastDisclosure
        if wantsOutput(id, retrying: true) { requestOutput(id) }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            restore(anchor)
        }
        latch.disclosureSettled(isAtEnd: isAtEnd)
        noteFollowing()
    }

    /// Whether a turn or group header is open, for tests.
    func isOpen(_ id: ChatRowID) -> Bool {
        openHeaders.contains(id)
    }

    /// Opens or closes a turn or group header. The rows it holds come and
    /// go below it, unanimated, and its top edge stays where it is even
    /// while the list follows: the reader asked to see what is under it.
    private func toggleFold(_ id: ChatRowID) {
        guard let dataSource else { return }
        let anchor = ScrollAnchor.rows([(id, rowTop(id))])
        if openHeaders.remove(id) == nil {
            openHeaders.insert(id)
        }
        let oldRows = rowsByID
        var snapshot = projectedSnapshot()
        snapshot.reconfigureItems(changedRows(since: oldRows, in: snapshot))
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            restore(anchor)
        }
        latch.disclosureSettled(isAtEnd: isAtEnd)
        noteFollowing()
        // Rows expanded before their turn folded read output that arrived
        // while they were away.
        for revealed in revealedRows(since: oldRows, in: snapshot) where wantsOutput(revealed, retrying: false) {
            requestOutput(revealed)
        }
        // VoiceOver stays on the header rather than a cell that left.
        if let index = layout.index(of: id),
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        {
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }
    }

    private func retryOutput(_ id: ChatRowID) {
        if wantsOutput(id, retrying: true) { requestOutput(id) }
    }

    /// Shows a changed file's whole diff, as far as the row holds it.
    private func showFile(_ id: ChatRowID, path: String) {
        guard case .tool(let tool)? = rowsByID[id]?.content, let changes = tool.fileChanges,
            let file = changes.files.first(where: { $0.path == path })
        else { return }
        ChatFileDiffPresenter.present(file, path: changes.displayPath(of: file), from: collectionView)
    }

    /// Whether a tool row should read its output again: what is open needs
    /// more than the row holds (output text cut short or never read, or a
    /// diff's lines), and no read has answered. Only a tap tries a failed
    /// read again.
    private func wantsOutput(_ id: ChatRowID, retrying: Bool) -> Bool {
        guard case .tool(let tool)? = rowsByID[id]?.content, tool.output != nil else { return false }
        let isExpanded = expanded.contains(id)
        let openFiles = expandedFiles[id] ?? []
        let wantsText = isExpanded && tool.previewIsIncomplete
        let wantsDiff = tool.fileChanges?.files.contains { file in
            !file.isComplete && (tool.showsDiffAsOutput ? isExpanded : openFiles.contains(file.path))
        } ?? false
        guard wantsText || wantsDiff else { return false }
        switch tool.outputRead {
        case nil: return true
        case .failed?: return retrying
        case .loading?, .read?, .unavailable?: return false
        }
    }

    private func requestOutput(_ id: ChatRowID) {
        guard case .entry(let entryID) = id else { return }
        actions.loadOutput(entryID)
    }

    /// A row's top edge relative to the visible top.
    private func rowTop(_ id: ChatRowID) -> CGFloat {
        guard let index = layout.index(of: id) else { return 0 }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return layout.geometry.minY(at: index) - visibleTop
    }

    private func reportFirstLayoutIfReady() {
        guard !hasReportedFirstLayout, applied?.isReady == true else { return }
        hasReportedFirstLayout = true
        // Applies run inside SwiftUI updates, which must not change state.
        Task { @MainActor [weak self] in
            self?.actions.firstPositionedLayout()
        }
    }

    private var isAtEnd: Bool {
        ChatFollowLatch.isAtEnd(offset: collectionView.contentOffset.y, maxOffset: collectionView.maxOffsetY)
    }

    /// Reported on the next turn: the change often happens inside a
    /// SwiftUI update, which must not mutate state.
    private func noteFollowing() {
        let following = latch.isFollowing
        guard following != reportedFollowing else { return }
        reportedFollowing = following
        Task { @MainActor [weak self] in
            self?.actions.followingChanged(following)
        }
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isJumpAnimating = false
        latch.userScrollBegan()
        noteFollowing()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        latch.scrolled(isAtEnd: isAtEnd)
        noteFollowing()
        requestOlderIfNear()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        latch.userScrollEnded(isAtEnd: isAtEnd)
        noteFollowing()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        latch.userScrollEnded(isAtEnd: isAtEnd)
        noteFollowing()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        isJumpAnimating = false
        latch.userScrollBegan()
        noteFollowing()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        latch.userScrollEnded(isAtEnd: isAtEnd)
        noteFollowing()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard isJumpAnimating else { return }
        isJumpAnimating = false
        pinToEnd()
        latch.scrolled(isAtEnd: isAtEnd)
        noteFollowing()
    }

    /// Within a screen of the top, earlier history loads by itself.
    private func requestOlderIfNear() {
        guard case .olderHistory(.available)? = rowsByID[.olderHistory]?.content else {
            requestedOlderAtRowCount = nil
            return
        }
        // Built rows, so opening or closing a fold does not ask again.
        let count = allRows.count
        guard requestedOlderAtRowCount != count,
            collectionView.contentOffset.y - collectionView.minOffsetY < collectionView.bounds.height
        else { return }
        requestedOlderAtRowCount = count
        // An apply's offset restore scrolls too, inside a SwiftUI update.
        Task { @MainActor [weak self] in
            self?.actions.loadOlder()
        }
    }

    // MARK: Menus

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
            let id = dataSource?.itemIdentifier(for: indexPath), let text = rowsByID[id]?.copyText
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                },
                UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in
                    self?.selectText(text)
                },
            ])
        }
    }

    private func selectText(_ text: String) {
        TerminalTextSelectionPresenter.present(
            text: text, font: .preferredFont(forTextStyle: .body), adjustsFontForContentSizeCategory: true,
            accessibilityIdentifier: "chat.text-selection", from: collectionView)
    }
}

/// Pins its content to the end on every layout while the timeline follows,
/// which covers appends, rows growing, inset and keyboard changes and
/// rotation in one place.
final class ChatCollectionView: UICollectionView {
    var shouldPin: () -> Bool = { false }

    var minOffsetY: CGFloat { -adjustedContentInset.top }

    var maxOffsetY: CGFloat {
        max(minOffsetY, contentSize.height + adjustedContentInset.bottom - bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard shouldPin() else { return }
        let end = maxOffsetY
        if abs(contentOffset.y - end) > 0.25 {
            contentOffset.y = end
        }
    }
}

/// Measures its hosted row at the column's full width.
final class ChatHostingCell: UICollectionViewCell {
    /// A hosted row pads itself by the safe area it overlaps, which for a
    /// row scrolling under the status bar or home indicator changes with
    /// every position, and so would its measured height. Rows only keep the
    /// sides, which are the same for all of them.
    override var safeAreaInsets: UIEdgeInsets {
        let insets = super.safeAreaInsets
        return UIEdgeInsets(top: 0, left: insets.left, bottom: 0, right: insets.right)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let fitted = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else {
            return layoutAttributes
        }
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        fitted.size.height = (size.height * scale).rounded(.up) / scale
        return fitted
    }
}
