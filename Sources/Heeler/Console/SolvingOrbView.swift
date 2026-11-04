import SwiftUI

/// The "solving" thought-orb: a dotted sphere whose bands twist in eased
/// quarter turns — rapid moves scramble, then replay in reverse so every
/// band clicks back to solved, rest, repeat. Depth is carried by dot size
/// and ink weight alone; on dark substrates the ink is mirrored so near
/// dots read bright.
///
/// Algorithm ported from thinking-orbs by Jakub Antalik (MIT,
/// https://github.com/Jakubantalik/thinking-orbs), "solving" state, with
/// the library's count/size multipliers pre-resolved into plain numbers.
struct SolvingOrbRenderer: Sendable {
    struct Dot: Equatable, Sendable {
        var x: Double
        var y: Double
        var z: Double
        var radius: Double
        /// Ink value: 0 = darkest ink on paper. Mirrored on dark themes.
        var white: Double
    }

    /// One shipped tuning (the library ships 64pt and 20pt variants).
    struct Preset: Sendable {
        /// Multiplier on wall-clock seconds; all motion terms consume the
        /// scaled time.
        let speed: Double
        let latRings: Int
        let lonDensity: Double
        let dotBase: Double
        let dotDepth: Double
        let dotActive: Double
    }

    static let large = Preset(
        speed: 1.82, latRings: 9, lonDensity: 24,
        dotBase: 0.63, dotDepth: 1.785, dotActive: 0.315)
    /// Deviates from the library's 20px tuning (4 rings, ~30 fat dots):
    /// at badge size that read as loose scatter, not a sphere. Small orbs
    /// keep the dense lattice and only take the faster clock; the painter's
    /// minimum dot radius keeps the finer dots legible on Retina.
    static let small = Preset(
        speed: 1.95, latRings: 9, lonDensity: 24,
        dotBase: 0.63, dotDepth: 1.785, dotActive: 0.315)

    /// A quarter-turn of one band of the sphere: every lattice point whose
    /// `axis` coordinate falls in [lo, lo + 0.5) rotates by `angle`.
    struct Move: Sendable {
        let axis: Int
        let lo: Double
        let angle: Double
    }

    static let moveCount = 14
    static let slotDuration = 0.42
    static let restDuration = 1.2

    /// The fixed scramble, derived from a deterministic hash so every orb
    /// plays the same choreography.
    static let moves: [Move] = (0..<moveCount).map { i in
        let index = Double(i)
        let axis = min(2, Int(hash(index, 2.3) * 3))
        let lo = -1.0 + 0.5 * Double(min(3, Int(hash(index, 5.9) * 4)))
        let direction: Double = hash(index, 7.7) < 0.5 ? 1 : -1
        return Move(axis: axis, lo: lo, angle: direction * .pi / 2)
    }

    /// The sphere's dot lattice before and after each move of the scramble:
    /// `states[k]` holds every point once moves `0..<k` have fully turned.
    /// Any frame is one of these states plus at most one partial turn, so a
    /// frame turns each dot once instead of up to `moveCount` times.
    struct Lattice: Sendable {
        struct Point: Sendable {
            var x: Double
            var y: Double
            var z: Double
        }

        let states: [[Point]]

        init(latRings: Int, lonDensity: Double) {
            var points: [Point] = []
            for ring in 0...latRings {
                let lat = -Double.pi / 2 + Double(ring) / Double(latRings) * .pi
                let cosLat = cos(lat)
                let sinLat = sin(lat)
                let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
                for step in 0..<lonCount {
                    let lon = Double(step) / Double(lonCount) * 2 * .pi
                    points.append(Point(x: cosLat * cos(lon), y: sinLat, z: cosLat * sin(lon)))
                }
            }
            var states = [points]
            for move in SolvingOrbRenderer.moves {
                points = points.map { SolvingOrbRenderer.turn($0, by: move, amount: 1).point }
                states.append(points)
            }
            self.states = states
        }
    }

    static let smallLattice = Lattice(latRings: small.latRings, lonDensity: small.lonDensity)
    static let largeLattice = Lattice(latRings: large.latRings, lonDensity: large.lonDensity)

    let size: Double
    let preset: Preset
    let lattice: Lattice

    init(size: Double) {
        self.size = size
        let isSmall = size <= 40
        self.preset = isSmall ? Self.small : Self.large
        self.lattice = isSmall ? Self.smallLattice : Self.largeLattice
    }

    /// Deterministic hash in [0, 1).
    private static func hash(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    /// The solver heartbeat: eased moves scramble for `count` slots, then
    /// replay in reverse (palindrome), rest, repeat. Returns how far each
    /// move has turned (0...1) and which one is mid-turn.
    static func solveCycle(at time: Double) -> (amounts: [Double], active: Int) {
        let count = moveCount
        let cycle = 2 * Double(count) * slotDuration + restDuration
        let tc = time.truncatingRemainder(dividingBy: cycle)
        var amounts = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDuration {
            let slot = Int(tc / slotDuration)
            let p = (tc - Double(slot) * slotDuration) / slotDuration
            let clamped = min(1, p / 0.7)
            let eased = 1 - pow(1 - clamped, 3)
            if slot < count {
                for i in 0..<slot { amounts[i] = 1 }
                amounts[slot] = eased
                active = slot
            } else {
                let unwinding = 2 * count - 1 - slot
                for i in 0..<unwinding { amounts[i] = 1 }
                amounts[unwinding] = 1 - eased
                active = unwinding
            }
        }
        return (amounts, active)
    }

    /// Turns `point` by `amount` of `move` when it lies in the move's band.
    private static func turn(
        _ point: Lattice.Point, by move: Move, amount: Double
    ) -> (point: Lattice.Point, inBand: Bool) {
        var (x, y, z) = (point.x, point.y, point.z)
        let coordinate = move.axis == 0 ? x : move.axis == 1 ? y : z
        guard coordinate >= move.lo, coordinate < move.lo + 0.5 else { return (point, false) }
        let a = move.angle * amount
        let ca = cos(a)
        let sa = sin(a)
        switch move.axis {
        case 0:
            (y, z) = (y * ca - z * sa, y * sa + z * ca)
        case 1:
            (x, z) = (x * ca + z * sa, -x * sa + z * ca)
        default:
            (x, y) = (x * ca - y * sa, x * sa + y * ca)
        }
        return (Lattice.Point(x: x, y: y, z: z), true)
    }

    /// One frame of the orb at scaled time `t`, z-sorted far → near.
    func dots(at t: Double) -> [Dot] {
        let center = size / 2
        let radius = size / 2 * 0.82
        let yaw = t * 0.55
        let tilt = 0.35 + 0.1 * sin(t * 0.9)
        let (sy, cy) = (sin(yaw), cos(yaw))
        let (st, ct) = (sin(tilt), cos(tilt))
        // Dot radii were tuned for a 300pt frame; sub-linear scaling keeps
        // small orbs legible.
        let radiusScale = pow(size / 300, 0.6)
        let (amounts, active) = Self.solveCycle(at: t)
        // Moves before the active one have fully turned; later ones have not
        // started. At rest (`active == -1`) the sphere is solved.
        let settled = lattice.states[max(0, active)]
        let turning = active >= 0 && amounts[active] > 0
            ? (move: Self.moves[active], amount: amounts[active]) : nil

        var dots: [Dot] = []
        dots.reserveCapacity(settled.count)
        for point in settled {
            var moved = point
            var inActive = false
            if let turning {
                (moved, inActive) = Self.turn(point, by: turning.move, amount: turning.amount)
            }
            // Spin + tilt + orthographic projection.
            let x1 = moved.x * cy + moved.z * sy
            let z1 = -moved.x * sy + moved.z * cy
            let y1 = moved.y * ct - z1 * st
            let z2 = moved.y * st + z1 * ct
            let depth = (z2 + 1) / 2
            dots.append(Dot(
                x: center + x1 * radius,
                y: center - y1 * radius,
                z: z2,
                radius: (preset.dotBase + preset.dotDepth * depth
                    + (inActive ? preset.dotActive : 0)) * radiusScale,
                // the band being turned inks a touch darker — the "hand"
                white: 0.62 - 0.54 * depth - (inActive ? 0.14 : 0)))
        }
        dots.sort { $0.z < $1.z }
        return dots
    }
}

/// The animated orb view. All mounted orbs share the wall clock, so they
/// stay in phase; reduced-motion users get a static representative frame.
struct SolvingOrbView: View {
    var size: CGFloat = 16

    /// The orb is a 10–12 pt glyph: 30 Hz reads the same as ProMotion's
    /// 120 Hz for a quarter of the main-thread drawing.
    static let frameInterval: TimeInterval = 1.0 / 30

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false

    var body: some View {
        let renderer = SolvingOrbRenderer(size: Double(size))
        Group {
            if reduceMotion {
                frame(renderer, at: 0.6)
            } else {
                // Holds its last frame while off screen or not in the
                // foreground, so a hidden orb costs nothing.
                TimelineView(.animation(
                    minimumInterval: Self.frameInterval,
                    paused: !isOnScreen || scenePhase != .active
                )) { timeline in
                    frame(
                        renderer,
                        at: timeline.date.timeIntervalSinceReferenceDate * renderer.preset.speed)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }

    private func frame(_ renderer: SolvingOrbRenderer, at t: Double) -> some View {
        let dark = colorScheme == .dark
        return Canvas { context, _ in
            for dot in renderer.dots(at: t) {
                let ink = min(1, max(0, dot.white))
                let radius = max(0.3, dot.radius)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: dot.x - radius, y: dot.y - radius,
                        width: radius * 2, height: radius * 2)),
                    with: .color(Color(white: dark ? 1 - ink : ink)))
            }
        }
    }
}

#Preview {
    HStack(spacing: 32) {
        SolvingOrbView(size: 64)
        SolvingOrbView(size: 20)
        SolvingOrbView(size: 16)
    }
    .padding()
}
