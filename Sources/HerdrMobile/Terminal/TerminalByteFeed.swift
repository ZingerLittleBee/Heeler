import Foundation

/// The byte pipe between a terminal store and the SwiftTerm view: stores
/// write decoded terminal bytes, the view attaches as the sink once it
/// exists. Bytes written before the view's first layout are buffered so
/// backfill can never race the view into the void. Shared by Observe (#9)
/// and Attach (#11), which differ only in whether an input path exists.
@MainActor
final class TerminalByteFeed {
    enum Delivery {
        case bytes(Data)
        case historySnapshot(Data)

        var data: Data {
            switch self {
            case .bytes(let data), .historySnapshot(let data):
                data
            }
        }
    }

    private var sink: ((Delivery) -> Void)?
    private var buffered: [Delivery] = []

    /// Registers the consumer, flushing anything buffered. Later attaches
    /// replace the sink (a representable view can be remade by SwiftUI).
    func attach(_ sink: @escaping (Data) -> Void) {
        attachDeliveries { sink($0.data) }
    }

    func attachDeliveries(_ sink: @escaping (Delivery) -> Void) {
        self.sink = sink
        let pending = buffered
        buffered.removeAll(keepingCapacity: true)
        for delivery in pending {
            sink(delivery)
        }
    }

    func write(_ data: Data) {
        deliver(.bytes(data))
    }

    func writeHistorySnapshot(_ data: Data) {
        deliver(.historySnapshot(data))
    }

    private func deliver(_ delivery: Delivery) {
        let data = delivery.data
        guard !data.isEmpty else { return }
        if let sink {
            sink(delivery)
        } else {
            buffered.append(delivery)
        }
    }
}
