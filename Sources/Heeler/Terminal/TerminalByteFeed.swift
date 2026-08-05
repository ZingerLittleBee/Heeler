import Foundation

/// The surface a `TerminalByteFeed` writes into.
///
/// Held weakly by the feed on purpose: SwiftUI remakes the representable view
/// whenever it likes, and the feed is the only place that can tell "the user
/// saw these bytes" from "these bytes went into a view that no longer exists"
/// (#141). A closure sink cannot answer that question — `[weak view]` swallows
/// the difference — so the sink is an object the feed can check.
@MainActor
protocol TerminalByteSink: AnyObject {
    func receive(_ data: Data)
}

/// The byte pipe between an Attach store and its terminal view. Bytes that
/// arrive before the view exists are buffered, so opening output is never lost.
@MainActor
final class TerminalByteFeed {
    /// What became of a chunk handed to ``write(_:)``.
    ///
    /// Only `.delivered` means the bytes are on a surface the user is looking
    /// at. The other two are both "the screen did not change", by different
    /// routes, and callers that need proof of a visible repaint must treat
    /// them as such — see `AttachTerminalStore.consume`.
    enum Delivery: Equatable {
        /// Written into a live surface.
        case delivered
        /// No surface has attached yet; held for the first one that does.
        case buffered
        /// A surface attached and has since gone away. The bytes are lost and
        /// nothing on screen changed.
        case dropped
    }

    private weak var sink: (any TerminalByteSink)?
    /// Whether a surface has ever attached. Distinguishes "no surface yet",
    /// whose bytes are still coming, from "the surface is gone", whose bytes
    /// are not.
    private var hasAttached = false
    private var buffered: [Data] = []

    /// Registers the consumer, flushing anything buffered. Later attaches
    /// replace the sink when SwiftUI remakes the representable view.
    func attach(_ sink: any TerminalByteSink) {
        self.sink = sink
        hasAttached = true
        let pending = buffered
        buffered.removeAll(keepingCapacity: true)
        for data in pending {
            sink.receive(data)
        }
    }

    @discardableResult
    func write(_ data: Data) -> Delivery {
        // An empty chunk proves nothing: the transport yields only non-empty
        // ones (`HeelerSSHTransport.runAttachChannel`), and reporting this as
        // delivered would hand a liveness probe a free answer.
        guard !data.isEmpty else { return .dropped }
        if let sink {
            sink.receive(data)
            return .delivered
        }
        guard !hasAttached else { return .dropped }
        buffered.append(data)
        return .buffered
    }
}
