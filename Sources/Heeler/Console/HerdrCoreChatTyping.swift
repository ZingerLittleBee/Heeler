import Foundation

/// A viewer of Chat's own on the Host's one link (ADR 0035): a resumed viewer, so
/// joining changes nothing, that reports no display facts. Before it types it sends
/// the Terminal's latest size as its own, because typing makes it the viewer whose
/// size counts, so its typing never resizes the Terminal for anyone.
@MainActor
final class HerdrCoreChatViewer: HerdrCoreTypingSeat {
    struct Size: Equatable {
        let columns: Int
        let rows: Int
    }

    private(set) var modes = TerminalModeTracker()
    /// The screen as this viewer joined it.
    private(set) var paintedScreen: ANSIScreen?
    private let session: TerminalAttachSession
    private let latestSize: @MainActor () -> Size?
    private var sentSize: Size?
    private var paint = HerdrCoreFirstPaint()
    private var hasEnded = false
    private var paintWaiters: [CheckedContinuation<Void, any Error>] = []

    init(session: TerminalAttachSession, latestSize: @escaping @MainActor () -> Size?) {
        self.session = session
        self.latestSize = latestSize
        // The first paint carries the modes, and the program can change them while
        // a Send waits between its steps. Credit keeps coming back until the end.
        Task { [weak self, session] in
            do {
                for try await output in session.output {
                    session.outputConsumed(output.count)
                    self?.take(output)
                }
            } catch {}
            self?.outputEnded()
        }
    }

    private func take(_ output: Data) {
        modes.receive(output)
        guard paintedScreen == nil, let screen = paint.receive(output) else { return }
        paintedScreen = screen
        let waiters = paintWaiters
        paintWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func outputEnded() {
        hasEnded = true
        let waiters = paintWaiters
        paintWaiters = []
        for waiter in waiters { waiter.resume(throwing: TransportError.cancelled) }
    }

    /// Returns once the modes can be trusted: the paint turns them all off first.
    func untilPainted() async throws {
        if paintedScreen != nil { return }
        if hasEnded { throw TransportError.cancelled }
        try await withCheckedThrowingContinuation { paintWaiters.append($0) }
    }

    func write(_ data: Data, indexedAs source: AttachUserMessageIndex.OutgoingSource?) async throws {
        if let size = latestSize(), size != sentSize {
            session.resize(cols: size.columns, rows: size.rows)
            sentSize = size
        }
        try await session.sendAcknowledged(data)
    }

    /// Chat's messages are in the Transcript, and it has no index of its own.
    func recordSubmitted(_ text: String) {}

    func leave() {
        Task { [session] in await session.end() }
    }
}

/// How Chat reads and types in a herdr-core Agent's Terminal (ADR 0035): the screen
/// from an observing attach's first paint, since `terminal.read` has no styles, and
/// keys and text through a viewer of Chat's own, opened for the one action and gone
/// after, so it never holds the Terminal's size longer than it types.
///
/// A key goes only while the Agent holds the foreground: a Terminal keeps its
/// keyboard flags and its stop key after its Agent exits, and the shell left behind
/// must not get what was meant for the Agent. That is checked again once the viewer
/// is open, since opening it can take seconds.
@MainActor
final class HerdrCoreChatTyping {
    /// Why nothing was typed, for the user: nothing left Heeler.
    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The process holding the foreground. A wrapper can keep its pid across
    /// programs, so the program counts too.
    private struct Holder: Equatable {
        let pid: Int
        let program: HerdrCoreAgentRule.Program

        init?(_ record: HerdrCoreTerminalRecord) {
            guard let pid = record.foreground?.pid else { return nil }
            self.pid = pid
            program = HerdrCoreAgentRule.program(of: record)
        }
    }

    private let address: String
    private weak var projection: HerdrCoreConsoleProjection?
    private let clock: BlockedCardClock
    /// What held the foreground as the last screen read began.
    private var screenHolder: Holder?
    /// That read saw another process than the read before it, so a dialog it found
    /// may not be the one the user is answering. The next read settles it.
    private var holderChangedAtLastRead = false

    init(address: String, projection: HerdrCoreConsoleProjection, clock: BlockedCardClock) {
        self.address = address
        self.projection = projection
        self.clock = clock
    }

    /// A Blocked Card's way to the Agent: its keys must reach the process whose
    /// screen it answered.
    var blockedScreen: BlockedScreenIO {
        BlockedScreenIO(
            readScreen: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.readScreen()
            },
            sendKeys: { [weak self] keys in
                guard let self else { throw TransportError.cancelled }
                try await self.press(keys, heldSinceScreenRead: true)
            },
            paste: { [weak self] text in
                guard let self else { throw TransportError.cancelled }
                try await self.paste(text, heldSinceScreenRead: true)
            },
            typeWhileShowing: { [weak self] typing, stillShows in
                guard let self else { throw TransportError.cancelled }
                switch typing {
                case .keys(let keys): try await self.press(keys, heldSinceScreenRead: true, whileShowing: stillShows)
                case .paste(let text): try await self.paste(text, heldSinceScreenRead: true, whileShowing: stillShows)
                }
            })
    }

    // MARK: Reading

    /// The screen now, colors kept. An attach of its own that only observes, so it
    /// counts for nothing in the Terminal's size, and closes once the paint is in.
    func readScreen() async throws -> ANSIScreen {
        let projection = try liveProjection()
        let holder = projection.terminalRecord(at: address).flatMap(Holder.init)
        holderChangedAtLastRead = screenHolder != nil && holder != screenHolder
        screenHolder = holder
        let session = try await open(as: .observe, on: projection)
        defer { Task { await session.end() } }
        return try await AsyncDeadline.run(for: HerdrCoreComposerSend.stepTimeout, sleep: clock.sleep) {
            var paint = HerdrCoreFirstPaint()
            for try await output in session.output {
                session.outputConsumed(output.count)
                if let screen = paint.receive(output) { return screen }
            }
            throw TransportError.cancelled
        }
    }

    // MARK: Typing

    /// Keys named as for `agent.send_keys`, in one write: OpenCode's two Escs have
    /// to arrive together.
    func press(
        _ keys: [String], heldSinceScreenRead: Bool = false,
        whileShowing stillShows: (@Sendable (ANSIScreen) -> Bool)? = nil
    ) async throws {
        let viewer = try await viewerToType(heldSinceScreenRead: heldSinceScreenRead, stillShows: stillShows)
        defer { viewer.leave() }
        var bytes = Data()
        for key in keys {
            guard let encoded = Self.bytes(forKeyNamed: key, modes: viewer.modes) else {
                throw Refusal(message: Self.unknownKey)
            }
            bytes.append(encoded)
        }
        try await write(bytes, on: viewer)
    }

    func paste(
        _ text: String, heldSinceScreenRead: Bool = false,
        whileShowing stillShows: (@Sendable (ANSIScreen) -> Bool)? = nil
    ) async throws {
        let viewer = try await viewerToType(heldSinceScreenRead: heldSinceScreenRead, stillShows: stillShows)
        defer { viewer.leave() }
        try await write(TerminalBracketedPaste.encode(text, bracketed: viewer.modes.usesBracketedPaste), on: viewer)
    }

    /// A viewer whose first paint is in, for one action. The caller leaves it.
    func openViewer() async throws -> HerdrCoreChatViewer {
        let projection = try liveProjection()
        let session = try await open(as: .resumed, on: projection)
        let address = address
        let viewer = HerdrCoreChatViewer(session: session) { [weak projection] in
            projection?.terminalRecord(at: address).map { .init(columns: $0.columns, rows: $0.rows) }
        }
        do {
            try await AsyncDeadline.run(for: HerdrCoreComposerSend.stepTimeout, sleep: clock.sleep) {
                try await viewer.untilPainted()
            }
        } catch {
            viewer.leave()
            throw error
        }
        return viewer
    }

    /// A viewer to press or paste through, with nothing changed while it opened.
    /// Its paint is newer than any read, so a dialog is checked against that.
    private func viewerToType(
        heldSinceScreenRead: Bool, stillShows: (@Sendable (ANSIScreen) -> Bool)?
    ) async throws -> HerdrCoreChatViewer {
        let projection = try liveProjection()
        let holder = try await checkHolder(in: projection, heldSinceScreenRead: heldSinceScreenRead)
        let viewer = try await openViewer()
        do {
            let holderNow = try await checkHolder(in: projection, heldSinceScreenRead: heldSinceScreenRead)
            guard holderNow == holder else { throw Refusal(message: Self.holderChangedWhileOpening) }
            if let stillShows, viewer.paintedScreen.map(stillShows) != true {
                throw Refusal(message: BlockedCardStore.changedMessage)
            }
        } catch {
            viewer.leave()
            throw error
        }
        return viewer
    }

    private func write(_ data: Data, on viewer: HerdrCoreChatViewer) async throws {
        try await AsyncDeadline.run(for: HerdrCoreComposerSend.stepTimeout, sleep: clock.sleep) {
            try await viewer.write(data, indexedAs: nil)
        }
    }

    private func open(
        as role: TerminalViewerRole, on projection: HerdrCoreConsoleProjection
    ) async throws -> TerminalAttachSession {
        let address = address
        return try await AsyncDeadline.run(for: HerdrCoreComposerSend.stepTimeout, sleep: clock.sleep) {
            try await projection.openChatViewer(at: address, as: role)
        }
    }

    private func liveProjection() throws -> HerdrCoreConsoleProjection {
        guard let projection else { throw TransportError.cancelled }
        return projection
    }

    private func checkHolder(
        in projection: HerdrCoreConsoleProjection, heldSinceScreenRead: Bool
    ) async throws -> Holder? {
        switch await HerdrCoreAgentHolder.current(at: address, in: projection, clock: clock) {
        case .success(let current):
            let holder = Holder(current.record)
            if heldSinceScreenRead, holderChangedAtLastRead || holder != screenHolder {
                throw Refusal(message: Self.holderChanged)
            }
            return holder
        case .failure(.agentLeft):
            throw Refusal(message: Self.agentLeft)
        case .failure(.notSampledYet):
            throw Refusal(message: Self.notSampledYet)
        case .failure(.noAnswer):
            throw Refusal(message: Self.noAnswer)
        }
    }

    // MARK: Keys

    /// `agent.send_keys` names its keys nearly as the core's grammar does. It also
    /// takes `plus`, keeps a capital's case, and takes any one character as typed.
    static func bytes(forKeyNamed name: String, modes: TerminalModeTracker) -> Data? {
        if name == "plus" { return TerminalKeyEncoder.encode("shift+=", modes: modes) }
        guard name.count == 1, let character = name.first else {
            return TerminalKeyEncoder.encode(name, modes: modes)
        }
        if character.isUppercase, character.isASCII {
            return TerminalKeyEncoder.encode("shift+\(character.lowercased())", modes: modes)
        }
        return TerminalKeyEncoder.encode(name, modes: modes) ?? Data(name.utf8)
    }

    // MARK: What Chat says

    private static let agentLeft = "The Agent no longer holds this terminal, so Heeler pressed nothing."
    private static let holderChanged =
        "Another process took over the terminal after Heeler read the screen, so Heeler pressed nothing."
    private static let holderChangedWhileOpening =
        "Another process took over the terminal as Heeler reached it, so Heeler pressed nothing."
    private static let notSampledYet = "The Agent is still starting, so Heeler pressed nothing. Try again in a moment."
    private static let noAnswer = "The Host did not answer, so Heeler pressed nothing. Check the connection and retry."
    private static let unknownKey = "Heeler can't press this key in this terminal, so it pressed nothing."
}
