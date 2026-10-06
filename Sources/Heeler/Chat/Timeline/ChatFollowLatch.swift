import CoreGraphics

/// Decides whether the Chat timeline keeps itself pinned to the newest
/// message.
///
/// A geometric "near the end" test alone is not enough: while an answer
/// streams, a reader who scrolled a few points up would be pulled back down
/// by every chunk that grows a row. Following is therefore a latch, ported by
/// semantics from T3 Code's thread-feed live follow (MIT). A user scroll
/// session, from a drag's start through the end of its momentum, turns it off
/// at once. It turns back on only when that session comes to rest at the end,
/// when a scroll outside any session reaches the end, or on an explicit reset
/// (a send, Jump to Latest, another conversation).
///
/// Programmatic offset changes (anchor compensation, inset and keyboard
/// changes, the jump animation) arrive as scroll events outside a session, so
/// they can turn following on but never off.
struct ChatFollowLatch: Sendable, Equatable {
    /// How far above the end, in points, still counts as at the end. The
    /// Monitor's pinned threshold used the same value.
    static let endTolerance: CGFloat = 24

    private(set) var isFollowing = true
    /// True from a drag's start, or a tap on the status bar, until the scroll
    /// it started comes to rest.
    private(set) var isUserScrolling = false

    init() {}

    /// Whether `offset` is at the end of content that scrolls no further
    /// than `maxOffset`.
    static func isAtEnd(offset: CGFloat, maxOffset: CGFloat) -> Bool {
        maxOffset - offset <= endTolerance
    }

    /// Follows again and forgets any scroll in progress, so the drag that
    /// was underway cannot turn following off when it ends.
    mutating func reset() {
        isFollowing = true
        isUserScrolling = false
    }

    /// The user began to scroll. Following stops before the first scroll
    /// event, so an append between touch-down and the drag leaving the
    /// tolerance cannot pin the list back to the end under the finger.
    mutating func userScrollBegan() {
        isUserScrolling = true
        isFollowing = false
    }

    /// The user's scroll came to rest: the finger lifted without momentum,
    /// the momentum ended, or the scroll to top finished. Following resumes
    /// exactly when it rests at the end. Without a session in progress the
    /// event says nothing about the user and changes nothing.
    mutating func userScrollEnded(isAtEnd: Bool) {
        if isUserScrolling {
            isFollowing = isAtEnd
        }
        isUserScrolling = false
    }

    /// The offset changed. Inside a session following stays off even at the
    /// end, so it resumes only once the user lets go there. Outside a session
    /// the change was programmatic: reaching the end resumes following, and
    /// anything else leaves it as it was.
    mutating func scrolled(isAtEnd: Bool) {
        if isUserScrolling {
            isFollowing = false
        } else if isAtEnd {
            isFollowing = true
        }
    }

    /// A row finished expanding or collapsing. A disclosure can leave the
    /// reader above the end without any drag, so following is reconciled
    /// with where the list now rests before a later layout could pin it.
    mutating func disclosureSettled(isAtEnd: Bool) {
        isFollowing = !isUserScrolling && isAtEnd
    }
}
