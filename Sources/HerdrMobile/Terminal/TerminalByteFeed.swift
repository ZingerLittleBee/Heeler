import Foundation

/// The byte pipe between a terminal store and the SwiftTerm view: stores
/// write decoded terminal bytes, the view attaches as the sink once it
/// exists. Bytes written before the view's first layout are buffered so
/// backfill can never race the view into the void. Shared by Observe (#9)
/// and Attach (#11), which differ only in whether an input path exists.
@MainActor
final class TerminalByteFeed {
    private var sink: ((Data) -> Void)?
    private var buffered = Data()

    /// Registers the consumer, flushing anything buffered. Later attaches
    /// replace the sink (a representable view can be remade by SwiftUI).
    func attach(_ sink: @escaping (Data) -> Void) {
        self.sink = sink
        if !buffered.isEmpty {
            let pending = buffered
            buffered = Data()
            sink(pending)
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
