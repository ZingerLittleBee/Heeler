import Foundation
import Network
import Synchronization

/// The device's network changing under the app: Wi-Fi joined or left, the
/// cellular link coming or going, another network on the same interface.
enum NetworkPathChanges {
    /// What tells one network path from the next.
    struct Signature: Equatable, Sendable {
        let isSatisfied: Bool
        let interfaces: [String]
        let gateways: [String]

        init(isSatisfied: Bool, interfaces: [String], gateways: [String]) {
            self.isSatisfied = isSatisfied
            self.interfaces = interfaces
            self.gateways = gateways
        }

        init(_ path: NWPath) {
            self.init(
                isSatisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map { "\($0.type):\($0.name)" },
                gateways: path.gateways.map { "\($0)" })
        }
    }

    /// Whether `next` is a change worth acting on. The first path the monitor
    /// reports is where the device already was.
    static func isChange(from previous: Signature?, to next: Signature) -> Bool {
        guard let previous else { return false }
        return previous != next
    }

    /// One element for each change, for as long as the stream is read. A
    /// burst that arrives while the reader is busy leaves a single element.
    static func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            let last = Mutex<Signature?>(nil)
            monitor.pathUpdateHandler = { path in
                let next = Signature(path)
                let changed = last.withLock { previous in
                    defer { previous = next }
                    return isChange(from: previous, to: next)
                }
                if changed { continuation.yield() }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.bybee.heeler.network-path"))
        }
    }
}
