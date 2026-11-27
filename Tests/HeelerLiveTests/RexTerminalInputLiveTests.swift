import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import Heeler

/// Explicit opt-in only: input to a Rex terminal (ADR 0052) through the
/// Console's runner, the store a view uses and its input controller, against a
/// Rex server that already runs on this Mac, over its local Unix socket. It
/// never runs in the HeelerTests target or in CI, and fails rather than skips
/// when selected without its configuration.
///
/// It creates one session labeled `heeler-lab-r5-…` with one shell under a
/// scrubbed environment, types into that shell only, reads the result back
/// from the server's own text of the terminal, then destroys the session. It
/// opens no other session's terminal and prints only counts and states, never
/// labels or terminal text. `/tmp/heeler-lab-home` must exist.
///
/// ```sh
/// mkdir -p /tmp/heeler-lab-home
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexTerminalInputLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@MainActor
@Suite("Rex terminal input over a local socket", .serialized, .timeLimit(.minutes(2)))
struct RexTerminalInputLiveTests {
    @Test func typingAndPastingReachALabShell() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        let lab = try await RexLab.open(path: socketPath)
        var failure: (any Error)?
        do {
            try await run(lab, socketPath: socketPath)
        } catch {
            failure = error
        }
        let remaining = await lab.destroyEverything()
        print("Rex lab: \(remaining.lab) lab sessions remain, \(remaining.total) sessions in all")
        #expect(remaining.lab == 0)
        await lab.control.close()
        if let failure { throw failure }
    }

    private func run(_ lab: RexLab, socketPath: String) async throws {
        let created = try await lab.createSession(
            blocks: [("shell", ["/bin/sh"])], grid: LocalGrid(columns: 100, rows: 30), name: "r5")
        let address = RexPaneAddress(sessionID: created.id, blockID: created.blocks[0])
        let server = { try await lab.text(session: address.sessionID, block: address.blockID, unwrap: true) }

        let session = RexHostSession(storedSocket: RexSocket(path: socketPath)) { _, previous in
            try await LocalRexTransport.connect(path: socketPath, resuming: previous)
        }
        await session.resume()
        let host = Host(
            name: "Rex", address: "localhost", username: "lab", serverKind: .rex,
            rexSocket: RexSocket(path: socketPath))
        let runner = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), onChange: {}
        ).terminalRunner()
        let input = TerminalInputController()
        let pin = TerminalCorePin()
        // Off screen, as the retention pool keeps a terminal, so it never
        // takes the block's size (ADR 0053) and types into a block another
        // client owns.
        let store = AttachTerminalStore(
            target: .terminal(address.paneID), isViewed: false, input: input, observeOutput: { _ in },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })

        store.viewDidResize(cols: 100, rows: 30)
        #expect(!input.send(Data("early\r".utf8)))
        try await waitUntil("the first paint", timeout: .seconds(20)) { store.status == .live }
        let owner =
            switch store.sizeReport?.owner {
            case nil: "no owner"
            case store.sizeReport?.client: "this client"
            default: "another client"
            }
        print("Rex lab: the block has \(owner) while Heeler types")

        // A shell that echoes nothing, so the server's text holds only what
        // `cat -v` prints back.
        #expect(input.send(Data("stty -echo; cat -v\r".utf8)))
        try await Task.sleep(for: .milliseconds(500))

        // A long numbered sequence, each token its own write, as fast as the
        // view hands them over: every one arrives, once, in order.
        let count = 300
        for number in 1...count {
            let token = String(format: "k%04d ", number) + (number % 20 == 0 ? "\r" : "")
            #expect(input.send(Data(token.utf8)))
        }
        try await waitUntil("the sequence", timeout: .seconds(20)) {
            ((try? await server()) ?? "").contains(String(format: "k%04d", count))
        }
        let numbers = Self.tokens(in: try await server())
        print("Rex lab: \(numbers.count) of \(count) tokens came back, in order: \(numbers == Array(1...count))")
        #expect(numbers == Array(1...count))

        // Pastes with bracketed paste off: one reviewed through the
        // controller, one with an ESC carried in the view's own bytes.
        try await paste(into: input, marker: "p1")
        try await waitUntil("the unbracketed pastes", timeout: .seconds(10)) {
            ((try? await server()) ?? "").contains("p1-esc-after")
        }
        let off = try await server()
        let offBracketed = off.contains("^[[200~")
        let offEscape = Self.escapeShown(in: off, marker: "p1")
        print("Rex lab: with bracketed paste off, markers \(offBracketed), the ESC shown as \(offEscape)")
        #expect(!offBracketed)
        #expect(off.contains("p1-one\np1-two"))

        // The same with the program's bracketed paste on.
        #expect(input.send(Data([0x03])))
        try await Task.sleep(for: .milliseconds(300))
        #expect(input.send(Data("printf '\\033[?2004h'; cat -v\r".utf8)))
        try await Task.sleep(for: .milliseconds(500))
        try await paste(into: input, marker: "p2")
        try await waitUntil("the bracketed pastes", timeout: .seconds(10)) {
            ((try? await server()) ?? "").contains("p2-esc-after")
        }
        let on = try await server()
        let onBracketed = on.contains("^[[200~p2-one") && on.contains("p2-two^[[201~")
        let onEscape = Self.escapeShown(in: on, marker: "p2")
        print("Rex lab: with bracketed paste on, markers \(onBracketed), the ESC shown as \(onEscape)")
        #expect(onBracketed)
        #expect(input.send(Data([0x03])))
        #expect(store.status == .live)

        let left = await lab.destroyEverything()
        #expect(left.lab == 0)
        try await waitUntil("the terminal's end", timeout: .seconds(10)) { store.status == .finished }
        await store.stop()
        await session.end()
    }

    /// Two pastes: newlines through the reviewed path, and an ESC inside a
    /// bracketed paste the view's bytes carry, which the controller's own
    /// clipboard check would refuse. A typed Return ends each line, so
    /// `cat -v` prints it.
    private func paste(into input: TerminalInputController, marker: String) async throws {
        #expect(input.requestPaste("\(marker)-one\n\(marker)-two").requiresReview)
        #expect(input.confirmPaste())
        #expect(input.send(Data("\r".utf8)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(input.send(Data("\u{1B}[200~\(marker)-esc-before\u{1B}\(marker)-esc-after\u{1B}[201~\r".utf8)))
    }

    /// The `k0001`-style tokens in `text`, in order, as numbers.
    static func tokens(in text: String) -> [Int] {
        text.matches(of: /k(\d{4})/).compactMap { Int($0.output.1) }
    }

    /// How `cat -v` printed the ESC between a paste's two words.
    static func escapeShown(in text: String, marker: String) -> String {
        guard let before = text.range(of: "\(marker)-esc-before"),
            let after = text.range(of: "\(marker)-esc-after", range: before.upperBound..<text.endIndex)
        else { return "missing" }
        let between = text[before.upperBound..<after.lowerBound]
        switch between {
        case "^[": return "^["
        case " ": return "a space"
        case "": return "nothing"
        default: return "\(between.count) characters"
        }
    }

    private func waitUntil(
        _ what: String, timeout: Duration, sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }
}

@MainActor
@Suite("Rex Terminal Composer after a foreground handover", .serialized, .timeLimit(.minutes(2)))
struct RexTerminalTakeoverLiveTests {
    @Test func anotherClientsUnsubmittedShellLineSurvivesAnAgentsExit() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_REX_TERMINAL_TAKEOVER_LAB"])
        let observed = try await RexTerminalTakeoverObservation.run(path: path)
        #expect(observed.refusedWithoutSubmitting)
        #expect(observed.mobileDraftRestored)
        #expect(observed.host.wire.acceptedPastes == 1)
        #expect(observed.host.wire.desktopTextVerifiedBeforeRelease)
        #expect(observed.host.wire.releasedPasteReceipts == 1)
        #expect(observed.host.wire.mobileAfterPaste.isEmpty)
        #expect(observed.host.wire.peerWrites == 0)
        #expect(observed.host.shells["target"]?.exactDesktopText == true)
        #expect(observed.host.shells["peer"]?.exactDesktopText == true)
        #expect(observed.host.shells.values.allSatisfy { $0.sameShellPID && !$0.commandExecuted })
    }
}

// The independent desktop reads Bash's actual READLINE_LINE on both sides
// after the phone closes its control connection. No second Enter is needed.
@MainActor
struct RexTerminalTakeoverObservation: Codable {
    struct HostEvidence: Codable {
        struct Wire: Codable {
            let acceptedPastes, releasedPasteReceipts, peerWrites: Int
            let desktopTextVerifiedBeforeRelease: Bool
            let mobileAfterPaste: [String]
        }
        struct Shell: Codable {
            let sameShellPID, exactDesktopText, commandExecuted: Bool
            let expectedReadlineBase64, actualReadlineBase64: String
        }
        let wire: Wire
        let shells: [String: Shell]
    }
    let refusedWithoutSubmitting, mobileDraftRestored: Bool
    let host: HostEvidence

    private struct Fixture: Decodable {
        struct Side: Decodable { let session, block: String }
        let port: Int
        let user, seed, fingerprint, rexSocket, directory, phoneText: String
        let target, peer: Side
    }
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(path: String) async throws -> Self {
        let lab = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let socket = RexSocket(path: lab.rexSocket), let secret = Data(base64Encoded: lab.seed),
              ["/tmp/heeler-lab-", "/private/tmp/heeler-lab-"].contains(where: lab.directory.hasPrefix),
              lab.phoneText.hasPrefix("REX_LAB_MOBILE_"),
              lab.target.session != lab.peer.session, lab.target.block != lab.peer.block else {
            throw Failure(description: "Expected two different private foregrounds")
        }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        let settings = SSHTransportSettings(host: "127.0.0.1", port: lab.port, username: lab.user,
            credentials: .ed25519(privateKey), hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) {
                $0.fingerprint.displayString == lab.fingerprint
            }, socket: .absolutePath("/nonexistent/herdr.sock"))
        let host = Host(name: "heeler-lab-terminal-takeover", address: "127.0.0.1", port: lab.port,
                        username: lab.user, serverKind: .rex, rexSocket: socket)
        let session = RexHostSession(storedSocket: socket) { saved, previous in
            try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: settings), socket: saved, resuming: previous)
        }
        let observer = try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: settings), socket: socket)
        let console = ConsoleStore(makeRexSession: { _ in session })
        console.setHosts([host])
        do {
            await console.resume()
            let pane = RexPaneAddress(sessionID: lab.target.session, blockID: lab.target.block).paneID
            func target() -> ConsoleAgent? {
                console.agents.first { $0.id.hostID == host.id && $0.agent.paneID == pane
                    && $0.agent.kind == "pi" && $0.agent.cwd == lab.directory }
            }
            let deadline = ContinuousClock.now + .seconds(20)
            while target() == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard let agent = target() else { throw Failure(description: "The real Pi foreground did not appear in Agents") }
            let composer = console.composerStore(for: agent)
            composer.replaceDraft(with: lab.phoneText)
            let sent = await composer.send(policy: .terminal)
            let refused: Bool
            if case .refused(.notSubmitted) = sent { refused = true } else { refused = false }
            let restored = composer.draft == lab.phoneText
            console.setHosts([])
            await session.end()
            let evidencePath = (lab.rexSocket as NSString).deletingLastPathComponent + "/after.json"
            let limit = ContinuousClock.now + .seconds(15)
            repeat {
                if let size = try await observer.reads.fileStatus(atPath: evidencePath)?.size, size > 0 && size < 65536 {
                    let read = try await observer.reads.readHostFileRange(.init(path: evidencePath, offset: 0, maxBytes: 65536))
                    let observed = try JSONDecoder().decode(HostEvidence.self, from: read.data)
                    await observer.close()
                    return Self(refusedWithoutSubmitting: refused, mobileDraftRestored: restored, host: observed)
                }
                try await Task.sleep(for: .milliseconds(120))
            } while ContinuousClock.now < limit
            throw Failure(description: "The independent shell inspection did not complete")
        } catch {
            console.setHosts([])
            await session.end()
            await observer.close()
            throw error
        }
    }
}
