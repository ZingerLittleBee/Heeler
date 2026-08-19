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
