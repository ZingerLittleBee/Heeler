import Darwin
import Foundation
import Synchronization

/// Takes the main thread's stack while a frame is overdue, so a hitch names
/// the code that held it even where no span was placed.
///
/// A watchdog thread reads when the last frame came. Once one is half a
/// frame overdue, it signals the main thread, whose handler walks its own
/// frame pointers into a fixed buffer: no lock, no allocation. The addresses
/// are resolved later, off both threads. Only started by `PerfTrace`, so a
/// build without the trace on installs no handler and starts no thread.
enum PerfMainThreadSampler {
    struct Sample: Sendable {
        /// Seconds the frame was overdue when the stack was taken.
        let overdue: Double
        /// Where the main thread was executing, from the signal's context.
        let pc: UInt
        /// Return addresses, the handler's own frames first.
        let frames: [UInt]
    }

    private static let signal = SIGUSR2
    /// The first stacks of a stall come close together, to catch a short
    /// one; a long stall then gets a few more, further apart.
    private static let denseSamples = 8
    private static let mostSamples = 16
    private static let denseSpacing: UInt64 = 8_000_000
    private static let sparseSpacing: UInt64 = 50_000_000
    private static let pollMicroseconds: UInt32 = 4_000

    private static let samples = Mutex<[Sample]>([])

    /// Called on the main thread, once.
    static func start() {
        guard !perfSamplerStarted.exchange(true, ordering: .relaxed) else { return }
        // Everything the handler touches exists before a signal can arrive:
        // a first use inside the handler would run a lazy initializer there.
        perfSampleBuffer.initialize(repeating: nil, count: Int(perfSampleCapacity))
        perfSampleReady.store(false, ordering: .relaxed)
        perfMainThread = pthread_self()

        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = { _, _, context in
            let saved = errno
            perfSampleCount = backtrace(perfSampleBuffer, perfSampleCapacity)
            perfSamplePC = perfProgramCounter(context)
            perfSampleReady.store(true, ordering: .sequentiallyConsistent)
            errno = saved
        }
        sigemptyset(&action.sa_mask)
        // On the thread's alternate stack where it has one, as runtimes that
        // manage their own stacks require of every handler in the process.
        action.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK
        sigaction(signal, &action, nil)

        let thread = Thread { watch() }
        thread.name = "dev.bybee.heeler.perf-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The main thread says a frame came, and how long one lasts.
    static func noteFrame(interval: Double) {
        perfFrameNanoseconds.store(UInt64(max(interval, 0) * 1_000_000_000), ordering: .relaxed)
        perfLastFrame.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
    }

    /// No frame is due while the app is not in front.
    static func pause() {
        perfLastFrame.store(0, ordering: .relaxed)
    }

    /// The stacks taken since the last call.
    static func takeSamples() -> [Sample] {
        samples.withLock { taken in
            guard !taken.isEmpty else { return [] }
            defer { taken.removeAll(keepingCapacity: true) }
            return taken
        }
    }

    private static func watch() {
        var origin: UInt64 = 0
        var taken = 0
        var lastSample: UInt64 = 0
        while true {
            usleep(pollMicroseconds)
            let last = perfLastFrame.load(ordering: .relaxed)
            guard last != 0 else { continue }
            if last != origin {
                origin = last
                taken = 0
                lastSample = 0
            }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let frame = max(perfFrameNanoseconds.load(ordering: .relaxed), 4_000_000)
            guard now > last, now - last >= frame + frame / 2, taken < mostSamples else { continue }
            let spacing = taken < denseSamples ? denseSpacing : sparseSpacing
            guard now - lastSample >= spacing, let sample = capture(overdue: now - last - frame) else { continue }
            // The frame came while the stack was being taken: not a stall's.
            guard perfLastFrame.load(ordering: .relaxed) == last else { continue }
            samples.withLock { $0.append(sample) }
            taken += 1
            lastSample = now
        }
    }

    private static func capture(overdue: UInt64) -> Sample? {
        guard let main = perfMainThread else { return nil }
        perfSampleReady.store(false, ordering: .sequentiallyConsistent)
        guard pthread_kill(main, signal) == 0 else { return nil }
        // The handler runs as soon as the main thread is on a core.
        var waited = 0
        while !perfSampleReady.load(ordering: .sequentiallyConsistent) {
            guard waited < 200 else { return nil }
            usleep(50)
            waited += 1
        }
        let count = Int(max(0, min(perfSampleCount, perfSampleCapacity)))
        let frames = (0..<count).map { UInt(bitPattern: perfSampleBuffer[$0]) }
        return Sample(overdue: Double(overdue) / 1_000_000_000, pc: perfSamplePC, frames: frames)
    }

    /// The stack as text, innermost first, without the handler's own frames.
    static func symbolicated(_ sample: Sample, resolve: (UInt) -> String) -> [String] {
        var frames = sample.frames.map(resolve)
        if let trampoline = frames.lastIndex(where: { $0.contains(" _sigtramp+") }) {
            frames.removeSubrange(...trampoline)
        }
        if sample.pc != 0 { frames.insert(resolve(sample.pc), at: 0) }
        return frames
    }

    /// `image symbol+offset`, the symbol still mangled, or the offset into
    /// the image where it has no symbol, which `atos` resolves with a dSYM.
    static func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return "? 0x" + String(address, radix: 16)
        }
        let image = info.dli_fname.map { String(cString: $0) }.map { path in
            path.split(separator: "/").last.map(String.init) ?? path
        } ?? "?"
        if let name = info.dli_sname, let start = info.dli_saddr {
            return "\(image) \(String(cString: name))+\(address &- UInt(bitPattern: start))"
        }
        return "\(image) 0x" + String(address &- UInt(bitPattern: info.dli_fbase), radix: 16)
    }
}

// What the signal handler reads and writes. Globals, so the handler captures
// nothing, and each written by one side at a time: the watchdog waits for
// `perfSampleReady` before it reads what the handler wrote. A SwiftUI update
// under a collection view layout runs well past a hundred frames deep.
private let perfSampleCapacity: Int32 = 224
private nonisolated(unsafe) let perfSampleBuffer =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(perfSampleCapacity))
private nonisolated(unsafe) var perfSampleCount: Int32 = 0
private nonisolated(unsafe) var perfSamplePC: UInt = 0
private nonisolated(unsafe) var perfMainThread: pthread_t?
private let perfSampleReady = Atomic<Bool>(false)
private let perfSamplerStarted = Atomic<Bool>(false)
/// When the last frame came, on the uptime clock; 0 while none is due.
private let perfLastFrame = Atomic<UInt64>(0)
private let perfFrameNanoseconds = Atomic<UInt64>(16_666_667)

private func perfProgramCounter(_ context: UnsafeMutableRawPointer?) -> UInt {
    guard let machine = context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext else { return 0 }
    #if arch(arm64)
        return UInt(machine.pointee.__ss.__pc)
    #elseif arch(x86_64)
        return UInt(machine.pointee.__ss.__rip)
    #else
        return 0
    #endif
}
