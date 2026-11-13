import Foundation

/// One live terminal on a Host's framed link: a viewer of its own, on a channel
/// of its own (ADR 0031). Every byte the user types goes out unchanged as DATA,
/// since no viewer chord is taken out of the input, and a repaint the core sends
/// after a backlog is output like any other.
///
/// CREDIT leaves as the view takes bytes, so a view that stops taking them holds
/// up this channel alone. A server CLOSE finishes `output` cleanly, and `end()`
/// sends CLOSE. The link ending under it reads as a lost connection.
enum HerdrCoreAttach {
    static func open(
        on link: HerdrCoreLink, request: TerminalAttachRequest, deadline: Duration
    ) async throws -> TerminalAttachSession {
        let (_, stream) = try await link.openStream(
            "terminal.attach", params: try params(for: request), deadline: deadline,
            creditsWhenConsumed: true)
        let input = TerminalAttachInputQueue()
        let pump = Task {
            // A write fails only once the channel or the link has ended, which
            // `output` reports: there is nothing else for this task to say.
            try? await input.pump(
                write: { try await stream.write($0) },
                resize: { columns, rows in
                    guard Self.isValidGeometry(columns: columns, rows: rows) else { return }
                    try await stream.resize(columns: columns, rows: rows)
                })
        }
        let (presences, presence) = AsyncStream.makeStream(of: TerminalViewerPresence.self)
        let presencePump = Task {
            for await change in presences {
                do { try await Self.send(change, on: stream) } catch { return }
            }
        }
        let firstPaint = HerdrCoreFirstPaintHold()
        return TerminalAttachSession(
            output: { Self.output(of: stream, holding: firstPaint) },
            input: input,
            onConsumed: { count in
                let owed = firstPaint.consumed(count)
                guard owed > 0 else { return }
                Task { await stream.consumed(owed) }
            },
            onPresence: { presence.yield($0) }
        ) {
            input.finish()
            presence.finish()
            pump.cancel()
            presencePump.cancel()
            await stream.close()
        }
    }

    private static let firstPaintHistory = 10_000

    static func params(for request: TerminalAttachRequest) throws -> JSONValue {
        guard isValidGeometry(columns: request.cols, rows: request.rows) else {
            throw TransportError.channelFailed(detail: String(localized: "Invalid herdr-core terminal geometry."))
        }
        var params: [String: JSONValue] = [
            "terminal": .string(try HerdrCoreWire.address(request.target.identifier)),
            "cols": .number(Double(request.cols)),
            "rows": .number(Double(request.rows)),
        ]
        switch request.viewer {
        case .interactive: break
        case .resumed: params["resumed"] = .bool(true)
        case .observe: params["observe"] = .bool(true)
        }
        if let facts = request.displayFacts {
            params["display"] = displayValue(facts)
        }
        // The core paints no history unless asked. Its own client asks once too.
        if !request.surfaceHasHistory {
            params["history"] = .number(Double(firstPaintHistory))
        }
        return .object(params)
    }

    private static func isValidGeometry(columns: Int, rows: Int) -> Bool {
        let side = 1...Int(UInt16.max)
        return side.contains(columns) && side.contains(rows)
    }

    private static func displayValue(_ facts: TerminalDisplayFacts) -> JSONValue {
        var display: [String: JSONValue] = [:]
        display["fg"] = facts.foreground.map(JSONValue.string)
        display["bg"] = facts.background.map(JSONValue.string)
        display["cursor"] = facts.cursor.map(JSONValue.string)
        display["cell"] = facts.cell.map {
            .array([.number(Double($0.width)), .number(Double($0.height))])
        }
        return .object(display)
    }

    private static func send(
        _ presence: TerminalViewerPresence, on stream: HerdrCoreLinkStream
    ) async throws {
        switch presence {
        case .viewed(let facts):
            try await stream.focus(gained: true)
            if let facts { try await sendFacts(facts, on: stream) }
        case .hidden:
            try await stream.focus(gained: false)
        case .factsChanged(let facts):
            try await sendFacts(facts, on: stream)
        }
    }

    private static func sendFacts(
        _ facts: TerminalDisplayFacts, on stream: HerdrCoreLinkStream
    ) async throws {
        try await stream.facts(try JSONEncoder().encode(displayValue(facts)))
    }

    /// A store reattaches after a lost connection, which any failure of the
    /// link comes to: a core restart reopens it on the same SSH connection.
    /// The first paint comes out whole (`HerdrCoreFirstPaintHold`).
    private static func output(
        of stream: HerdrCoreLinkStream, holding firstPaint: HerdrCoreFirstPaintHold
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream {
            do {
                return try await firstPaint.next(
                    read: { try await stream.read() }, credit: { await stream.consumed($0) })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TransportError.cancelled
            }
        }
    }
}
