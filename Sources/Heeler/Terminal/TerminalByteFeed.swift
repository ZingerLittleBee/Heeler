import Foundation

/// The surface a `TerminalByteFeed` writes into.
///
/// Held weakly by the feed on purpose: SwiftUI remakes the representable view
/// whenever it likes. An object sink lets the feed distinguish a live receiver
/// from a released one; it does not reveal whether the receiver drew or
/// presented the bytes (#141).
@MainActor
protocol TerminalByteSink: AnyObject {
    /// Output that no feed has read modes from.
    func receive(_ data: Data)
    /// Output whose modes are already in the feed's source.
    func receiveTracked(_ data: Data)
    /// The modes of the stream this sink now shows.
    func adoptModes(_ modes: TerminalModeSource)
}

extension TerminalByteSink {
    func receiveTracked(_ data: Data) {
        receive(data)
    }

    func adoptModes(_ modes: TerminalModeSource) {}
}

/// The modes of one terminal stream, shared by its pipeline and the view that
/// shows it. A view can be remade at any time; the program that set the modes
/// is still running, so they outlive the view.
@MainActor
final class TerminalModeSource {
    private(set) var tracker = TerminalModeTracker()
    /// Alternate screen or mouse tracking flipped.
    var onScrollModesChange: (() -> Void)?

    func receive(_ data: Data) {
        change { $0.receive(data) }
    }

    func reset() {
        change { $0 = TerminalModeTracker() }
    }

    private func change(_ update: (inout TerminalModeTracker) -> Void) {
        let wasAlternateScreen = tracker.isAlternateScreen
        let didTrackMouse = tracker.tracksMouse
        update(&tracker)
        if tracker.isAlternateScreen != wasAlternateScreen
            || tracker.tracksMouse != didTrackMouse
        {
            onScrollModesChange?()
        }
    }
}

/// The byte pipe between an Attach store and its terminal view. Bytes that
/// arrive before the view exists are buffered, so opening output is never lost.
@MainActor
final class TerminalByteFeed {
    /// Read from every chunk before the view receives it, including chunks no
    /// view is around to receive.
    let modes = TerminalModeSource()
    private weak var sink: (any TerminalByteSink)?
    /// Whether a surface has ever attached. Distinguishes "no surface yet",
    /// whose bytes are still coming, from "the surface is gone", whose bytes
    /// are not.
    private var hasAttached = false
    private var buffered: [(data: Data, consumed: (@MainActor (Int) -> Void)?)] = []
    /// What the surface showing this feed looks like, kept across remounts.
    private(set) var displayFacts: TerminalDisplayFacts?
    var onDisplayFactsChange: ((TerminalDisplayFacts) -> Void)?

    /// Registers the consumer, flushing anything buffered. Later attaches
    /// replace the sink when SwiftUI remakes the representable view.
    func attach(_ sink: any TerminalByteSink) {
        self.sink = sink
        hasAttached = true
        sink.adoptModes(modes)
        let pending = buffered
        buffered.removeAll(keepingCapacity: true)
        for (data, consumed) in pending {
            sink.receiveTracked(data)
            consumed?(data.count)
        }
    }

    func updateDisplayFacts(_ change: (inout TerminalDisplayFacts) -> Void) {
        var facts = displayFacts ?? TerminalDisplayFacts()
        change(&facts)
        guard facts != displayFacts else { return }
        displayFacts = facts
        onDisplayFactsChange?(facts)
    }

    /// Whether `candidate` is the surface currently receiving this feed's bytes.
    /// The hosted terminal binds in `TerminalScreenView.makeUIView`; a
    /// replacement pipeline's feed is not attached until that remount runs.
    func isAttached(to candidate: any TerminalByteSink) -> Bool {
        sink === candidate
    }

    /// `consumed` runs once the surface has taken the bytes, or once there is
    /// no surface left to take them, and never before.
    func write(_ data: Data, consumed: (@MainActor (Int) -> Void)? = nil) {
        guard !data.isEmpty else { return }
        modes.receive(data)
        if let sink {
            sink.receiveTracked(data)
            consumed?(data.count)
            return
        }
        // Opening bytes wait for the first surface. Once a surface has gone
        // away, its old pipeline must not replay stale bytes into a later one.
        guard !hasAttached else {
            consumed?(data.count)
            return
        }
        buffered.append((data, consumed))
    }
}
