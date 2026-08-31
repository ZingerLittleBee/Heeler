#if DEBUG
import Foundation
import os

/// Debug-only timing markers for one Agent Detail Attach pipeline.
///
/// The trace intentionally contains no Host, pane, command, or terminal data.
/// A replacement pipeline receives a new identifier, making initial entry and
/// every foreground recovery independently searchable in Instruments.
@MainActor
final class AttachRestorationTrace {
    enum Phase: Hashable {
        case foregroundRecoveryStarted
        case foregroundRecoveryAborted
        case agentDetailVisible
        case agentSnapshotSwitcherAvailable
        case transportAcquired
        case attachRequestStarted
        case attachPTYOpened
        case terminalSurfaceAttached
        case initialResize
        case firstOutputBytes
    }

    private static let log = OSLog(
        subsystem: "dev.bybee.heeler",
        category: "attach-restoration")

    private let traceID: String
    private let signpostID: OSSignpostID
    private var state = AttachRestorationTraceState()

    init(traceID: UUID = UUID()) {
        let identifier = traceID.uuidString.lowercased()
        self.traceID = identifier
        signpostID = OSSignpostID(log: Self.log)
    }

    func emit(_ phase: Phase, generation: UInt64? = nil) {
        guard state.record(phase) else { return }
        let generation = generation.map { String($0) } ?? "none"
        switch phase {
        case .foregroundRecoveryStarted:
            os_signpost(.event, log: Self.log, name: "foreground_recovery_started", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .foregroundRecoveryAborted:
            os_signpost(.event, log: Self.log, name: "foreground_recovery_aborted", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .agentDetailVisible:
            os_signpost(.event, log: Self.log, name: "agent_detail_visible", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .agentSnapshotSwitcherAvailable:
            os_signpost(.event, log: Self.log, name: "agent_snapshot_switcher_available", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .transportAcquired:
            os_signpost(.event, log: Self.log, name: "transport_acquired", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .attachRequestStarted:
            // `attachTerminal` owns remote target resolution and PTY open as
            // one operation. This marks only the app-observable request edge.
            os_signpost(.event, log: Self.log, name: "attach_request_started", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .attachPTYOpened:
            // This is the app-observable completion: `attachTerminal` returned.
            os_signpost(.event, log: Self.log, name: "attach_pty_opened", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .terminalSurfaceAttached:
            os_signpost(.event, log: Self.log, name: "terminal_surface_attached", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .initialResize:
            os_signpost(.event, log: Self.log, name: "initial_resize", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        case .firstOutputBytes:
            // Feed receipt, not a Ghostty renderer-presented frame.
            os_signpost(.event, log: Self.log, name: "first_output_bytes", signpostID: signpostID,
                "trace_id=%{public}s generation=%{public}s", traceID, generation)
        }
    }

    var recordedPhases: Set<Phase> { state.emittedPhases }
}

/// Debug-only bridge across the Attach runner boundary. It deliberately owns
/// only app-observable edges, not remote herdr implementation details.
struct AttachRestorationTraceEvents: Sendable {
    private let trace: AttachRestorationTrace
    private let generation: @MainActor @Sendable () -> UInt64?

    init(
        trace: AttachRestorationTrace,
        generation: @escaping @MainActor @Sendable () -> UInt64?
    ) {
        self.trace = trace
        self.generation = generation
    }

    @MainActor
    func attachRequestDidStart() {
        trace.emit(.attachRequestStarted, generation: generation())
    }

    @MainActor
    func attachChannelDidOpen() {
        trace.emit(.attachPTYOpened, generation: generation())
    }
}

/// The once-only phase gate keeps SwiftUI's repeated body and appearance work
/// from making one Attach pipeline look like several recovery attempts.
struct AttachRestorationTraceState {
    private(set) var emittedPhases: Set<AttachRestorationTrace.Phase> = []

    mutating func record(_ phase: AttachRestorationTrace.Phase) -> Bool {
        emittedPhases.insert(phase).inserted
    }
}
#endif
