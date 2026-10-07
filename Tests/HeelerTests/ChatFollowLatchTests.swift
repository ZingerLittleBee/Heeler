import CoreGraphics
import Testing

@testable import Heeler

@Suite("Chat follow latch")
struct ChatFollowLatchTests {
    /// The states a latch can reach. Following inside a user scroll session
    /// is not one of them: a session starts by turning following off, and
    /// nothing turns it back on until the session ends.
    enum Start: String, Sendable, CaseIterable {
        case following
        case paused
        case scrolling

        var latch: ChatFollowLatch {
            var latch = ChatFollowLatch()
            switch self {
            case .following:
                break
            case .paused:
                latch.userScrollBegan()
                latch.userScrollEnded(isAtEnd: false)
            case .scrolling:
                latch.userScrollBegan()
            }
            return latch
        }
    }

    enum Event: Sendable, Equatable {
        case reset
        case userScrollBegan
        case userScrollEnded(isAtEnd: Bool)
        case scrolled(isAtEnd: Bool)
        case disclosureSettled(isAtEnd: Bool)

        static let all: [Event] = [
            .reset, .userScrollBegan,
            .userScrollEnded(isAtEnd: true), .userScrollEnded(isAtEnd: false),
            .scrolled(isAtEnd: true), .scrolled(isAtEnd: false),
            .disclosureSettled(isAtEnd: true), .disclosureSettled(isAtEnd: false),
        ]

        var name: String {
            switch self {
            case .reset: "reset"
            case .userScrollBegan: "userScrollBegan"
            case .userScrollEnded(let isAtEnd): "userScrollEnded(isAtEnd: \(isAtEnd))"
            case .scrolled(let isAtEnd): "scrolled(isAtEnd: \(isAtEnd))"
            case .disclosureSettled(let isAtEnd): "disclosureSettled(isAtEnd: \(isAtEnd))"
            }
        }

        func apply(to latch: inout ChatFollowLatch) {
            switch self {
            case .reset: latch.reset()
            case .userScrollBegan: latch.userScrollBegan()
            case .userScrollEnded(let isAtEnd): latch.userScrollEnded(isAtEnd: isAtEnd)
            case .scrolled(let isAtEnd): latch.scrolled(isAtEnd: isAtEnd)
            case .disclosureSettled(let isAtEnd): latch.disclosureSettled(isAtEnd: isAtEnd)
            }
        }
    }

    struct Transition: Sendable, CustomTestStringConvertible {
        let start: Start
        let event: Event
        let isFollowing: Bool
        let isUserScrolling: Bool

        init(_ start: Start, _ event: Event, following: Bool, scrolling: Bool) {
            self.start = start
            self.event = event
            isFollowing = following
            isUserScrolling = scrolling
        }

        var testDescription: String {
            "\(start.rawValue) + \(event.name) -> following: \(isFollowing), scrolling: \(isUserScrolling)"
        }
    }

    /// Every reachable state against every event, with the scroll session
    /// tracked from a drag's start through the end of its momentum.
    static let transitions: [Transition] = [
        Transition(.following, .reset, following: true, scrolling: false),
        Transition(.following, .userScrollBegan, following: false, scrolling: true),
        // The end of a scroll the user never started is ignored either way.
        Transition(.following, .userScrollEnded(isAtEnd: true), following: true, scrolling: false),
        Transition(.following, .userScrollEnded(isAtEnd: false), following: true, scrolling: false),
        Transition(.following, .scrolled(isAtEnd: true), following: true, scrolling: false),
        // Layout compensation away from the end is not a user scroll.
        Transition(.following, .scrolled(isAtEnd: false), following: true, scrolling: false),
        Transition(.following, .disclosureSettled(isAtEnd: true), following: true, scrolling: false),
        Transition(.following, .disclosureSettled(isAtEnd: false), following: false, scrolling: false),

        Transition(.paused, .reset, following: true, scrolling: false),
        Transition(.paused, .userScrollBegan, following: false, scrolling: true),
        Transition(.paused, .userScrollEnded(isAtEnd: true), following: false, scrolling: false),
        Transition(.paused, .userScrollEnded(isAtEnd: false), following: false, scrolling: false),
        // A programmatic scroll that reaches the end re-arms.
        Transition(.paused, .scrolled(isAtEnd: true), following: true, scrolling: false),
        Transition(.paused, .scrolled(isAtEnd: false), following: false, scrolling: false),
        Transition(.paused, .disclosureSettled(isAtEnd: true), following: true, scrolling: false),
        Transition(.paused, .disclosureSettled(isAtEnd: false), following: false, scrolling: false),

        Transition(.scrolling, .reset, following: true, scrolling: false),
        Transition(.scrolling, .userScrollBegan, following: false, scrolling: true),
        Transition(.scrolling, .userScrollEnded(isAtEnd: true), following: true, scrolling: false),
        Transition(.scrolling, .userScrollEnded(isAtEnd: false), following: false, scrolling: false),
        // Passing the end mid-drag does not re-arm until the drag rests there.
        Transition(.scrolling, .scrolled(isAtEnd: true), following: false, scrolling: true),
        Transition(.scrolling, .scrolled(isAtEnd: false), following: false, scrolling: true),
        Transition(.scrolling, .disclosureSettled(isAtEnd: true), following: false, scrolling: true),
        Transition(.scrolling, .disclosureSettled(isAtEnd: false), following: false, scrolling: true),
    ]

    @Test("The transition table covers every state and event once")
    func tableIsComplete() {
        for start in Start.allCases {
            for event in Event.all {
                let matches = Self.transitions.filter { $0.start == start && $0.event == event }
                #expect(matches.count == 1, "\(start.rawValue) + \(event.name)")
            }
        }
        #expect(Self.transitions.count == Start.allCases.count * Event.all.count)
    }

    @Test("Each event moves each reachable state as the latch defines", arguments: transitions)
    func transition(_ transition: Transition) {
        var latch = transition.start.latch
        transition.event.apply(to: &latch)
        #expect(latch.isFollowing == transition.isFollowing)
        #expect(latch.isUserScrolling == transition.isUserScrolling)
    }

    @Test("A new latch follows with no scroll in progress")
    func initialState() {
        let latch = ChatFollowLatch()
        #expect(latch.isFollowing)
        #expect(!latch.isUserScrolling)
    }

    @Test("Reading history survives streaming growth until the user returns to the end")
    func readingWhileStreaming() {
        var latch = ChatFollowLatch()
        latch.scrolled(isAtEnd: true)  // An append pinned to the end.
        #expect(latch.isFollowing)

        latch.userScrollBegan()
        latch.scrolled(isAtEnd: true)  // The first scroll event is still inside the tolerance.
        latch.scrolled(isAtEnd: false)
        latch.userScrollEnded(isAtEnd: false)  // Momentum came to rest in history.
        #expect(!latch.isFollowing)

        latch.scrolled(isAtEnd: false)  // A streamed chunk grew a row; the anchor held.
        latch.userScrollEnded(isAtEnd: false)  // A stray end with no session.
        #expect(!latch.isFollowing)

        latch.userScrollBegan()
        latch.scrolled(isAtEnd: true)
        #expect(!latch.isFollowing)
        latch.userScrollEnded(isAtEnd: true)
        #expect(latch.isFollowing)
        #expect(!latch.isUserScrolling)
    }

    @Test("A reset mid-drag keeps the drag's end from turning following off")
    func resetDuringDrag() {
        var latch = ChatFollowLatch()
        latch.userScrollBegan()
        latch.reset()  // A send from a hardware keyboard while a finger drags.
        latch.scrolled(isAtEnd: false)
        latch.userScrollEnded(isAtEnd: false)
        #expect(latch.isFollowing)
    }

    @Test("A disclosure that leaves the list above the end stops following until Jump to Latest")
    func disclosureThenJump() {
        var latch = ChatFollowLatch()
        latch.disclosureSettled(isAtEnd: false)
        #expect(!latch.isFollowing)
        latch.reset()
        #expect(latch.isFollowing)
    }

    @Test("The end tolerance is 24 points and includes overscroll past the end")
    func endTolerance() {
        #expect(ChatFollowLatch.endTolerance == 24)
        #expect(ChatFollowLatch.isAtEnd(offset: 1_000, maxOffset: 1_000))
        #expect(ChatFollowLatch.isAtEnd(offset: 976, maxOffset: 1_000))
        #expect(!ChatFollowLatch.isAtEnd(offset: 975.5, maxOffset: 1_000))
        #expect(ChatFollowLatch.isAtEnd(offset: 1_040, maxOffset: 1_000))
        #expect(ChatFollowLatch.isAtEnd(offset: -20, maxOffset: -20))
    }
}
