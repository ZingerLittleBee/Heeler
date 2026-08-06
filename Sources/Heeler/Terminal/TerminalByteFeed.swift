import Foundation

/// The surface a `TerminalByteFeed` writes into.
///
/// Held weakly by the feed on purpose: SwiftUI remakes the representable view
/// whenever it likes. An object sink lets the feed distinguish a live receiver
/// from a released one; it does not reveal whether the receiver drew or
/// presented the bytes (#141).
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
    /// None of these cases acknowledges drawing. `.delivered` means only that
    /// a non-empty chunk was synchronously handed to a live sink object.
    enum Delivery: Equatable {
        /// Handed to a live sink object; presentation remains unobserved.
        case delivered
        /// No sink has attached yet; held for the first one that does.
        case buffered
        /// A sink attached and has since gone away. The bytes are lost.
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
