import CMosh
import Darwin
import Foundation
import libmoshios
import Synchronization

/// One interactive terminal session carried over mosh's UDP transport.
///
/// `mosh_main` is a blocking call that runs the whole mosh event loop —
/// select over the UDP socket, the keystroke fd, and signals — and its
/// suspend path calls `pthread_exit`, which makes libdispatch and
/// async/await contexts unsafe. The session therefore runs it on a
/// dedicated Foundation thread (8 MB stack; mosh + protobuf state is
/// heavy) and wires the result into the transport-agnostic
/// ``TerminalAttachSession`` machinery:
///
/// - `f_in`: Swift writes keystrokes into a pipe; mosh polls the read end.
///   Closing the write end produces the EOF that shuts mosh down.
/// - `f_out`: mosh writes frame diffs and connection notices to a pipe;
///   a reader thread drains it into the Attach output gate.
/// - Resizes mutate the caller-owned `struct winsize` (via
///   ``mosh_ws_update``) and raise SIGWINCH, which the library handles.
///
/// Construction never throws: a session that dies early — wrong key,
/// unreachable server — surfaces on `output` as a thrown error, which the
/// Attach store presents as an ended session. The caller owns explicit
/// teardown through `end()`; dropping the session without it leaks the
/// pipes, exactly as dropping an SSH session would leave its channel open.
///
/// Known phase-1 limitation: mosh's signal handlers are process-wide, so a
/// SIGWINCH raised for one live mosh session is observed by whichever
/// mosh_main registered its handler last. Two simultaneously live mosh
/// sessions can misdirect a resize; SSH sessions are unaffected.
enum MoshAttachSession {
    /// Assembles the mosh-backed session for a successful bootstrap. The
    /// UDP endpoint comes from the bootstrap; geometry is the attach
    /// request's initial PTY size.
    static func make(
        bootstrap: MoshBootstrap, cols: Int, rows: Int
    ) -> TerminalAttachSession {
        let lifecycle = MoshSessionLifecycle(
            bootstrap: bootstrap, cols: cols, rows: rows)
        lifecycle.start()
        return TerminalAttachSession(
            output: lifecycle.outputGate.makeOutput,
            input: lifecycle.input,
            onEndStarted: lifecycle.outputGate.beginExplicitEnd
        ) {
            await lifecycle.end()
        }
    }
}

/// Owns one live mosh session's pipes, threads, and pump task. All mutable
/// state sits behind a mutex; the class is Sendable so the terminal
/// machinery can reach it from any isolation domain.
private final class MoshSessionLifecycle: Sendable {
    /// Matches mosh's own keystroke read size on the remote side.
    private static let outputChunkSize = 16 * 1024
    private static let moshThreadStackSize = 8 << 20

    private struct State {
        let fInWriteFD: Int32
        let fInReadFD: Int32
        let fOutWriteFD: Int32
        var fOutReadFD: Int32
        var ws: UnsafeMutablePointer<mosh_ws>?
        var pumpTask: Task<Void, Never>?
        var moshExitCode: Int32?
        var moshDoneWaiters: [CheckedContinuation<Int32, Never>] = []
        var outputDone = false
        var outputDoneWaiters: [CheckedContinuation<Void, Never>] = []
        var endRequested = false
    }

    let input = TerminalAttachInputQueue()
    let outputGate = HeelerSSHAttachOutputGate()

    private let state: Mutex<State>
    private let bootstrap: MoshBootstrap
    private let initialCols: UInt16
    private let initialRows: UInt16

    init(bootstrap: MoshBootstrap, cols: Int, rows: Int) {
        self.bootstrap = bootstrap
        initialCols = UInt16(max(1, cols))
        initialRows = UInt16(max(1, rows))
        // f_in: Swift writes → mosh reads. f_out: mosh writes → Swift reads.
        var fIn: [Int32] = [-1, -1]
        var fOut: [Int32] = [-1, -1]
        pipe(&fIn)
        pipe(&fOut)
        state = Mutex(State(
            fInWriteFD: fIn[1], fInReadFD: fIn[0], fOutWriteFD: fOut[1],
            fOutReadFD: fOut[0], ws: nil))
    }

    func start() {
        state.withLock { initialState in
            initialState.ws = mosh_ws_create(initialCols, initialRows)
        }
        let moshThread = Thread { [self] in
            runMosh()
        }
        moshThread.stackSize = Self.moshThreadStackSize
        moshThread.name = "mosh-session"
        moshThread.start()

        let readerThread = Thread { [self] in
            runOutputReader()
        }
        readerThread.name = "mosh-output"
        readerThread.start()

        let pumpTask = Task<Void, Never> { [input, self] in
            _ = try? await input.pump(
                write: { data in self.write(data) },
                resize: { cols, rows in self.resize(cols: cols, rows: rows) })
        }
        state.withLock { runningState in
            runningState.pumpTask = pumpTask
        }
    }

    /// Explicit teardown: EOF on the keystroke pipe shuts mosh down, then
    /// every helper winds down in dependency order before the fds go.
    func end() async {
        let shouldProceed = state.withLock { currentState -> Bool in
            guard !currentState.endRequested else { return false }
            currentState.endRequested = true
            return true
        }
        guard shouldProceed else { return }

        let fInWriteFD = state.withLock { $0.fInWriteFD }
        if fInWriteFD >= 0 { close(fInWriteFD) }

        let pumpTask = state.withLock { $0.pumpTask }
        await pumpTask?.value

        _ = await moshExitCode()
        await waitOutputDone()
        cleanup()
    }

    // MARK: mosh thread

    private func runMosh() {
        // The library exits the whole process without a UTF-8 native locale.
        mosh_prepare_locale()
        let fds = state.withLock { currentState -> (Int32, Int32) in
            (currentState.fInReadFD, currentState.fOutWriteFD)
        }
        let exitCode: Int32
        if let fInFILE = fdopen(fds.0, "r"), let fOutFILE = fdopen(fds.1, "w") {
            let ws = state.withLock { $0.ws }
            exitCode = mosh_main(
                fInFILE,
                fOutFILE,
                mosh_ws_pointer(ws),
                mosh_state_discard,
                nil,
                bootstrap.host,
                bootstrap.udpPort,
                bootstrap.key,
                "adaptive",
                "",
                0)
            // The reader learns the session ended through the output pipe's
            // EOF, which only happens once the write end closes below — so
            // the exit code must be recorded first.
            recordMoshExit(exitCode)
            fclose(fOutFILE)
            fclose(fInFILE)
        } else {
            close(fds.1)
            close(fds.0)
            recordMoshExit(1)
        }
    }

    // MARK: output reader thread

    private func runOutputReader() {
        let fOutReadFD = state.withLock { $0.fOutReadFD }
        var buffer = [UInt8](repeating: 0, count: Self.outputChunkSize)
        var failure: (any Error)?
        var outputTail: [String] = []
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fOutReadFD, raw.baseAddress, Self.outputChunkSize)
            }
            if count > 0 {
                let chunk = String(decoding: buffer.prefix(count), as: UTF8.self)
                // Keep the tail for failure diagnosis: mosh reports the
                // concrete reason (sendto errno, "Nothing received", locale
                // problems) through this stream, not through the exit code.
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: true)
                where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    outputTail.append(String(line))
                    if outputTail.count > 6 { outputTail.removeFirst() }
                }
                outputGate.yield(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            failure = TransportError.moshSessionFailed(
                detail: "mosh output read failed (errno \(errno))")
            break
        }

        // EOF is only observable after mosh closed its write end, and the
        // exit code is recorded before that close — so it is already here.
        let exitCode = state.withLock { $0.moshExitCode } ?? 1
        if failure == nil, exitCode != 0 {
            let reason = outputTail.isEmpty
                ? ""
                : " — last output: \(outputTail.suffix(2).joined(separator: " | "))"
            failure = TransportError.moshSessionFailed(
                detail: "mosh session failed (exit status \(exitCode))\(reason)")
        }
        outputGate.finish(throwing: failure)
        markOutputDone()
    }

    // MARK: input pump closures

    private func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let fd = state.withLock { $0.fInWriteFD }
                guard fd >= 0 else { return }
                let written = Darwin.write(
                    fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                // A dead keystroke path surfaces through the session's own
                // shutdown; nothing to report here.
                return
            }
        }
    }

    private func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let ws = state.withLock { $0.ws }
        mosh_ws_update(ws, UInt16(cols), UInt16(rows))
        kill(getpid(), SIGWINCH)
    }

    // MARK: completion plumbing

    private func moshExitCode() async -> Int32 {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { currentState -> Int32? in
                if let exitCode = currentState.moshExitCode { return exitCode }
                currentState.moshDoneWaiters.append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    private func recordMoshExit(_ exitCode: Int32) {
        let waiters = state.withLock { currentState -> [
            CheckedContinuation<Int32, Never>
        ] in
            currentState.moshExitCode = exitCode
            let pending = currentState.moshDoneWaiters
            currentState.moshDoneWaiters = []
            return pending
        }
        for waiter in waiters {
            waiter.resume(returning: exitCode)
        }
    }

    private func waitOutputDone() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { currentState -> Bool in
                if currentState.outputDone { return true }
                currentState.outputDoneWaiters.append(continuation)
                return false
            }
            if immediate {
                continuation.resume()
            }
        }
    }

    private func markOutputDone() {
        let waiters = state.withLock { currentState -> (
            Int32, [CheckedContinuation<Void, Never>]
        ) in
            currentState.outputDone = true
            let pending = currentState.outputDoneWaiters
            currentState.outputDoneWaiters = []
            return (currentState.fOutReadFD, pending)
        }
        for waiter in waiters.1 {
            waiter.resume()
        }
        if waiters.0 >= 0 {
            close(waiters.0)
            state.withLock { $0.fOutReadFD = -1 }
        }
    }

    private func cleanup() {
        let ws = state.withLock { $0.ws }
        if let ws {
            mosh_ws_destroy(ws)
            state.withLock { $0.ws = nil }
        }
    }
}
