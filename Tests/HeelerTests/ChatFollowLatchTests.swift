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

        var testDescription: String {
            "\(start.rawValue) + \(event.name) -> following: \(isFollowing), scrolling: \(isUserScrolling)"
        }
    }

    /// Every reachable state against every event, as T3's reducer resolves
    /// it, with the scroll session tracked the way its feed tracks it.
    static let transitions: [Transition] = [
        Transition(start: .following, event: .reset, isFollowing: true, isUserScrolling: false),
        Transition(start: .following, event: .userScrollBegan, isFollowing: false, isUserScrolling: true),
        // The end of a scroll the user never started is ignored either way.
        Transition(start: .following, event: .userScrollEnded(isAtEnd: true), isFollowing: true, isUserScrolling: false),
        Transition(start: .following, event: .userScrollEnded(isAtEnd: false), isFollowing: true, isUserScrolling: false),
        Transition(start: .following, event: .scrolled(isAtEnd: true), isFollowing: true, isUserScrolling: false),
        // Layout compensation away from the end is not a user scroll.
        Transition(start: .following, event: .scrolled(isAtEnd: false), isFollowing: true, isUserScrolling: false),
        Transition(start: .following, event: .disclosureSettled(isAtEnd: true), isFollowing: true, isUserScrolling: false),
        Transition(start: .following, event: .disclosureSettled(isAtEnd: false), isFollowing: false, isUserScrolling: false),

        Transition(start: .paused, event: .reset, isFollowing: true, isUserScrolling: false),
        Transition(start: .paused, event: .userScrollBegan, isFollowing: false, isUserScrolling: true),
        Transition(start: .paused, event: .userScrollEnded(isAtEnd: true), isFollowing: false, isUserScrolling: false),
        Transition(start: .paused, event: .userScrollEnded(isAtEnd: false), isFollowing: false, isUserScrolling: false),
        // A programmatic scroll that reaches the end re-arms.
        Transition(start: .paused, event: .scrolled(isAtEnd: true), isFollowing: true, isUserScrolling: false),
        Transition(start: .paused, event: .scrolled(isAtEnd: false), isFollowing: false, isUserScrolling: false),
        Transition(start: .paused, event: .disclosureSettled(isAtEnd: true), isFollowing: true, isUserScrolling: false),
        Transition(start: .paused, event: .disclosureSettled(isAtEnd: false), isFollowing: false, isUserScrolling: false),

        Transition(start: .scrolling, event: .reset, isFollowing: true, isUserScrolling: false),
        Transition(start: .scrolling, event: .userScrollBegan, isFollowing: false, isUserScrolling: true),
        Transition(start: .scrolling, event: .userScrollEnded(isAtEnd: true), isFollowing: true, isUserScrolling: false),
        Transition(start: .scrolling, event: .userScrollEnded(isAtEnd: false), isFollowing: false, isUserScrolling: false),
        // Passing the end mid-drag does not re-arm until the drag rests there.
        Transition(start: .scrolling, event: .scrolled(isAtEnd: true), isFollowing: false, isUserScrolling: true),
        Transition(start: .scrolling, event: .scrolled(isAtEnd: false), isFollowing: false, isUserScrolling: true),
        Transition(start: .scrolling, event: .disclosureSettled(isAtEnd: true), isFollowing: false, isUserScrolling: true),
        Transition(start: .scrolling, event: .disclosureSettled(isAtEnd: false), isFollowing: false, isUserScrolling: true),
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

    @Test("Each event moves each reachable state as T3's reducer does", arguments: transitions)
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
