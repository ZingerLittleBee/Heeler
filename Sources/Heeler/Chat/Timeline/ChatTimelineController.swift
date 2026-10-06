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
    private var rowsByID: [ChatRowID: ChatRow] = [:]
    private var expanded: Set<ChatRowID> = []
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
            guard let row = self?.rowsByID[id] else { return nil }
            let expanded = self?.expanded.contains(id) == true
            // An expanded row is a different measurement of the same content.
            return (row.seed, row.revision * 2 + (expanded ? 1 : 0))
        }
        layout.isFollowing = { [weak self] in self?.latch.isFollowing ?? true }

        let registration = UICollectionView.CellRegistration<ChatHostingCell, ChatRowID> {
            [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            let isExpanded = expanded.contains(id)
            let actions = rowActions
            cell.contentConfiguration = UIHostingConfiguration {
                ChatRowView(row: row, isExpanded: isExpanded, actions: actions)
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
            missingOutputText: actions.missingOutputText)
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
        rowsByID = Dictionary(state.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatRowID>()
        snapshot.appendSections([0])
        snapshot.appendItems(uniqueIDs(state.rows))

        guard let previous, previous.generation == state.generation else {
            expanded = []
            requestedOlderAtRowCount = nil
            latch.reset()
            noteFollowing()
            UIView.performWithoutAnimation {
                dataSource.applySnapshotUsingReloadData(snapshot)
                collectionView.layoutIfNeeded()
                pinToEnd()
            }
            layout.forgetMeasurements(keeping: Set(rowsByID.keys))
            reportFirstLayoutIfReady()
            return
        }

        let anchor = captureAnchor()
        let changed = state.rows.compactMap { row -> ChatRowID? in
            guard let old = oldRows[row.id], old.revision != row.revision else { return nil }
            return row.id
        }
        snapshot.reconfigureItems(changed)
        expanded.formIntersection(rowsByID.keys)
        // A row expanded while it ran may have output now. The request
        // waits for this update to finish, since it changes what the list
        // is built from.
        let wanting = changed.filter { expanded.contains($0) && wantsOutput($0, retrying: false) }
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
        layout.forgetMeasurements(keeping: Set(rowsByID.keys))
        reportFirstLayoutIfReady()
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
            for (id, offset) in rows {
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
        guard let dataSource, rowsByID[id]?.isExpandable == true else { return }
        let anchor: ScrollAnchor = latch.isFollowing ? .end : .rows([(id, rowTop(id))])
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            if wantsOutput(id, retrying: true) { requestOutput(id) }
        }
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

    /// Whether an expanded tool row should read its output again: it has
    /// none to show, or only the start, and no read has answered. Only a
    /// tap tries a failed read again.
    private func wantsOutput(_ id: ChatRowID, retrying: Bool) -> Bool {
        guard case .tool(let tool)? = rowsByID[id]?.content, tool.output != nil,
            tool.preview?.isTruncated ?? true
        else { return false }
        switch tool.outputRead {
        case nil: return true
        case .failed?: return retrying
        case .loading?, .read?: return false
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
        let count = rowsByID.count
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
