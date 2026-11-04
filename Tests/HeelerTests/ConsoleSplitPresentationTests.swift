import SwiftUI
import Testing

@testable import Heeler

@Suite("Console split presentation")
struct ConsoleSplitPresentationTests {
    private let landscape = ConsoleSplitPresentation(
        horizontalSizeClass: .regular, size: CGSize(width: 1194, height: 834))
    private let portrait = ConsoleSplitPresentation(
        horizontalSizeClass: .regular, size: CGSize(width: 834, height: 1194))

    @Test func regularLandscapeShowsBothColumns() {
        #expect(landscape.defaultVisibility == .all)
        #expect(landscape.usesRegularColumns)
        #expect(landscape.sidebarWidth == .init(minimum: 320, ideal: 380, maximum: 600))
    }

    @Test func regularPortraitShowsDetail() {
        #expect(portrait.defaultVisibility == .detailOnly)
        #expect(portrait.usesRegularColumns)
        #expect(portrait.sidebarWidth == .init(minimum: 320, ideal: 380, maximum: 600))
    }

    @Test func sidebarIsUserResizableAboveItsIdeal() {
        // The divider can be dragged wider than the ideal, but not past the cap.
        let width = landscape.sidebarWidth
        #expect(width.maximum.map { $0 > width.ideal } == true)
        #expect(width.minimum < width.ideal)
    }

    @Test(arguments: [false, true])
    func compactRetainsAutomaticVisibility(isLandscape: Bool) {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: .compact,
            size: isLandscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844))
        #expect(presentation.defaultVisibility == .automatic)
        #expect(!presentation.usesRegularColumns)
        #expect(presentation.sidebarWidth == .init(minimum: 320, ideal: 380, maximum: nil))
    }

    @Test func unknownSizeClassUsesAutomaticVisibility() {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: nil, size: CGSize(width: 1194, height: 834))
        #expect(presentation.defaultVisibility == .automatic)
        #expect(!presentation.usesRegularColumns)
    }

    @Test func squareWindowShowsDetail() {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 900, height: 900))
        #expect(presentation.defaultVisibility == .detailOnly)
    }

    @Test func safeAreaInsetsPreservePortraitAspectWithKeyboard() {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 834, height: 700),
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 470, trailing: 0))
        #expect(presentation.defaultVisibility == .detailOnly)
    }

    @Test func portraitSeedFollowsRotationUntilUserToggles() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
        state.update(from: landscape)
        #expect(state.visibility == .all)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
        #expect(state.userVisibility == nil)
    }

    @Test func compactSeedFollowsRegularWidthLayout() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844)))
        #expect(state.visibility == .automatic)
        state.update(from: landscape)
        #expect(state.visibility == .all)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test(arguments: [false, true])
    func stableSystemToggleSurvivesRotation(startInPortrait: Bool) {
        var state = ConsoleSplitVisibilityState()
        let initial = startInPortrait ? portrait : landscape
        state.update(from: initial)
        let chosen: NavigationSplitViewVisibility = startInPortrait ? .all : .detailOnly
        state.systemDidChangeVisibility(chosen, presentation: initial)
        #expect(state.userVisibility == chosen)
        state.update(from: startInPortrait ? landscape : portrait)
        #expect(state.visibility == chosen)
        state.update(from: initial)
        #expect(state.visibility == chosen)
    }

    @Test func transitionWriteBacksBeforeUpdateDoNotBecomeIntent() {
        var state = ConsoleSplitVisibilityState()
        state.systemDidChangeVisibility(.all, presentation: portrait)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func outgoingLayoutWriteBackAfterUpdateCannotOverrideNewDefault() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.visibility == .all)
        #expect(state.userVisibility == nil)
    }

    @Test func seedAcknowledgementDoesNotBecomeIntent() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.reportedSidebarVisibility == false)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        #expect(state.reportedSidebarVisibility == true)
        #expect(state.userVisibility == nil)
    }

    @Test func sameAspectResizePreservesPolicyAndVisibilityReport() {
        let resizedPortrait = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 800, height: 1100))
        #expect(resizedPortrait == portrait)
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.all, presentation: portrait)
        state.update(from: resizedPortrait)
        #expect(state.reportedSidebarVisibility == true)
        #expect(!state.showsAgentsAction)
        #expect(state.userVisibility == .all)
        state.systemDidChangeVisibility(.detailOnly, presentation: resizedPortrait)
        #expect(state.userVisibility == nil)
    }

    @Test func policyChangesAtAspectAndSizeClassBoundaries() {
        let compactPortrait = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 834, height: 1194))
        #expect(portrait != landscape)
        #expect(portrait != compactPortrait)
        #expect(portrait != ConsoleSplitPresentation(horizontalSizeClass: .regular, size: .zero))
    }

    @Test func compactWriteBackDoesNotReplaceRegularUserChoice() {
        let compact = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844))
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.all, presentation: portrait)
        state.update(from: compact)
        state.systemDidChangeVisibility(.detailOnly, presentation: compact)
        #expect(state.userVisibility == .all)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func layoutChangeInvalidatesThePreviousVisibilityReport() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        #expect(state.reportedSidebarVisibility == true)
        state.update(from: portrait)
        #expect(state.reportedSidebarVisibility == nil)
        #expect(state.visibility == .detailOnly)
    }

    @Test func automaticReportDoesNotClaimVisibleOrRecordIntent() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.automatic, presentation: portrait)
        // On the iPhone test destination, automatic resolves to the concrete detailOnly value.
        #expect(state.reportedSidebarVisibility == false)
        #expect(state.isSidebarVisible == false)
        #expect(state.showsAgentsAction)
        #expect(state.userVisibility == nil)
        state.showSidebar()
        #expect(state.visibility == .all)
        #expect(!state.showsAgentsAction)
    }

    @Test(arguments: [false, true])
    func portraitRevealThenDismissRestoresLandscapeDefault(useShowAgents: Bool) {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        if useShowAgents {
            state.showSidebar()
        } else {
            state.systemDidChangeVisibility(.all, presentation: portrait)
        }
        #expect(state.userVisibility == .all)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func landscapeHideSurvivesPortraitRoundTripAndAcknowledgement() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        #expect(state.userVisibility == .detailOnly)
        state.update(from: portrait)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.userVisibility == .detailOnly)
        state.update(from: landscape)
        #expect(state.visibility == .detailOnly)
    }

    @Test func showingAgainInLandscapeClearsPreference() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        state.update(from: portrait)
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test func showAgentsClearsLandscapeHidePreference() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        state.showSidebar()
        #expect(state.visibility == .all)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test(arguments: [false, true])
    func visibleLandscapeHidesShowAgentsAndPressIsNoOp(withSystemEcho: Bool) {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        if withSystemEcho {
            state.systemDidChangeVisibility(.all, presentation: landscape)
        }
        #expect(!state.showsAgentsAction)
        let empty = ConsoleEmptyDetailPresentation(hasHosts: true, showsAgentsAction: state.showsAgentsAction)
        #expect(!empty.actions.contains(.showAgents))
        state.showSidebar()
        #expect(state.visibility == .all)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test func concreteVisibleReportHidesActionAndRepeatedShowPreservesChoice() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.all, presentation: portrait)
        #expect(!state.showsAgentsAction)
        state.showSidebar()
        #expect(state.visibility == .all)
        #expect(state.reportedSidebarVisibility == true)
        #expect(state.userVisibility == .all)
    }

    @Test func showAgentsRevealsHiddenSidebarOnceWithoutNeedingEcho() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        #expect(state.showsAgentsAction)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        state.showSidebar()
        #expect(state.visibility == .all)
        #expect(state.userVisibility == .all)
        #expect(!state.showsAgentsAction)
        state.showSidebar()
        #expect(state.visibility == .all)
        #expect(state.userVisibility == .all)
    }

    @Test func portraitPickReturnsToTheDetailAlone() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.showSidebar()
        #expect(state.isSidebarVisible == true)
        state.selectionDidOpenDetail()
        #expect(state.visibility == .detailOnly)
        #expect(state.isSidebarVisible == false)
        // Not a hide preference: landscape still shows both columns.
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func pickKeepsTheSidebarWhereItIsShownByDefault() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.selectionDidOpenDetail()
        #expect(state.visibility == .all)

        var compact = ConsoleSplitVisibilityState()
        compact.update(
            from: ConsoleSplitPresentation(
                horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844)))
        compact.selectionDidOpenDetail()
        #expect(compact.visibility == .automatic)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 834), CGSize(width: 1194, height: 0)])
    func zeroSizedPassDoesNotSeedOrReplaceLayout(size: CGSize) {
        let invalid = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: size,
            safeAreaInsets: EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
        #expect(!invalid.hasUsableSize)
        var state = ConsoleSplitVisibilityState()
        state.update(from: invalid)
        #expect(state.visibility == .automatic)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
        state.update(from: invalid)
        #expect(state.visibility == .all)
    }
}
