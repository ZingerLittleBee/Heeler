import Foundation
import QuartzCore
import UIKit
import os

/// An opt-in trace for hunting dropped frames.
///
/// Off unless the process starts with `--perf-trace` or the `perf.trace`
/// default is set, and then every entry point returns at once. On, it times
/// the display link for late frames ("hitches"), attributes each to the spans
/// and counts recorded on the main actor since the frame before, and samples
/// the main thread's stack while frames are overdue (`PerfMainThreadSampler`).
///
/// Records go to a JSON Lines file under `Library/Caches/PerfTrace`, which
/// `scripts/perf-trace-summary.py` reads; hitches also go to the unified log
/// (category `Perf`), and spans to signposts for Instruments. See
/// `docs/agents/performance-tracing.md`.
enum PerfTrace {
    static let launchArgument = "--perf-trace"
    static let defaultsKey = "perf.trace"

    /// Fixed for the process, so a disabled trace costs one load per call.
    static let isEnabled: Bool =
        ProcessInfo.processInfo.arguments.contains(launchArgument)
        || UserDefaults.standard.bool(forKey: defaultsKey)

    fileprivate static let signposter = OSSignposter(subsystem: "dev.bybee.heeler", category: "PerfTrace")

    /// Main-actor work under way; nil while the trace is off.
    struct Span {
        fileprivate let name: StaticString
        fileprivate let start: CFTimeInterval
        fileprivate let state: OSSignpostIntervalState
    }

    /// Work that waits, on any actor; nil while the trace is off.
    struct Interval: Sendable {
        fileprivate let name: StaticString
        fileprivate let start: CFTimeInterval
        fileprivate let detail: String
    }

    /// Starts the frame clock and the sampler. Called once, as the app starts.
    @MainActor
    static func startIfEnabled() {
        guard isEnabled else { return }
        PerfTraceRecorder.shared.start()
    }

    /// Times main-actor work, counted against the frame it runs in.
    @MainActor
    static func begin(_ name: StaticString) -> Span? {
        guard isEnabled else { return nil }
        return Span(name: name, start: CACurrentMediaTime(), state: signposter.beginInterval(name))
    }

    @MainActor
    static func end(_ span: Span?) {
        guard let span else { return }
        let seconds = CACurrentMediaTime() - span.start
        signposter.endInterval(span.name, span.state)
        PerfTraceRecorder.shared.record(span.name, seconds: seconds)
    }

    @MainActor
    @discardableResult
    static func span<Value>(_ name: StaticString, _ body: () throws -> Value) rethrows -> Value {
        let span = begin(name)
        defer { end(span) }
        return try body()
    }

#if DEBUG
    @MainActor static var testCountObserver: ((StaticString, Int) -> Void)?
#endif

    /// Counts something that happens many times a frame: a view's `body`, a
    /// cell, an event.
    @MainActor
    static func count(_ name: StaticString, _ amount: Int = 1) {
#if DEBUG
        testCountObserver?(name, amount)
#endif
        guard isEnabled else { return }
        PerfTraceRecorder.shared.count(name, amount)
    }

    /// Says what is on screen, in every hitch record until it changes.
    @MainActor
    static func setContext(_ key: StaticString, _ value: String?) {
        guard isEnabled else { return }
        PerfTraceRecorder.shared.setContext(key, value)
    }

    /// Times work that waits (a Host read, rows built off the main actor), to
    /// set beside the hitches it overlaps. `detail` is `key=value` pairs.
    static func beginInterval(_ name: StaticString, _ detail: @autoclosure () -> String = "") -> Interval? {
        guard isEnabled else { return nil }
        return Interval(name: name, start: CACurrentMediaTime(), detail: detail())
    }

    static func endInterval(_ interval: Interval?, _ detail: @autoclosure () -> String = "") {
        guard let interval else { return }
        let end = CACurrentMediaTime()
        let ended = detail()
        var record = PerfRecord(time: interval.start, kind: "interval")
        record.n = interval.name.description
        record.ms = PerfRecord.milliseconds(end - interval.start)
        let joined = [interval.detail, ended].filter { !$0.isEmpty }.joined(separator: " ")
        record.d = joined.isEmpty ? nil : joined
        PerfTraceSink.shared.write(record)
    }

    /// Marks a moment: a connection, a snapshot, a scenario's start.
    static func event(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        var record = PerfRecord(time: CACurrentMediaTime(), kind: "event")
        record.n = name.description
        let text = detail()
        record.d = text.isEmpty ? nil : text
        PerfTraceSink.shared.write(record)
    }
}

/// What ran on the main actor over a stretch of time: a frame, or a second.
struct PerfFrameLedger: Equatable {
    struct Total: Equatable {
        var count = 0
        var seconds = 0.0
        var longest = 0.0
    }

    private(set) var spans: [String: Total] = [:]
    private(set) var counts: [String: Int] = [:]

    var isEmpty: Bool { spans.isEmpty && counts.isEmpty }

    mutating func record(span name: String, seconds: Double) {
        var total = spans[name] ?? Total()
        total.count += 1
        total.seconds += seconds
        total.longest = max(total.longest, seconds)
        spans[name] = total
    }

    mutating func count(_ name: String, _ amount: Int = 1) {
        counts[name, default: 0] += amount
    }

    mutating func merge(_ other: PerfFrameLedger) {
        for (name, total) in other.spans {
            var merged = spans[name] ?? Total()
            merged.count += total.count
            merged.seconds += total.seconds
            merged.longest = max(merged.longest, total.longest)
            spans[name] = merged
        }
        for (name, amount) in other.counts {
            counts[name, default: 0] += amount
        }
    }

    mutating func removeAll() {
        spans.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
    }

    /// The spans that took the most time, most first; names break ties so a
    /// record reads the same each time.
    func spanTotals(limit: Int) -> [PerfSpanTotal] {
        spans
            .sorted { ($1.value.seconds, $0.key) < ($0.value.seconds, $1.key) }
            .prefix(limit)
            .map {
                PerfSpanTotal(
                    n: $0.key, c: $0.value.count, ms: PerfRecord.milliseconds($0.value.seconds),
                    max: PerfRecord.milliseconds($0.value.longest))
            }
    }
}

/// Decides which frames came late.
enum PerfFrameClock {
    /// A gap longer than this is the app coming back, not a frame.
    static let longestGap: CFTimeInterval = 30

    /// How late a frame came, when it came at least half a frame late: one
    /// dropped frame reads as a whole interval over, and timer jitter as none.
    static func hitch(gap: CFTimeInterval, frame: CFTimeInterval) -> CFTimeInterval? {
        guard frame > 0, gap > 0, gap <= longestGap else { return nil }
        let over = gap - frame
        return over >= frame / 2 ? over : nil
    }
}

struct PerfSpanTotal: Encodable, Sendable, Equatable {
    var n: String
    var c: Int
    var ms: Double
    var max: Double
}

/// One main-thread stack, innermost frame first.
struct PerfStack: Encodable, Sendable {
    /// Milliseconds the frame was overdue when the stack was taken.
    var at: Double
    var f: [String]
}

/// One line of the trace file. Short keys keep a long run's file small.
struct PerfRecord: Encodable, Sendable {
    /// Seconds since 1970.
    var t: Double
    /// `launch`, `hitch`, `stat`, `interval` or `event`.
    var k: String
    var n: String?
    var ms: Double?
    var d: String?
    /// A hitch's time past its frame, and the frame's length.
    var over: Double?
    var frame: Double?
    /// Whether a scroll view was tracking a touch or decelerating.
    var scroll: Bool?
    var ctx: [String: String]?
    var spans: [PerfSpanTotal]?
    var counts: [String: Int]?
    var stacks: [PerfStack]?
    /// A stat window's frames, hitches, time over, longest gap, the time the
    /// main run loop spent awake, and the frames a scroll view was moving in.
    var frames: Int?
    var hitches: Int?
    var hitchMs: Double?
    var maxMs: Double?
    var busyMs: Double?
    var scrollFrames: Int?
    var window: Double?
    var info: [String: String]?

    /// The wall clock's lead over the media clock every span is timed on.
    private static let wallOffset = Date().timeIntervalSince1970 - CACurrentMediaTime()

    init(time: CFTimeInterval, kind: String) {
        t = ((time + Self.wallOffset) * 1000).rounded() / 1000
        k = kind
    }

    static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 100_000).rounded() / 100
    }
}

/// Keeps the frame clock and what ran in each frame.
@MainActor
final class PerfTraceRecorder: NSObject {
    static let shared = PerfTraceRecorder()

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "Perf")

    /// Spans a hitch record lists, and a stat record.
    private static let hitchSpanLimit = 12
    private static let statSpanLimit = 24
    private static let statWindow: CFTimeInterval = 1

    private var names: [UInt: String] = [:]
    private var frame = PerfFrameLedger()
    private var window = PerfFrameLedger()
    private var contexts: [String: String] = [:]
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var scrollFrames = 0
    private var hitches = 0
    private var hitchSeconds = 0.0
    private var longestGap = 0.0
    private var busySeconds = 0.0
    private var wokeAt: CFTimeInterval?
    private var observer: CFRunLoopObserver?

    func start() {
        guard link == nil else { return }
        var launch = PerfRecord(time: CACurrentMediaTime(), kind: "launch")
        launch.info = Self.launchInfo()
        PerfTraceSink.shared.write(launch)
        if let path = PerfTraceSink.shared.fileURL?.path {
            Self.log.notice("perf trace writing to \(path, privacy: .public)")
        }

        PerfMainThreadSampler.start()
        Self.installKeychainHook()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Common modes: the clock has to run while a scroll view tracks.
        link.add(to: .main, forMode: .common)
        self.link = link
        observeRunLoop()

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(pause), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(pause), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    nonisolated static func installKeychainHook() {
        KeychainSecretTrace.wrapRead = { service, isAll, body in
            if pthread_main_np() != 0 {
                let state = PerfTrace.signposter.beginInterval("keychain.main.read")
                let start = CACurrentMediaTime()
                let status = body()
                let seconds = CACurrentMediaTime() - start
                PerfTrace.signposter.endInterval("keychain.main.read", state)
                MainActor.assumeIsolated {
                    PerfTraceRecorder.shared.record("keychain.main.read", seconds: seconds)
                }
                return status
            }
            let interval = PerfTrace.beginInterval(
                "keychain.bg.read", "service=\(service) all=\(isAll ? 1 : 0)")
            let result = body()
            PerfTrace.endInterval(interval)
            return result
        }
    }

    func record(_ name: StaticString, seconds: Double) {
        frame.record(span: string(name), seconds: seconds)
    }

    func count(_ name: StaticString, _ amount: Int) {
        frame.count(string(name), amount)
    }

    func setContext(_ key: StaticString, _ value: String?) {
        contexts[string(key)] = value
    }

    /// A literal's bytes never move, so its address names it without making
    /// a `String` on every call.
    private func string(_ name: StaticString) -> String {
        guard name.hasPointerRepresentation else { return name.description }
        let key = UInt(bitPattern: name.utf8Start)
        if let known = names[key] { return known }
        let made = name.description
        names[key] = made
        return made
    }

    /// A frame that follows time away is not late.
    @objc private func pause() {
        lastTimestamp = 0
        wokeAt = nil
        PerfMainThreadSampler.pause()
    }

    /// The time the main run loop spends awake is the main thread's load,
    /// whether or not a frame came late for it. Last in line before the loop
    /// sleeps, so the frame's own layout and commit count as awake.
    private func observeRunLoop() {
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, .max) { _, activity in
            MainActor.assumeIsolated {
                let recorder = PerfTraceRecorder.shared
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    recorder.wokeAt = now
                } else if let woke = recorder.wokeAt {
                    recorder.busySeconds += now - woke
                    recorder.wokeAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let interval = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        PerfMainThreadSampler.noteFrame(interval: interval)
        defer {
            lastTimestamp = now
            frame.removeAll()
        }
        guard lastTimestamp > 0 else {
            windowStart = now
            _ = PerfMainThreadSampler.takeSamples()
            return
        }
        let gap = now - lastTimestamp
        let isScrolling = RunLoop.current.currentMode == .tracking
        let samples = PerfMainThreadSampler.takeSamples()
        frames += 1
        if isScrolling { scrollFrames += 1 }
        longestGap = max(longestGap, gap)
        window.merge(frame)

        if let over = PerfFrameClock.hitch(gap: gap, frame: interval) {
            hitches += 1
            hitchSeconds += over
            var record = PerfRecord(time: lastTimestamp, kind: "hitch")
            record.ms = PerfRecord.milliseconds(gap)
            record.over = PerfRecord.milliseconds(over)
            record.frame = PerfRecord.milliseconds(interval)
            record.scroll = isScrolling
            record.ctx = contexts.isEmpty ? nil : contexts
            let spans = frame.spanTotals(limit: Self.hitchSpanLimit)
            record.spans = spans.isEmpty ? nil : spans
            record.counts = frame.counts.isEmpty ? nil : frame.counts
            PerfTraceSink.shared.write(record, samples: samples)
            let top = spans.first.map { "\($0.n) \($0.ms)ms x\($0.c)" } ?? "-"
            Self.log.notice(
                "hitch \(record.ms ?? 0, privacy: .public)ms scroll=\(isScrolling, privacy: .public) top=\(top, privacy: .public)"
            )
        }
        if now - windowStart >= Self.statWindow { flushWindow(at: now) }
    }

    private func flushWindow(at now: CFTimeInterval) {
        var record = PerfRecord(time: windowStart, kind: "stat")
        record.window = PerfRecord.milliseconds(now - windowStart)
        record.frames = frames
        record.scrollFrames = scrollFrames
        record.hitches = hitches
        record.hitchMs = PerfRecord.milliseconds(hitchSeconds)
        record.maxMs = PerfRecord.milliseconds(longestGap)
        record.busyMs = PerfRecord.milliseconds(busySeconds)
        record.ctx = contexts.isEmpty ? nil : contexts
        let spans = window.spanTotals(limit: Self.statSpanLimit)
        record.spans = spans.isEmpty ? nil : spans
        record.counts = window.counts.isEmpty ? nil : window.counts
        PerfTraceSink.shared.write(record)

        windowStart = now
        frames = 0
        scrollFrames = 0
        hitches = 0
        hitchSeconds = 0
        longestGap = 0
        busySeconds = 0
        window.removeAll()
    }

    private static func launchInfo() -> [String: String] {
        let bundle = Bundle.main
        var info: [String: String] = [
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "os": UIDevice.current.systemVersion,
            "model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
            "fps": String(UIScreen.main.maximumFramesPerSecond),
            "pid": String(ProcessInfo.processInfo.processIdentifier),
        ]
        #if DEBUG
            info["configuration"] = "debug"
        #else
            info["configuration"] = "release"
        #endif
        #if targetEnvironment(simulator)
            info["simulator"] = "1"
        #endif
        return info
    }
}

/// Writes the trace file off the main thread, resolving stack addresses there.
final class PerfTraceSink: @unchecked Sendable {
    static let shared = PerfTraceSink()

    /// Trace files kept from earlier launches.
    private static let keptFiles = 8

    let fileURL: URL?
    private let queue = DispatchQueue(label: "dev.bybee.heeler.perf-trace", qos: .utility)
    private let handle: FileHandle?
    private let encoder: JSONEncoder
    /// Only read and written on `queue`.
    private var symbols: [UInt: String] = [:]

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let files = FileManager.default
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            fileURL = nil
            handle = nil
            return
        }
        let directory = caches.appendingPathComponent("PerfTrace", isDirectory: true)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        let earlier = ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in earlier.dropLast(Self.keptFiles - 1) {
            try? files.removeItem(at: stale)
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("perf-\(stamp.string(from: Date())).jsonl")
        files.createFile(atPath: url.path, contents: nil)
        fileURL = url
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ record: PerfRecord, samples: [PerfMainThreadSampler.Sample] = []) {
        guard handle != nil else { return }
        queue.async { [self] in
            var record = record
            if !samples.isEmpty {
                record.stacks = samples.map { sample in
                    PerfStack(
                        at: PerfRecord.milliseconds(sample.overdue),
                        f: PerfMainThreadSampler.symbolicated(sample, resolve: symbol(at:)))
                }
            }
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            try? handle?.write(contentsOf: line)
        }
    }

    private func symbol(at address: UInt) -> String {
        if let known = symbols[address] { return known }
        let described = PerfMainThreadSampler.describe(address)
        symbols[address] = described
        return described
    }
}
