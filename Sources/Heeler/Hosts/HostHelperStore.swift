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

    @ObservationIgnored private let connect: @Sendable () async throws -> any HerdrCoreTransport
    @ObservationIgnored private let bundle: @Sendable () throws -> HostHelperBundle
    @ObservationIgnored private let nonce: @Sendable () -> String

    init(
        connect: @escaping @Sendable () async throws -> any HerdrCoreTransport,
        bundle: @escaping @Sendable () throws -> HostHelperBundle = { try HostHelperBundle.load() },
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.connect = connect
        self.bundle = bundle
        self.nonce = nonce
    }

    var status: HostHelperStatus? {
        if case .read(let reading) = reading { reading.status } else { nil }
    }

    /// What Host detail's row says.
    var rowValue: String {
        switch reading {
        case .checking: "Checking…"
        case .unavailable: "Unavailable"
        case .read(let reading): HostHelperPresentation(reading.status).value
        }
    }

    var detail: String? {
        switch reading {
        case .checking: nil
        case .unavailable(let message): message
        case .read(let reading): HostHelperPresentation(reading.status).detail
        }
    }

    var needsAttention: Bool {
        switch reading {
        case .checking, .unavailable: false
        case .read(let reading): HostHelperPresentation(reading.status).needsAttention
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

    /// Reads the Host over a connection the caller owns, such as the preflight's.
    func refresh(over transport: any HerdrCoreTransport) async {
        do {
            let read = try await installer(transport).read()
            if !Task.isCancelled { adopt(read) }
        } catch {
            if !Task.isCancelled { reading = .unavailable(message: Self.message(for: error)) }
        }
    }

    /// Reads the Host over a connection of its own.
    func refresh() async {
        do {
            let transport = try await connect()
            await refresh(over: transport)
            try? await transport.close()
        } catch {
            if !Task.isCancelled { reading = .unavailable(message: Self.message(for: error)) }
        }
    }

    func install() async {
        await perform(.install) { installer, reading, bundle in
            _ = try await installer.install(over: reading, bundle: try bundle())
        }
    }

    func remove() async {
        await perform(.remove) { installer, reading, _ in
            try await installer.remove(over: reading)
        }
    }

    func turnOnLinger() async {
        await perform(.turnOnLinger) { installer, reading, _ in
            try await installer.turnOnLinger(over: reading)
        }
    }

    private func adopt(_ read: HostHelperReading) {
        reading = .read(read)
        plan = read.installAction == nil
            ? nil : (try? bundle()).flatMap { try? HostHelperInstallPlan(reading: read, bundle: $0) }
    }

    /// Works from what the Host says now, not what the sheet last read: another
    /// device may have installed a newer Helper since. The Host is read again
    /// afterwards either way, since a failed step may have changed it.
    private func perform(
        _ action: Action,
        _ work: @escaping @Sendable (
            HostHelperInstaller, HostHelperReading, @Sendable () throws -> HostHelperBundle
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
            try await work(installer, try await installer.read(), bundle)
        } catch {
            failure = Self.message(for: error)
        }
        await refresh(over: transport)
        try? await transport.close()
    }

    private func installer(_ transport: any HerdrCoreTransport) -> HostHelperInstaller {
        HostHelperInstaller(host: transport.hostHelperHost, nonce: nonce)
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
