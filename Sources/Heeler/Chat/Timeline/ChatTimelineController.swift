import SwiftUI
import UIKit

/// What the timeline tells its owner.
struct ChatTimelineActions {
    /// The user asked for earlier history: Load Earlier Messages or Retry.
    var loadOlder: @MainActor () -> Void = {}
    /// The list asks for earlier history by itself while its rows do not
    /// fill the screen.
    var loadOlderAutomatically: @MainActor () -> Void = {}
    /// Whether the list follows its newest row; drives Jump to Latest.
    var followingChanged: @MainActor (Bool) -> Void = { _ in }
    /// The first layout that shows content, positioned at its end.
    var firstPositionedLayout: @MainActor () -> Void = {}
    /// An expanded tool row has no output to show, or only its start.
    var loadOutput: @MainActor (ChatEntryID) -> Void = { _ in }
    /// Shown in an expanded tool row whose output was never read.
    var missingOutputText: String = "Output is available when connected."
    var loadImage: ChatImagePreviewController.Loader = { _ in throw ChatImagePreviewError.unavailable }
    /// An open trajectory intersects the reading viewport.
    var collapseAvailabilityChanged: @MainActor (Bool) -> Void = { _ in }
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
    /// How far a pull past the top has gone, for the Load Earlier row.
    var olderPull: ChatOlderPull?
}

/// A pull past the timeline's top, as the Load Earlier row shows it.
@MainActor @Observable
final class ChatOlderPull {
    enum Phase: Equatable {
        case idle
        /// Pulled, not yet far enough to load.
        case pulling
        /// Far enough: letting go loads earlier messages.
        case armed
        /// Let go while armed, until the request shows in the row.
        case requested
    }

    var phase: Phase = .idle
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
    /// The newest update that arrived while the list was held past its end,
    /// applied once it is back.
    private var heldState: ChatTimelineState?
    /// Every built row, folded ones included, so what a folded row has
    /// open survives its fold.
    private var allRows: [ChatRowID: ChatRow] = [:]
    /// The rows the list shows: built rows a fold leaves out of view are
    /// absent, and fold and group headers are present.
    private var rowsByID: [ChatRowID: ChatRow] = [:]
    /// Each folded row, by the shown header that holds it.
    private var owners: [ChatRowID: ChatRowID] = [:]
    private var trajectories: [ChatTimelineProjection.Trajectory] = []
    private var trajectoryByRow: [ChatRowID: Int] = [:]
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
    /// A disclosure is an explicit request to read from this row's top.
    /// Keep it stable through later self-sizing and asynchronously read output,
    /// until the reader scrolls, follows latest, or changes conversations.
    private var disclosureAnchor: ChatRowID?
    private var reportedFollowing = true
    private var reportedCanCollapse = false
    /// The floating Collapse Steps button's height above the list's bottom
    /// edge, and how much of it the bottom inset keeps clear right now.
    private var collapseControlClearance: CGFloat = 0
    private var collapseControlReserve: CGFloat = 0
    /// Where the chrome floating over the list's bottom edge begins, in
    /// window coordinates, and how much of the list it covers.
    private var bottomEdge: CGFloat?
    private var bottomObstruction: CGFloat = 0
    /// The part of the obstruction that is the keyboard, which moves with
    /// every frame of its motion, and the chrome's own part, which changes in
    /// steps.
    private var keyboardLift: CGFloat = 0
    private var keyboardIsFalling = false
    private var chromeObstruction: CGFloat?
    /// A chrome height still being given up over the keyboard's fall.
    private var chromeHandover: (excess: CGFloat, lift: CGFloat)?
    /// Set when the list may rest with its end under Collapse Steps; the
    /// next layout pass, which knows the end, moves it clear.
    private var wantsEndClearOfCollapseControl = false
    private var isJumpAnimating = false
    private var hasReportedFirstLayout = false
    /// The older-history state the last automatic request was made in, so
    /// one short list asks once.
    private var requestedOlderAtRowCount: Int?
    /// From a drag's start until the finger lifts.
    private var isPulling = false
    /// The drag pulled the list past its top far enough to load earlier
    /// history when the finger lifts.
    private var isPullArmed = false
    private let olderPull = ChatOlderPull()

    /// How far past its top the list is pulled to load earlier history.
    static let pullToLoadDistance: CGFloat = 80

    /// Whether the list follows its end, for tests.
    var isFollowing: Bool { latch.isFollowing }
    /// What the Load Earlier row shows of a pull, for tests.
    var olderPullPhase: ChatOlderPull.Phase { olderPull.phase }
    var timeline: ChatCollectionView { collectionView }
    var geometry: ChatTimelineGeometry { layout.geometry }
    var canCollapseTrajectory: Bool { collapseTarget != nil }

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

    /// Chat's text size and font, which every cell reads from its traits;
    /// a change re-measures the rows like a system text size change.
    /// A nil size leaves the system's in place. Overrides are read only
    /// once set: reading an unset one throws.
    func setTypography(size: DynamicTypeSize?, font: ChatFontOption) {
        let sizeTrait = UITraitPreferredContentSizeCategory.self
        if let size {
            let category = UIContentSizeCategory(size)
            if !traitOverrides.contains(sizeTrait) || traitOverrides.preferredContentSizeCategory != category {
                traitOverrides.preferredContentSizeCategory = category
            }
        } else if traitOverrides.contains(sizeTrait) {
            traitOverrides.remove(sizeTrait)
        }
        if !traitOverrides.contains(ChatFontTrait.self) || traitOverrides.chatFont != font {
            traitOverrides.chatFont = font
        }
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
        layout.disclosureAnchor = { [weak self] in self?.disclosureAnchor }
        layout.isPastEnd = { [weak self] in self?.isHeldPastEnd ?? false }

        let registration = UICollectionView.CellRegistration<ChatHostingCell, ChatRowID> {
            [weak self] cell, _, id in
            guard let self, let row = rowsByID[id] else { return }
            let isExpanded = expanded.contains(id)
            let files = expandedFiles[id] ?? []
            let actions = rowActions
            cell.contentConfiguration = UIHostingConfiguration {
                ChatRowView(row: row, isExpanded: isExpanded, expandedFiles: files, actions: actions)
                    .modifier(ChatFontDesign())
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
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, ChatFontTrait.self]) {
            (self: Self, _: UITraitCollection) in
            self.layout.invalidateLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomObstruction()
        liftEndClearOfCollapseControl()
        requestOlderIfShort()
        noteCollapseAvailability()
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
            retryOutput: { [weak self] id in self?.retryOutput(id) },
            olderPull: olderPull)
    }

    // MARK: Updates

    func apply(_ state: ChatTimelineState) {
        loadViewIfNeeded()
        guard let dataSource else { return }
        // Applying rows clamps an offset past the end to the new end, which
        // the drag or bounce then undoes on its next frame.
        if isHeldPastEnd {
            heldState = state
            return
        }
        heldState = nil
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
            isPulling = false
            isPullArmed = false
            olderPull.phase = .idle
            disclosureAnchor = nil
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
            requestOlderIfShort()
            noteCollapseAvailability()
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
        // The layout still holds the shown rows' last heights.
        let heightsBefore = rowHeights(changed)
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
        redrawResizedRows(changed, heightsBefore: heightsBefore)
        // Once the row shows the request, its own state takes over.
        if olderPull.phase == .requested {
            if case .olderHistory(.available)? = rowsByID[.olderHistory]?.content {} else { olderPull.phase = .idle }
        }
        forgetMeasurements()
        reportFirstLayoutIfReady()
        requestOlderIfShort()
        noteCollapseAvailability()
    }

    private func rowHeights(_ ids: [ChatRowID]) -> [ChatRowID: CGFloat] {
        var heights: [ChatRowID: CGFloat] = [:]
        for id in ids {
            if let index = layout.index(of: id) { heights[id] = layout.geometry.height(at: index) }
        }
        return heights
    }

    /// Applies arrive inside a SwiftUI update. A reconfigured row that
    /// self-sizing then resizes there keeps drawing its old content at the
    /// new size, so a pending message's new status line stayed blank under
    /// its bubble until something else laid the row out. Laying the hosted
    /// row out again once the update is over draws what it holds.
    private func redrawResizedRows(_ ids: [ChatRowID], heightsBefore: [ChatRowID: CGFloat]) {
        let resized = ids.filter { id in
            guard let before = heightsBefore[id], let index = layout.index(of: id) else { return false }
            return abs(layout.geometry.height(at: index) - before) >= 0.5
        }
        guard !resized.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for id in resized {
                guard let index = layout.index(of: id),
                    let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
                else { continue }
                cell.contentView.setNeedsLayout()
                cell.contentView.layoutIfNeeded()
            }
        }
    }

    /// Folds the applied rows as the open headers say, and makes the
    /// result what the list shows.
    private func projectedSnapshot() -> NSDiffableDataSourceSnapshot<Int, ChatRowID> {
        let output = ChatTimelineProjection.project(
            applied?.rows ?? [], turns: applied?.turns ?? [], precedingTurnEnd: applied?.precedingTurnEnd,
            signals: applied?.signals ?? ChatTurnSignals(), open: openHeaders)
        rowsByID = Dictionary(output.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        owners = output.owners
        trajectories = output.trajectories
        trajectoryByRow = [:]
        for (index, trajectory) in trajectories.enumerated() {
            for id in trajectory.shownIDs { trajectoryByRow[id] = index }
        }
        if let id = disclosureAnchor, rowsByID[id] == nil {
            disclosureAnchor = owners[id]
        }
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

    /// Keeps the list below window y `edge` clear of rows at rest, for
    /// chrome that floats over the list's bottom edge; rows still scroll
    /// beneath it. Measured against the list's own frame, which can stop
    /// short of the screen's bottom (a raised keyboard, the home indicator)
    /// by a different amount than the chrome's safe area says.
    ///
    /// `keyboardLift` is how much of that is the keyboard raising the chrome.
    func setBottomEdge(
        _ edge: CGFloat?, keyboardLift: CGFloat = 0, keyboardIsFalling: Bool = false
    ) {
        loadViewIfNeeded()
        guard bottomEdge != edge || self.keyboardLift != keyboardLift else { return }
        bottomEdge = edge
        self.keyboardLift = keyboardLift
        self.keyboardIsFalling = keyboardIsFalling
        updateBottomObstruction()
    }

    private func updateBottomObstruction() {
        var height: CGFloat = 0
        if let bottomEdge, collectionView.window != nil {
            let bottom = collectionView.convert(collectionView.bounds, to: nil).maxY
            let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
            height = (max(0, bottom - bottomEdge) * scale).rounded() / scale
        }
        // The Composer folds as the keyboard falls. Its change of height is
        // spread over the fall, so the rows have one motion and cannot reverse.
        let chrome = height - keyboardLift
        let previousChrome = chromeObstruction ?? chrome
        let chromeChanged = abs(previousChrome - chrome) > 0.5
        chromeObstruction = chrome
        if !keyboardIsFalling || keyboardLift <= 0 {
            chromeHandover = nil
        } else if chromeChanged {
            chromeHandover = (previousChrome - chrome, keyboardLift)
        }
        if let chromeHandover {
            height += (chromeHandover.excess * keyboardLift / chromeHandover.lift)
        }
        guard bottomObstruction != height else { return }
        bottomObstruction = height
        guard chromeChanged, chromeHandover == nil, collectionView.window != nil,
            !collectionView.isTracking
        else {
            settleBottomObstruction()
            return
        }
        // The chrome eases to its new height and the rows ease along.
        UIView.animate(
            withDuration: 0.25, delay: 0,
            options: [.allowUserInteraction, UIView.AnimationOptions(rawValue: 7 << 16)]
        ) { [self] in
            settleBottomObstruction()
            collectionView.layoutIfNeeded()
        }
    }

    private func settleBottomObstruction() {
        applyBottomInset()
        // A short list's blank space above its rows follows the room. A longer
        // list has none, and this runs on each frame of the keyboard's motion.
        if collectionView.contentSize.height < collectionView.bounds.height {
            layout.invalidateLayout()
        }
        collectionView.setNeedsLayout()
    }

    /// Keeps `height` at the bottom clear of rows while Collapse Steps
    /// shows, so the button never covers the newest row.
    func setCollapseControlClearance(_ height: CGFloat) {
        loadViewIfNeeded()
        guard collapseControlClearance != height else { return }
        collapseControlClearance = height
        reserveCollapseControlRoom()
    }

    private func reserveCollapseControlRoom() {
        let reserve = reportedCanCollapse ? collapseControlClearance : 0
        guard collapseControlReserve != reserve else { return }
        collapseControlReserve = reserve
        applyBottomInset()
        if reserve > 0 { wantsEndClearOfCollapseControl = true }
        // A short list's blank space above its rows follows the room.
        layout.invalidateLayout()
        collectionView.setNeedsLayout()
    }

    private func applyBottomInset() {
        collectionView.contentInset.bottom = Self.contentInsets.bottom + bottomObstruction + collapseControlReserve
        collectionView.verticalScrollIndicatorInsets.bottom = bottomObstruction
        // Room given back leaves no blank space past the end at rest.
        if !collectionView.isTracking, !collectionView.isDecelerating,
            collectionView.contentOffset.y > collectionView.maxOffsetY
        {
            collectionView.contentOffset.y = collectionView.maxOffsetY
        }
    }

    /// Where rows stop being readable: the bottom chrome covers the rest.
    private var visibleBottom: CGFloat {
        collectionView.contentOffset.y + collectionView.bounds.height - bottomObstruction
    }

    /// A list resting with its end under Collapse Steps, or past the bottom
    /// edge by no more than the button's room (a short last turn just
    /// opened, say), moves to its end so its newest rows sit above the
    /// button and take taps. Further from the end the reader is scrolling
    /// through a long turn, and the room lets its last row scroll clear.
    private func liftEndClearOfCollapseControl() {
        guard wantsEndClearOfCollapseControl else { return }
        wantsEndClearOfCollapseControl = false
        let view = collectionView
        let reserve = collapseControlReserve
        guard reserve > 0, !view.isTracking, !view.isDecelerating, !latch.isFollowing else { return }
        let end = view.maxOffsetY
        let offset = view.contentOffset.y
        guard offset < end - 0.5, offset >= end - 2 * reserve else { return }
        view.contentOffset.y = end
    }

    private func uniqueIDs(_ rows: [ChatRow]) -> [ChatRowID] {
        var seen = Set<ChatRowID>()
        return rows.map(\.id).filter { seen.insert($0).inserted }
    }

    /// Back to the newest row and following, as after a send. Waits for the
    /// layout the send's inset changes cause before pinning.
    func followLatest() {
        disclosureAnchor = nil
        latch.reset()
        noteFollowing()
        collectionView.setNeedsLayout()
    }

    /// The first open turn actually on screen, rather than the most
    /// recently expanded turn elsewhere in the conversation.
    private var collapseTarget: (trajectory: ChatTimelineProjection.Trajectory, row: ChatRowID)? {
        // Making room for the button moves only a list at its end up, by as
        // far as it rests past the end without that room. Measured from no
        // later than that end, the window is the same with or without the
        // room, so making or giving it back never changes the answer; away
        // from the end it starts at the top edge.
        let view = collectionView
        let unreservedEnd = max(
            view.minOffsetY,
            view.contentSize.height + view.adjustedContentInset.bottom - collapseControlReserve - view.bounds.height)
        let top = min(view.contentOffset.y, unreservedEnd) + view.adjustedContentInset.top
        for index in layout.geometry.indices(from: top, to: visibleBottom) {
            guard let id = layout.id(at: index), let scope = trajectoryByRow[id] else { continue }
            let trajectory = trajectories[scope]
            // A folded turn ending at the top edge leaves the open turn
            // under it in view.
            if trajectory.shownIDs.contains(where: {
                openHeaders.contains($0) || expanded.contains($0) || expandedFiles[$0]?.isEmpty == false
            }) {
                return (trajectory, id)
            }
        }
        return nil
    }

    /// Folds this turn's groups, reasoning, tool output and file diffs in
    /// one update. Other turns keep their disclosures and measurements.
    func collapseCurrentTrajectory() {
        guard let target = collapseTarget, let dataSource else { return }
        let scope = target.trajectory
        let offset = max(0, rowTop(target.row))
        let details = scope.shownIDs.filter {
            openHeaders.contains($0) || expanded.contains($0) || expandedFiles[$0]?.isEmpty == false
        }
        let preferred = scope.turnHeader ?? details.first ?? target.row
        _ = beginDisclosure(preferred)
        let changed = Set(expanded.filter(scope.contains))
            .union(expandedFiles.keys.filter(scope.contains))
        expanded = expanded.filter { !scope.contains($0) }
        expandedFiles = expandedFiles.filter { !scope.contains($0.key) }
        openHeaders = openHeaders.filter { !scope.contains($0) }
        for id in changed {
            lastDisclosure += 1
            disclosures[id] = lastDisclosure
        }
        let oldRows = rowsByID
        var snapshot = projectedSnapshot()
        var anchorID = preferred
        var visited: Set<ChatRowID> = []
        while rowsByID[anchorID] == nil, visited.insert(anchorID).inserted, let owner = owners[anchorID] {
            anchorID = owner
        }
        disclosureAnchor = anchorID
        let reconfigure = Set(changedRows(since: oldRows, in: snapshot))
            .union(changed.intersection(snapshot.itemIdentifiers))
        snapshot.reconfigureItems(Array(reconfigure))
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            restore(.rows([(anchorID, offset)]))
        }
        // Restore clamps to the natural end when little content follows.
        // Never add trailing space just to pin a collapsed header at the top.
        noteCollapseAvailability()
        if let index = layout.index(of: anchorID),
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        {
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }
    }

    /// Jump to Latest: animates from nearby, and first lands one screen
    /// above the end from far away, so no blank screen of unmeasured rows
    /// scrolls past.
    func jumpToLatest() {
        disclosureAnchor = nil
        latch.reset()
        noteFollowing()
        // Held from the start, so a layout on the way cannot pin to the end
        // before the animation begins.
        isJumpAnimating = true
        collectionView.layoutIfNeeded()
        let end = collectionView.maxOffsetY
        if end - collectionView.contentOffset.y > 2 * collectionView.bounds.height {
            collectionView.contentOffset.y = max(collectionView.minOffsetY, end - collectionView.bounds.height)
            collectionView.layoutIfNeeded()
        }
        // An animation to where the list already is never starts, so it
        // never ends either, and the flag would stop every later pin.
        if UIAccessibility.isReduceMotionEnabled
            || abs(collectionView.maxOffsetY - collectionView.contentOffset.y) <= 0.25
        {
            isJumpAnimating = false
            pinToEnd()
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: collectionView.maxOffsetY), animated: true)
    }

    private func captureAnchor() -> ScrollAnchor {
        if let id = disclosureAnchor, layout.index(of: id) != nil {
            return .rows([(id, rowTop(id))])
        }
        if latch.isFollowing { return .end }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let range = layout.geometry.indices(from: visibleTop, to: visibleBottom)
        let rows = range.compactMap { index -> (ChatRowID, CGFloat)? in
            guard let id = layout.id(at: index) else { return nil }
            return (id, layout.geometry.minY(at: index) - visibleTop)
        }
        return rows.contains(where: { $0.0 != .olderHistory }) ? .rows(rows) : .end
    }

    private func restore(_ anchor: ScrollAnchor) {
        switch anchor {
        case .end:
            pinToEnd()
        case .rows(var rows):
            // Earlier history loads in under the Load Earlier row, which
            // stays first: holding it still would put the reader at the top
            // of what loaded, which asks for the next page at once. With
            // nothing loaded under it, it holds still, so a row that grew
            // (a failure and its Retry) stays in view.
            if rows.first?.0 == .olderHistory {
                let rowIndex = layout.index(of: .olderHistory)
                let nextIndex = rows.count > 1 ? layout.index(of: rows[1].0) : nil
                if rowIndex == nil || nextIndex == nil || nextIndex != rowIndex.map({ $0 + 1 }) {
                    rows.removeFirst()
                }
            }
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
        disclose(id, expanding: !expanded.contains(id)) {
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
        disclose(id, expanding: expandedFiles[id]?.contains(path) != true) {
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
    private func disclose(_ id: ChatRowID, expanding: Bool, _ change: () -> Void) {
        guard let dataSource else { return }
        let anchor = beginDisclosure(id)
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
        finishDisclosure(expanding: expanding)
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
        let anchor = beginDisclosure(id)
        let expanding = !openHeaders.contains(id)
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
        finishDisclosure(expanding: expanding)
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

    private func beginDisclosure(_ id: ChatRowID) -> ScrollAnchor {
        let anchor = ScrollAnchor.rows([(id, rowTop(id))])
        disclosureAnchor = id
        layout.holdTopPadding()
        // Stop before UIKit measures anything. Otherwise the collection's
        // layout pass can pin to the old end before the anchor is restored.
        isJumpAnimating = false
        latch.disclosureSettled(isAtEnd: false)
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        noteFollowing()
        return anchor
    }

    private func finishDisclosure(expanding: Bool) {
        // Even a short loading row can grow after output arrives. Expanding
        // keeps its top fixed; collapsing may naturally return to latest.
        if !expanding, isAtEnd {
            disclosureAnchor = nil
            latch.disclosureSettled(isAtEnd: true)
        }
        noteFollowing()
        noteCollapseAvailability()
        if expanding {
            wantsEndClearOfCollapseControl = true
            collectionView.setNeedsLayout()
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

    /// A drag or its bounce holding the list past its end. UIKit moves the
    /// offset itself then, and any change to it throws the rows out, so the
    /// timeline holds its rows and their heights until the list is back
    /// within its bounds.
    private var isHeldPastEnd: Bool {
        latch.isUserScrolling && collectionView.contentOffset.y > collectionView.maxOffsetY + 0.5
    }

    /// Catches up on what the list held while it was past its end.
    private func releaseHoldIfBack() {
        guard !isHeldPastEnd else { return }
        layout.applyHeldHeights()
        if let state = heldState {
            heldState = nil
            apply(state)
        }
    }

    /// Reported on the next turn: the change often happens inside a
    /// SwiftUI update, which must not mutate state.
    private func noteFollowing() {
        let following = latch.isFollowing
        if following { layout.releaseTopPadding() }
        guard following != reportedFollowing else { return }
        reportedFollowing = following
        Task { @MainActor [weak self] in
            self?.actions.followingChanged(following)
        }
    }

    private func noteCollapseAvailability() {
        let available = canCollapseTrajectory
        guard available != reportedCanCollapse else { return }
        reportedCanCollapse = available
        reserveCollapseControlRoom()
        Task { @MainActor [weak self] in
            guard let self, reportedCanCollapse == available else { return }
            actions.collapseAvailabilityChanged(available)
        }
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        disclosureAnchor = nil
        isJumpAnimating = false
        isPulling = true
        isPullArmed = false
        olderPull.phase = .idle
        latch.userScrollBegan()
        noteFollowing()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if disclosureAnchor == nil { latch.scrolled(isAtEnd: isAtEnd) }
        noteFollowing()
        releaseHoldIfBack()
        notePull()
        requestOlderIfShort()
        noteCollapseAvailability()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isPulling = false
        if isPullArmed {
            isPullArmed = false
            olderPull.phase = .requested
            actions.loadOlder()
        }
        guard !decelerate else { return }
        latch.userScrollEnded(isAtEnd: disclosureAnchor == nil && isAtEnd)
        noteFollowing()
        releaseHoldIfBack()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A finger that catches the momentum or the bounce stops it here,
        // past the end as often as not; the list rests where it was caught,
        // and following there would pin it to the end under the finger.
        latch.userScrollEnded(isAtEnd: disclosureAnchor == nil && isAtEnd && !scrollView.isTracking)
        noteFollowing()
        releaseHoldIfBack()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        disclosureAnchor = nil
        isJumpAnimating = false
        latch.userScrollBegan()
        noteFollowing()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        latch.userScrollEnded(isAtEnd: disclosureAnchor == nil && isAtEnd)
        noteFollowing()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard isJumpAnimating else { return }
        isJumpAnimating = false
        pinToEnd()
        latch.scrolled(isAtEnd: isAtEnd)
        noteFollowing()
    }

    /// Pulling the list past its top by `pullToLoadDistance` arms a request
    /// for earlier history, with a tap of feedback; lifting the finger then
    /// makes it, as Load Earlier Messages or Retry does, unless the finger
    /// pushed back inside that distance first. Reaching the top alone loads
    /// nothing, so a scroll that bounces there can't by accident.
    private func notePull() {
        let pulled = collectionView.minOffsetY - collectionView.contentOffset.y
        switch rowsByID[.olderHistory]?.content {
        case .olderHistory(.available)?, .olderHistory(.failed)?: break
        default: return
        }
        // A pull let go short of loading keeps its hint until it bounces back.
        if !isPulling {
            if olderPull.phase == .pulling, pulled <= 0 { olderPull.phase = .idle }
            return
        }
        if pulled >= Self.pullToLoadDistance {
            guard !isPullArmed else { return }
            isPullArmed = true
            olderPull.phase = .armed
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            isPullArmed = false
            olderPull.phase = pulled > 0 ? .pulling : .idle
        }
    }

    /// Rows that do not fill the screen leave it partly empty, so earlier
    /// history loads by itself, without a pull.
    private func requestOlderIfShort() {
        guard case .olderHistory(.available)? = rowsByID[.olderHistory]?.content else {
            requestedOlderAtRowCount = nil
            return
        }
        // Built rows, so opening or closing a fold does not ask again.
        let count = allRows.count
        guard requestedOlderAtRowCount != count, layout.geometry.contentHeight < layout.geometry.visibleHeight
        else { return }
        requestedOlderAtRowCount = count
        // An apply's offset restore scrolls too, inside a SwiftUI update.
        Task { @MainActor [weak self] in
            self?.actions.loadOlderAutomatically()
        }
    }

    // MARK: Menus

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
            let id = dataSource?.itemIdentifier(for: indexPath), let row = rowsByID[id], let text = row.copyText
        else { return nil }
        let path = row.imagePath
        let loader = actions.loadImage
        let preview: UIContextMenuContentPreviewProvider? = path.map { path in
            { ChatImagePreviewController(path: path, loadImage: loader) }
        }
        return UIContextMenuConfiguration(identifier: path as NSString?, previewProvider: preview) { [weak self] _ in
            var items: [UIMenuElement] = []
            if let path {
                items.append(UIAction(title: "Preview Image", image: UIImage(systemName: "photo")) { [weak self] _ in
                    guard let self else { return }
                    ChatImagePreviewController(path: path, loadImage: loader).present(from: self)
                })
            }
            items += [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                },
                UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in
                    self?.selectText(text)
                },
            ]
            return UIMenu(children: items)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: any UIContextMenuInteractionCommitAnimating
    ) {
        guard let preview = animator.previewViewController as? ChatImagePreviewController else { return }
        animator.addCompletion { [weak self] in
            guard let self else { return }
            preview.present(from: self)
        }
    }

    private func selectText(_ text: String) {
        TerminalTextSelectionPresenter.present(
            text: text, font: .preferredFont(forTextStyle: .body, compatibleWith: collectionView.traitCollection),
            adjustsFontForContentSizeCategory: true,
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
