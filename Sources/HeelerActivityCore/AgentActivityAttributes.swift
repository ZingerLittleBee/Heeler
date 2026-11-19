#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

/// Static Live Activity attributes for one Host (docs/agents/live-activity-contract.md).
/// The type name is shipped-forever: APNs `attributes-type` must match it
/// exactly if push-to-start is ever added.
///
/// `ContentState` is a plain Codable value so non-UI targets can decode an
/// update without linking ActivityKit. The ActivityKit conformance is
/// compiled only when the framework is available.
struct AgentActivityAttributes: Codable, Hashable, Sendable {
    var hostID: String

    /// Dynamic Live Activity content. Every field is a primitive so
    /// ActivityKit's default `JSONDecoder` (no date/key strategies) can
    /// decode an APNs `content-state` without dropping the update.
    struct ContentState: Codable, Hashable, Sendable {
        var counts: Counts
        var envelope: Envelope?

        struct Counts: Codable, Hashable, Sendable {
            var working: Int
            var blocked: Int
            var done: Int

            /// A Host that needs the user outranks every other, and among
            /// equals the most recently updated wins: the update time, in
            /// whole seconds, plus a tier far above any time for Blocked.
            /// The relay derives the same score from its push timestamp.
            func relevanceScore(at date: Date) -> Double {
                guard working + blocked + done > 0 else { return 0 }
                let seconds = date.timeIntervalSince1970.rounded(.down)
                return blocked > 0 ? Self.blockedRelevanceTier + seconds : seconds
            }

            /// An update with the same counts keeps the score the activity
            /// has, so reopening the app or a title change does not make a
            /// Host look newly changed or undo the relay's push time.
            func relevanceScore(
                at date: Date, replacing previous: (counts: Self, score: Double)?
            ) -> Double {
                if let previous, previous.counts == self { return previous.score }
                return relevanceScore(at: date)
            }

            static let blockedRelevanceTier: Double = 10_000_000_000
        }

        /// Cleartext `{v,kid,n,ct}` frame carried inside content-state.
        /// Opening it is `AgentActivityEnvelope`'s job; an absent or
        /// undecryptable envelope degrades rendering to counts-only.
        struct Envelope: Codable, Hashable, Sendable {
            var v: Int
            var kid: String
            var n: String
            var ct: String
        }
    }
}

#if canImport(ActivityKit)
extension AgentActivityAttributes: ActivityAttributes {}
#endif
