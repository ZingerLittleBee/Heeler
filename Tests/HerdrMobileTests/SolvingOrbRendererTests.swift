import Foundation
import Testing

@testable import HerdrMobile

/// The solving orb behind the Working badge: a deterministic dotted
/// sphere whose bands scramble and then replay in reverse. The renderer
/// is pure, so the choreography is testable without rendering a frame.
@Suite("Solving orb renderer")
struct SolvingOrbRendererTests {
    @Test func presetFollowsTheRenderedSize() {
        #expect(SolvingOrbRenderer(size: 16).preset.latRings == SolvingOrbRenderer.small.latRings)
        #expect(SolvingOrbRenderer(size: 64).preset.latRings == SolvingOrbRenderer.large.latRings)
    }

    @Test func scrambleIsDeterministic() {
        let renderer = SolvingOrbRenderer(size: 16)
        #expect(renderer.dots(at: 3.7) == renderer.dots(at: 3.7))
        for move in SolvingOrbRenderer.moves {
            #expect((0...2).contains(move.axis))
            #expect(move.lo >= -1.0 && move.lo <= 0.5)
            #expect(abs(move.angle) == .pi / 2)
        }
    }

    @Test(arguments: [16.0, 64.0])
    func dotsStayInsideTheFrame(size: Double) {
        let renderer = SolvingOrbRenderer(size: size)
        for t in stride(from: 0.0, through: 13.0, by: 0.5) {
            let dots = renderer.dots(at: t)
            #expect(!dots.isEmpty)
            for dot in dots {
                #expect(dot.x - dot.radius >= 0 && dot.x + dot.radius <= size)
                #expect(dot.y - dot.radius >= 0 && dot.y + dot.radius <= size)
            }
        }
    }

    @Test func dotsArePaintedFarToNear() {
        let dots = SolvingOrbRenderer(size: 64).dots(at: 1.3)
        for (far, near) in zip(dots, dots.dropFirst()) {
            #expect(far.z <= near.z)
        }
    }

    /// The heartbeat is a palindrome: after `moveCount` forward slots the
    /// same moves unwind, and the rest window holds every band at zero —
    /// solved — until the next cycle.
    @Test func solveCycleScramblesThenUnwindsToSolved() {
        let count = SolvingOrbRenderer.moveCount
        let slot = SolvingOrbRenderer.slotDuration

        // Mid-scramble: earlier moves are locked in, one is mid-turn.
        let scrambling = SolvingOrbRenderer.solveCycle(at: 3.5 * slot)
        #expect(scrambling.active == 3)
        #expect(scrambling.amounts[0..<3].allSatisfy { $0 == 1 })
        #expect(scrambling.amounts[3] > 0 && scrambling.amounts[3] < 1)

        // Mid-unwind: the mirror slot turns the same move back.
        let unwinding = SolvingOrbRenderer.solveCycle(at: (2 * Double(count) - 3.5) * slot)
        #expect(unwinding.active == 3)
        #expect(unwinding.amounts[3] > 0 && unwinding.amounts[3] < 1)

        // Rest: everything has clicked back to solved.
        let resting = SolvingOrbRenderer.solveCycle(at: 2 * Double(count) * slot + 0.1)
        #expect(resting.active == -1)
        #expect(resting.amounts.allSatisfy { $0 == 0 })
    }

    /// The rest pose recurs every cycle at the same phase, so the orb
    /// returns to solved rather than accumulating twist over time.
    @Test func solvedPoseRecursEveryCycle() {
        let cycle = 2 * Double(SolvingOrbRenderer.moveCount) * SolvingOrbRenderer.slotDuration
            + SolvingOrbRenderer.restDuration
        for lap in 0..<5 {
            let resting = SolvingOrbRenderer.solveCycle(at: Double(lap) * cycle + cycle - 0.5)
            #expect(resting.active == -1)
            #expect(resting.amounts.allSatisfy { $0 == 0 })
        }
    }
}
