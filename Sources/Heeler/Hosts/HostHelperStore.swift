import Foundation
import Observation

/// One core Host's Host Helper as Host detail and the install sheet show it.
/// Each read and action runs over a connection of its own, like the plugin's:
/// a step that redialed partway could run twice.
@MainActor
@Observable
final class HostHelperStore {
    enum Reading: Equatable {
        case checking
        case read(HostHelperReading)
        /// The Host could not be asked; nothing is known about its Helper.
        case unavailable(message: String)
    }

    enum Action: Equatable {
        case install
        case remove
        case turnOnLinger
    }

    private(set) var reading = Reading.checking
    /// What an install would write, for the sheet to list before it does.
    private(set) var plan: HostHelperInstallPlan?
    /// The action in flight.
    private(set) var running: Action?
    /// Why the last action failed, in words the user can act on.
    private(set) var failure: String?

    /// What a removal had to leave of the edits that go with the Helper.
    @ObservationIgnored private var editsLeft: String?
    /// Why the reading offers an install it cannot list.
    @ObservationIgnored private var planFailure: String?
    /// How many actions have finished their work. A read begun under an older
    /// count may hold the Host as it was before that action, whose own read back
    /// has the last word.
    @ObservationIgnored private var actionsDone = 0
    /// An action has run and the Host has been read back: what else follows the
    /// Helper should look again.
    @ObservationIgnored var onChanged: (@MainActor () -> Void)?

    @ObservationIgnored private let connect: @Sendable () async throws -> any HerdrCoreTransport
    @ObservationIgnored private let bundle: @Sendable () throws -> HostHelperBundle
    @ObservationIgnored private let nonce: @Sendable () -> String
    @ObservationIgnored private let healthGap: @Sendable () async throws -> Void
    /// Undoes what goes with the Helper over the removal's own connection, and says
    /// what it had to leave.
    @ObservationIgnored private let undoEdits: @MainActor @Sendable (any HostServices) async throws -> String?

    init(
        connect: @escaping @Sendable () async throws -> any HerdrCoreTransport,
        bundle: @escaping @Sendable () throws -> HostHelperBundle = { try HostHelperBundle.load() },
        nonce: @escaping @Sendable () -> String = { UUID().uuidString },
        healthGap: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: HostHelperLaunchAgent.healthGap)
        },
        undoEdits: @escaping @MainActor @Sendable (any HostServices) async throws -> String? = { _ in nil }
    ) {
        self.connect = connect
        self.bundle = bundle
        self.nonce = nonce
        self.healthGap = healthGap
        self.undoEdits = undoEdits
    }

    var status: HostHelperStatus? {
        if case .read(let reading) = reading { reading.status } else { nil }
    }

    /// What Host detail's row says.
    var rowValue: String {
        switch reading {
        case .checking: "Checking…"
        case .unavailable: "Unavailable"
        case .read(let reading): reading.presentation.value
        }
    }

    var detail: String? {
        switch reading {
        case .checking: nil
        case .unavailable(let message): message
        case .read(let reading): reading.presentation.detail
        }
    }

    var needsAttention: Bool {
        switch reading {
        case .checking, .unavailable: false
        case .read(let reading): reading.presentation.needsAttention
        }
    }

    var installAction: HostHelperInstallAction? {
        if case .read(let reading) = reading { reading.installAction } else { nil }
    }

    var offersRemoval: Bool {
        if case .read(let reading) = reading { reading.offersRemoval } else { false }
    }

    var offersLinger: Bool {
        if case .read(let reading) = reading { reading.offersLinger } else { false }
    }

    /// What the removal's confirmation says. A Mac has no linger to leave.
    var removalMessage: String {
        if case .read(let reading) = reading, reading.probe?.manager == .launchd {
            return HostHelperSheet.macOSRemovalMessage
        }
        return HostHelperSheet.removalMessage
    }

    /// A preflight has begun. What the Host last said no longer answers for it,
    /// and until the preflight reads it again nothing is known.
    func checkStarted() {
        if running == nil { failure = nil }
        forgetReading(.checking)
    }

    /// A preflight has ended. One that never got to read the Host leaves its
    /// Helper unknown, not still being checked.
    func checkEnded(unreadBecause reason: String) {
        if reading == .checking { forgetReading(.unavailable(message: reason)) }
    }

    /// What a Mac's check still has to do once the Host has been read, over the
    /// connection the caller still owns.
    typealias HealthConfirmation = @MainActor @Sendable () async -> Void

    /// Checks the Host over a connection the caller owns, such as the preflight's.
    /// A new check answers for the Host as it is now, so the last action's failure
    /// goes, unless that action is still running and has yet to report. The second
    /// health read a LaunchAgent takes comes back for the caller to run, as it is
    /// over ten seconds away, and until it has run nothing has been concluded.
    func beginRefresh(over transport: any HerdrCoreTransport) async -> HealthConfirmation? {
        if running == nil { failure = nil }
        let began = actionsDone
        let installer = installer(transport)
        do {
            let first = try await installer.readLoadingAgent()
            guard first.awaitsSecondHealthRead else {
                if answers(began) { adopt(first) }
                return nil
            }
            guard answers(began) else { return nil }
            return { [self] in
                do {
                    let read = try await installer.confirmingHealth(of: first)
                    if answers(began) { adopt(read) }
                } catch {
                    if answers(began) { forgetReading(.unavailable(message: Self.message(for: error))) }
                }
            }
        } catch {
            if answers(began) { forgetReading(.unavailable(message: Self.message(for: error))) }
            return nil
        }
    }

    /// Checks the Host over a connection of its own.
    func refresh() async {
        if running == nil { failure = nil }
        let began = actionsDone
        do {
            let transport = try await connect()
            await read(over: transport, began: began)
            try? await transport.close()
        } catch {
            if answers(began) { forgetReading(.unavailable(message: Self.message(for: error))) }
        }
    }

    /// Writes nothing until the sheet has listed what it will write. With no list
    /// showing, this only tries again to make one.
    func install() async {
        guard plan != nil else {
            await listInstall()
            return
        }
        await perform(.install) { installer, reading, bundle, _ in
            _ = try await installer.install(over: reading, bundle: try bundle())
        }
    }

    func remove() async {
        editsLeft = nil
        await perform(.remove) { [self] installer, reading, _, services in
            try await installer.remove(over: reading) {
                try await self.undoEditsGoingWithTheHelper(over: services)
            }
        }
        if failure == nil { failure = editsLeft }
    }

    private func undoEditsGoingWithTheHelper(over services: any HostServices) async throws {
        editsLeft = try await undoEdits(services)
    }

    func turnOnLinger() async {
        await perform(.turnOnLinger) { installer, reading, _, _ in
            try await installer.turnOnLinger(over: reading)
        }
    }

    private func listInstall() async {
        guard running == nil else { return }
        running = .install
        failure = nil
        defer { running = nil }
        do {
            let transport = try await connect()
            await read(over: transport)
            try? await transport.close()
            failure = planFailure
        } catch {
            failure = "Heeler could not connect to the Host, so nothing changed. " + Self.message(for: error)
        }
    }

    private func read(over transport: any HerdrCoreTransport, began: Int? = nil) async {
        let began = began ?? actionsDone
        do {
            let read = try await installer(transport).check()
            if answers(began) { adopt(read) }
        } catch {
            if answers(began) { forgetReading(.unavailable(message: Self.message(for: error))) }
        }
    }

    /// Whether a read that began at this count may still say how the Host is.
    private func answers(_ began: Int) -> Bool {
        !Task.isCancelled && began == actionsDone
    }

    private func adopt(_ read: HostHelperReading) {
        reading = .read(read)
        plan = nil
        planFailure = nil
        guard read.installAction != nil else { return }
        do {
            plan = try HostHelperInstallPlan(reading: read, bundle: try bundle())
        } catch {
            planFailure = Self.message(for: error)
        }
    }

    /// The file list came from the reading, so it goes with it.
    private func forgetReading(_ replacement: Reading) {
        reading = replacement
        plan = nil
        planFailure = nil
    }

    /// Works from what the Host says now, not what the sheet last read: another
    /// device may have installed a newer Helper since. The Host is read again
    /// afterwards either way, since a failed step may have changed it.
    private func perform(
        _ action: Action,
        _ work: @escaping @Sendable (
            HostHelperInstaller, HostHelperReading, @Sendable () throws -> HostHelperBundle, any HostServices
        ) async throws -> Void
    ) async {
        guard running == nil else { return }
        running = action
        failure = nil
        defer { running = nil }
        let transport: any HerdrCoreTransport
        do {
            transport = try await connect()
        } catch {
            failure = "Heeler could not connect to the Host, so nothing changed. " + Self.message(for: error)
            return
        }
        let installer = installer(transport)
        do {
            try await work(installer, try await installer.read(), bundle, transport.hostServices)
        } catch {
            failure = Self.message(for: error)
        }
        actionsDone += 1
        await read(over: transport)
        try? await transport.close()
        onChanged?()
    }

    private func installer(_ transport: any HerdrCoreTransport) -> HostHelperInstaller {
        HostHelperInstaller(host: transport.hostHelperHost, nonce: nonce, bundle: bundle, healthGap: healthGap)
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as HostHelperError: error.message
        case is HostHelperBundle.LoadError: HostHelperError.bundleUnavailable.message
        case let error as TransportError: error.presentation.message
        default: "\(error)"
        }
    }
}
