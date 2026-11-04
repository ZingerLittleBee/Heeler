import Foundation
import Testing

@testable import Heeler

/// The solving orb behind the Working badge: a deterministic dotted
/// sphere whose bands scramble and then replay in reverse. The renderer
/// is pure, so the choreography is testable without rendering a frame.
@Suite("Solving orb renderer")
struct SolvingOrbRendererTests {
    @Test func presetFollowsTheRenderedSize() {
        #expect(SolvingOrbRenderer(size: 16).preset.speed == SolvingOrbRenderer.small.speed)
        #expect(SolvingOrbRenderer(size: 64).preset.speed == SolvingOrbRenderer.large.speed)
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

    /// Frames come from precomputed lattice states plus one partial turn;
    /// they must match, bit for bit, the original renderer that turned every
    /// dot through each started move on every frame.
    @Test(arguments: [10.0, 12.0, 16.0, 64.0])
    func precomputedFramesMatchTurningEveryMove(size: Double) {
        let renderer = SolvingOrbRenderer(size: size)
        let cycle = 2 * Double(SolvingOrbRenderer.moveCount) * SolvingOrbRenderer.slotDuration
            + SolvingOrbRenderer.restDuration
        #expect(renderer.lattice.states.count == SolvingOrbRenderer.moveCount + 1)
        for t in stride(from: 0.0, through: 2 * cycle, by: 0.013) {
            #expect(renderer.dots(at: t) == Self.referenceDots(renderer, at: t))
        }
    }

    /// The pre-#434 renderer, kept verbatim as the reference.
    private static func referenceDots(
        _ renderer: SolvingOrbRenderer, at t: Double
    ) -> [SolvingOrbRenderer.Dot] {
        let size = renderer.size
        let preset = renderer.preset
        let center = size / 2
        let radius = size / 2 * 0.82
        let yaw = t * 0.55
        let tilt = 0.35 + 0.1 * sin(t * 0.9)
        let (sy, cy) = (sin(yaw), cos(yaw))
        let (st, ct) = (sin(tilt), cos(tilt))
        let radiusScale = pow(size / 300, 0.6)
        let (amounts, active) = SolvingOrbRenderer.solveCycle(at: t)

        var dots: [SolvingOrbRenderer.Dot] = []
        for ring in 0...preset.latRings {
            let lat = -Double.pi / 2 + Double(ring) / Double(preset.latRings) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * preset.lonDensity).rounded()))
            for step in 0..<lonCount {
                let lon = Double(step) / Double(lonCount) * 2 * .pi
                var (x, y, z) = (cosLat * cos(lon), sinLat, cosLat * sin(lon))
                var inActive = false
                for i in 0..<SolvingOrbRenderer.moves.count where amounts[i] > 0 {
                    let move = SolvingOrbRenderer.moves[i]
                    let coordinate = move.axis == 0 ? x : move.axis == 1 ? y : z
                    guard coordinate >= move.lo, coordinate < move.lo + 0.5 else { continue }
                    if i == active { inActive = true }
                    let a = move.angle * amounts[i]
                    let ca = cos(a)
                    let sa = sin(a)
                    switch move.axis {
                    case 0: (y, z) = (y * ca - z * sa, y * sa + z * ca)
                    case 1: (x, z) = (x * ca + z * sa, -x * sa + z * ca)
                    default: (x, y) = (x * ca - y * sa, x * sa + y * ca)
                    }
                }
                let x1 = x * cy + z * sy
                let z1 = -x * sy + z * cy
                let y1 = y * ct - z1 * st
                let z2 = y * st + z1 * ct
                let depth = (z2 + 1) / 2
                dots.append(SolvingOrbRenderer.Dot(
                    x: center + x1 * radius,
                    y: center - y1 * radius,
                    z: z2,
                    radius: (preset.dotBase + preset.dotDepth * depth
                        + (inActive ? preset.dotActive : 0)) * radiusScale,
                    white: 0.62 - 0.54 * depth - (inActive ? 0.14 : 0)))
            }
        }
        dots.sort { $0.z < $1.z }
        return dots
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
