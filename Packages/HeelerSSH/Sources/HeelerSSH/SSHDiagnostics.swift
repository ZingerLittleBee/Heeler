import Foundation
import Synchronization

/// Failure diagnostics for the reader of a CI log, not for the program.
///
/// `SSHError` is deliberately coarse: the app classifies against a handful of
/// cases and must not grow a branch per libssh2 code. That coarseness is also
/// why a fixture-backed E2E failure on a loaded runner could not be
/// diagnosed (#343): `.connectionFailed` and `.timedOut` said nothing about
/// which phase gave up or what libssh2 reported. Sinks receive one line per
/// failure naming the phase, the libssh2 code, and its message. With no sink
/// installed, nothing is formatted and nothing is retained.
public enum SSHDiagnostics {
    public typealias Sink = @Sendable (String) -> Void

    public struct SinkToken: Sendable, Hashable {
        fileprivate let id: UInt64
    }

    private struct Registry {
        var nextID: UInt64 = 1
        var sinks: [(id: UInt64, sink: Sink)] = []
    }

    private static let registry = Mutex(Registry())

    /// Sinks are additive so a test recorder and a log-printing sink can be
    /// installed at the same time without one silently replacing the other.
    @discardableResult
    public static func addSink(_ sink: @escaping Sink) -> SinkToken {
        registry.withLock { registry in
            let id = registry.nextID
            registry.nextID &+= 1
            registry.sinks.append((id: id, sink: sink))
            return SinkToken(id: id)
        }
    }

    public static func removeSink(_ token: SinkToken) {
        registry.withLock { registry in
            registry.sinks.removeAll { $0.id == token.id }
        }
    }

    /// A sink that prints each line, prefixed with a UTC timestamp in the
    /// format GitHub uses for job log lines and the CI gate uses for the
    /// fixture sshd logs, so the three can be read against each other.
    public static func printingSink(prefix: String = "[HeelerSSH]") -> Sink {
        { message in
            print("\(prefix) \(timestamp()) \(message)")
        }
    }

    static var isEnabled: Bool {
        registry.withLock { !$0.sinks.isEmpty }
    }

    public static func note(_ message: @autoclosure () -> String) {
        let sinks = registry.withLock { $0.sinks.map(\.sink) }
        guard !sinks.isEmpty else { return }
        let line = message()
        for sink in sinks { sink(line) }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
