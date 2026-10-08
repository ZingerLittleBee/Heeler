import UIKit

/// The Chat timeline's single column of full-width rows.
///
/// Heights come from the cells themselves (self-sizing); until a row is
/// measured it gets its last measurement, even one taken at another width or
/// text size, or else its family's seed. The arithmetic lives in
/// `ChatTimelineGeometry`; this class only feeds it and answers UIKit.
///
/// A row that measures differently moves everything below it. While the
/// reader is scrolled up, the content offset moves by the same amount for
/// rows above the first fully visible one, so what they are reading stays
/// put. A following list needs nothing: the collection view pins its end.
@MainActor
final class ChatTimelineLayout: UICollectionViewLayout {
    /// Identity and revision of the rows the collection view holds now,
    /// in order; read from the data source so the two can never disagree.
    var itemIDs: () -> [ChatRowID] = { [] }
    var rowInfo: (ChatRowID) -> (seed: ChatRowSeed, revision: Int)? = { _ in nil }
    var isFollowing: () -> Bool = { true }
    /// The row the reader explicitly opened, including when its top is
    /// partially clipped. Its own growth must extend downward.
    var disclosureAnchor: () -> ChatRowID? = { nil }

    private(set) var geometry = ChatTimelineGeometry()
    private var ids: [ChatRowID] = []
    private var indexByID: [ChatRowID: Int] = [:]
    private var measured: [ChatRowID: ChatMeasuredHeight] = [:]
    private var width: CGFloat = 0
    private var contentSizeCategory = ""

    func index(of id: ChatRowID) -> Int? {
        indexByID[id]
    }

    func id(at index: Int) -> ChatRowID? {
        ids.indices.contains(index) ? ids[index] : nil
    }

    /// A short conversation normally rests at the bottom. Once the reader
    /// opens a row, its existing blank space belongs above that row until
    /// following resumes, just like already-scrolled content would.
    func holdTopPadding() {
        geometry.minimumTopPadding = geometry.topPadding
    }

    func releaseTopPadding() {
        guard geometry.minimumTopPadding != 0 else { return }
        geometry.minimumTopPadding = 0
        invalidateLayout()
    }

    /// Drops measurements for rows no longer shown, so the cache follows the
    /// conversation instead of growing with it.
    func forgetMeasurements(keeping kept: Set<ChatRowID>) {
        measured = measured.filter { kept.contains($0.key) }
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let ids = itemIDs()
        let width = collectionView.bounds.width
        let category = collectionView.traitCollection.preferredContentSizeCategory.rawValue
        if ids != self.ids || width != self.width || category != contentSizeCategory {
            self.ids = ids
            self.width = width
            contentSizeCategory = category
            indexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            geometry.setHeights(ids.map(estimatedHeight))
        }
        geometry.visibleHeight = Self.visibleHeight(of: collectionView)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: geometry.totalHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.indices(from: rect.minY, to: rect.maxY).map(attributes(at:))
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item < geometry.count else { return nil }
        return attributes(at: indexPath.item)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let index = preferredAttributes.indexPath.item
        guard preferredAttributes.representedElementCategory == .cell, index < geometry.count else {
            return false
        }
        record(preferredAttributes.size.height, at: index)
        return abs(preferredAttributes.size.height - geometry.height(at: index)) >= 0.5
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes, withOriginalAttributes: originalAttributes)
        let index = preferredAttributes.indexPath.item
        guard let collectionView, index < geometry.count else { return context }
        let anchor = isFollowing() ? nil : stableAnchor(in: collectionView)
        let delta = geometry.setHeight(preferredAttributes.size.height, at: index)
        context.contentSizeAdjustment = CGSize(width: 0, height: delta)
        let adjustment = geometry.offsetAdjustment(restoring: anchor)
        if adjustment != 0 {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: adjustment)
        }
        return context
    }

    /// The first row whose top edge shows, or the first row showing when
    /// none does. A row cut off at the top grows upward, off screen, rather
    /// than pushing what is below it.
    private func stableAnchor(in collectionView: UICollectionView) -> ChatTimelineAnchor? {
        if let id = disclosureAnchor(), let index = indexByID[id] {
            return ChatTimelineAnchor(index: index, minY: geometry.minY(at: index))
        }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard let first = geometry.anchor(visibleTop: visibleTop) else { return nil }
        let next = first.index + 1
        if first.minY < visibleTop - 0.5, next < geometry.count {
            return ChatTimelineAnchor(index: next, minY: geometry.minY(at: next))
        }
        return first
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = CGRect(x: 0, y: geometry.minY(at: index), width: width, height: geometry.height(at: index))
        return attributes
    }

    private func record(_ height: CGFloat, at index: Int) {
        guard let id = id(at: index), let info = rowInfo(id) else { return }
        measured[id] = ChatMeasuredHeight(
            height: height, width: width, contentSizeCategory: contentSizeCategory, revision: info.revision)
    }

    private func estimatedHeight(for id: ChatRowID) -> CGFloat {
        guard let info = rowInfo(id) else { return ChatRowSeed.system.height }
        return ChatHeightEstimate(
            cached: measured[id], seed: info.seed, width: width,
            contentSizeCategory: contentSizeCategory, revision: info.revision
        ).height
    }

    static func visibleHeight(of collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(0, collectionView.bounds.height - insets.top - insets.bottom)
    }
}
