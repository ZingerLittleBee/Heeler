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

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        if let sink {
            sink.receive(data)
            return
        }
        // Opening bytes wait for the first surface. Once a surface has gone
        // away, its old pipeline must not replay stale bytes into a later one.
        guard !hasAttached else { return }
        buffered.append(data)
    }
}
