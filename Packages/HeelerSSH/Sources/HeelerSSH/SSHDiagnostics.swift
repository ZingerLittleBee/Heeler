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
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

/// One async operation owns its phase, timeout deduplication, and timings.
/// A session's actor can admit another operation while this one is waiting;
/// storing these values on that actor attributes failures to the wrong caller.
/// The task-local scope ends with the operation, including successful calls.
final class SSHDiagnosticOperation: Sendable {
    @TaskLocal static var current: SSHDiagnosticOperation?

    private struct State {
        var step = ""
        var stepStarted = ContinuousClock.now
        var timings: [(name: String, elapsed: Duration)] = []
        var timeoutNoted = false
        var lastResult: Int32?
        var waitCount = 0
        var lastWait = "none"
    }

    private let phase: String
    private let budget: Duration?
    private let started = ContinuousClock.now
    private let state = Mutex(State())

    init(phase: String, budget: Duration?) {
        self.phase = phase
        self.budget = budget
    }

    var step: String {
        get { state.withLock { $0.step } }
        set {
            state.withLock { state in
                guard state.step != newValue else { return }
                let now = ContinuousClock.now
                if !state.step.isEmpty {
                    let elapsed = state.stepStarted.duration(to: now)
                    if let index = state.timings.firstIndex(where: { $0.name == state.step }) {
                        state.timings[index].elapsed += elapsed
                    } else {
                        state.timings.append((state.step, elapsed))
                    }
                }
                state.step = newValue
                state.stepStarted = now
                state.lastResult = nil
                state.lastWait = "none"
            }
        }
    }

    var context: String {
        state.withLock { $0.step.isEmpty ? phase : "\(phase), \($0.step)" }
    }

    func recordResult(_ result: Int32) {
        state.withLock { $0.lastResult = result }
    }

    func recordWait(_ wait: String) {
        state.withLock {
            $0.waitCount += 1
            $0.lastWait = wait
        }
    }

    func noteTimeout() {
        let shouldNote = state.withLock { state in
            guard !state.timeoutNoted else { return false }
            state.timeoutNoted = true
            return true
        }
        if shouldNote {
            SSHDiagnostics.note("\(context) timed out \(timingDetails)")
        }
    }

    var timingDetails: String {
        state.withLock { state in
            let now = ContinuousClock.now
            var fields = ["elapsed=\(Self.seconds(started.duration(to: now)))s"]
            if let budget { fields.append("budget=\(Self.seconds(budget))s") }
            for timing in state.timings {
                fields.append("\(timing.name)=\(Self.seconds(timing.elapsed))s")
            }
            if !state.step.isEmpty {
                fields.append("\(state.step)=\(Self.seconds(state.stepStarted.duration(to: now)))s")
            }
            if let result = state.lastResult { fields.append("last_result=\(result)") }
            fields.append("waits=\(state.waitCount)")
            fields.append("last_wait=\(state.lastWait)")
            return "[\(fields.joined(separator: "; "))]"
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
