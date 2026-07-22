import Foundation

/// The byte pipe between an Attach store and its SwiftTerm view. Bytes that
/// arrive before the view exists are buffered, so opening output is never lost.
@MainActor
final class TerminalByteFeed {
    private var sink: ((Data) -> Void)?
    private var buffered: [Data] = []

    /// Registers the consumer, flushing anything buffered. Later attaches
    /// replace the sink when SwiftUI remakes the representable view.
    func attach(_ sink: @escaping (Data) -> Void) {
        self.sink = sink
        let pending = buffered
        buffered.removeAll(keepingCapacity: true)
        for data in pending {
            sink(data)
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        if let sink {
            sink(data)
        } else {
            buffered.append(data)
        }
    }
}
