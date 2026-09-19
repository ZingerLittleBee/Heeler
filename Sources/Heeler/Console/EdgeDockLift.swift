import SwiftUI
import UIKit

/// Long-press lifts a floating control off the terminal's edge, the drag that
/// follows slides it along that edge, and letting go docks it where it was
/// left. One modifier for every edge control, so they all move the same way.
///
/// The lift outlives the touch by a beat: a Button under the finger fires on
/// release, so a host keeps its own actions off while `isLifted`, and this
/// modifier clears the flag only after that release has been delivered.
struct EdgeDockLift: ViewModifier {
    @Binding var isLifted: Bool
    /// Vertical travel so far, in points, while lifted.
    let onMove: (CGFloat) -> Void
    /// Final vertical travel; the host docks and remembers the position.
    let onDrop: (CGFloat) -> Void

    static let longPressDuration: TimeInterval = 0.4
    /// How long the lift lingers after release, covering a Button's own tap.
    static let settleDelay: Duration = .milliseconds(250)
    static let liftedScale: CGFloat = 1.08

    func body(content: Content) -> some View {
        content
            .scaleEffect(isLifted ? Self.liftedScale : 1)
            .animation(.snappy(duration: 0.18), value: isLifted)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: Self.longPressDuration)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if !isLifted {
                            isLifted = true
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        onMove(drag?.translation.height ?? 0)
                    }
                    .onEnded { value in
                        guard isLifted else { return }
                        var travel: CGFloat = 0
                        if case .second(true, let drag) = value {
                            travel = drag?.translation.height ?? 0
                        }
                        onDrop(travel)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { @MainActor in
                            try? await Task.sleep(for: Self.settleDelay)
                            isLifted = false
                        }
                    })
    }
}

extension View {
    /// See ``EdgeDockLift``.
    func edgeDockLift(
        isLifted: Binding<Bool>,
        onMove: @escaping (CGFloat) -> Void,
        onDrop: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(EdgeDockLift(isLifted: isLifted, onMove: onMove, onDrop: onDrop))
    }
}
