import Foundation

/// Runs a plugin notice's action on one Herdr TUI Server, then rereads the
/// plugin. The action runs over a connection of its own, like the
/// preflight's: the Console's redials after a timeout and would run a step
/// twice. Steps stop at the first failure, which herdr leaves the plugin as
/// it was after.
struct HeelerPluginActionRunner: Sendable {
    /// What a run left behind.
    struct Outcome: Sendable, Equatable {
        /// The plugin as herdr's registry read after the steps. Nil when
        /// nothing ran, or when the plugin could not be read back.
        var readBack: HeelerPluginStatus?
        /// Why the action did not finish, in words the user can act on.
        var failure: HeelerPluginActionFailure?
        /// The steps ended without herdr's answer, or with one and no plugin
        /// to read back after it, so the Host may hold either version.
        var isUncertain = false
    }

    let host: Host
    var connector: any TransportConnector = SSHTransportConnector()
    var knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared
    var credentials = HostCredentialsProvider()
    var overlays: OverlayNetworkRuntime = .shared

    /// Runs `action`, which the user read on the notice's sheet.
    func run(_ action: HeelerPluginPresentation.Notice.Action) async -> Outcome {
        switch await connect() {
        case .failed(let failure):
            return Outcome(failure: failure)
        case .connected(let transport):
            let outcome = await perform(action, over: transport)
            try? await transport.close()
            return outcome
        }
    }

    /// Updates the plugin as the Host holds it now, without a sheet to read
    /// first (ADR 0048). It runs only the update a current reading still
    /// offers: a plugin that is up to date, or that an update no longer
    /// fits, is read back untouched.
    func update() async -> Outcome {
        switch await connect() {
        case .failed(let failure):
            return Outcome(failure: failure)
        case .connected(let transport):
            let status = await HeelerPluginStatus.read(over: transport)
            let outcome: Outcome
            switch status {
            case .installed, .notInstalled:
                if let action = HeelerPluginPresentation.unattendedUpdate(for: status, on: host) {
                    outcome = await perform(action, over: transport)
                } else {
                    outcome = Outcome(readBack: status)
                }
            case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable:
                outcome = Outcome(
                    failure: HeelerPluginActionFailure(
                        message: String(localized: "Heeler could not read the Host's plugin, so nothing changed.")))
            }
            try? await transport.close()
            return outcome
        }
    }

    private enum Dial {
        case connected(any Transport)
        case failed(HeelerPluginActionFailure)
    }

    private func connect() async -> Dial {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch {
            return .failed(
                HeelerPluginActionFailure(
                    message: String(localized: "Could not load this Host's credentials. (\(String(describing: error)))")))
        }
        // The preflight already settled the Host key, so a key that still
        // needs trusting is declined rather than asked about mid-change.
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
        let settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy, overlays: overlays)
        do {
            return .connected(try await connector.connect(settings: settings))
        } catch {
            return .failed(
                HeelerPluginActionFailure(
                    message: String(localized: "Heeler could not connect to the Host, so nothing changed."),
                    detail: (error as? TransportError)?.presentation.message ?? "\(error)"))
        }
    }

    private func perform(
        _ action: HeelerPluginPresentation.Notice.Action, over transport: any Transport
    ) async -> Outcome {
        var steps = action.steps
        var skippedInstall: HeelerPluginActionFailure?
        if steps.contains(.install) {
            switch await installClearance(over: transport) {
            case .clear:
                break
            case .nothingNewer(let reason):
                // The action's other steps still apply.
                steps.removeAll { $0 == .install }
                skippedInstall = reason
            case .refused(let reason):
                return Outcome(failure: reason)
            }
            if steps.isEmpty { return Outcome(failure: skippedInstall) }
        }
        var stepError: (any Error)?
        for step in steps {
            do {
                try await transport.runHeelerPluginStep(step)
            } catch {
                stepError = error
                break
            }
        }
        // herdr's registry is the answer either way: a step that timed out
        // may still have finished, and two devices may update at once.
        let status = await HeelerPluginStatus.read(over: transport)
        switch status {
        case .installed, .notInstalled:
            break
        case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable:
            // A step whose connection dropped may have finished all the same.
            guard let stepError else {
                return Outcome(
                    failure: HeelerPluginActionFailure(
                        message: String(localized: "The change finished, but the plugin could not be read back. Run the checks again.")),
                    isUncertain: true)
            }
            if let error = stepError as? TransportError, error != .timedOut {
                return Outcome(
                    failure: HeelerPluginActionFailure(
                        message: String(localized: "The connection ended during the change, which may still finish on the Host. Run the checks again."),
                        detail: error.presentation.message),
                    isUncertain: true)
            }
            // A step that said why it failed is no more in doubt for the
            // plugin being unreadable after it.
            return Outcome(failure: HeelerPluginActionFailure(stepError), isUncertain: stepError is TransportError)
        }
        let presentation = HeelerPluginPresentation(
            status, session: host.sessionName, endpoint: host.herdrEndpoint)
        guard presentation.notice != nil else { return Outcome(readBack: status) }
        if let stepError { return Outcome(readBack: status, failure: HeelerPluginActionFailure(stepError)) }
        if let skippedInstall { return Outcome(readBack: status, failure: skippedInstall) }
        let bundled = HeelerPluginCompatibility.bundled
        if let version = status.confirmedVersion, version < bundled {
            return Outcome(
                readBack: status,
                failure: HeelerPluginActionFailure(
                    message: String(localized: "herdr installed plugin \(String(describing: version)), the newest published, but this app expects \(String(describing: bundled)).")))
        }
        return Outcome(
            readBack: status,
            failure: HeelerPluginActionFailure(
                message: String(localized: "The change finished, but the plugin still needs the attention described above.")))
    }

    /// Whether an action's install may run. herdr installs whatever the
    /// plugin branch holds, and an app built ahead of the branch, or a Host
    /// installed from elsewhere, can have a newer plugin than that. The
    /// branch only moves forward (ADR 0026), so the version read here is the
    /// least herdr installs. The Host's plugin is reread rather than taken
    /// from the checks, since another device may have changed it; a refusal
    /// reads nothing back, so the sheet keeps the action it explains.
    private enum InstallClearance {
        case clear
        /// The Host's plugin is newer than the branch.
        case nothingNewer(HeelerPluginActionFailure)
        case refused(HeelerPluginActionFailure)
    }

    private func installClearance(over transport: any Transport) async -> InstallClearance {
        let installed: PluginVersion
        switch await HeelerPluginStatus.read(over: transport) {
        case .notInstalled:
            return .clear
        case .installed(let installation):
            guard !installation.isLegacyID, installation.isReplaceableByInstall,
                let version = installation.parsedVersion
            else {
                return .refused(HeelerPluginActionFailure(
                    message: String(localized: "The plugin on the Host changed since the checks, so nothing changed. Run the checks again.")))
            }
            installed = version
        case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable:
            return .refused(HeelerPluginActionFailure(
                message: String(localized: "Heeler could not read the Host's plugin before changing it, so nothing changed. Run the checks again.")))
        }
        let published: PluginVersion
        do {
            published = try await transport.readPluginBranchVersion()
        } catch {
            let detail =
                switch error {
                case let error as PluginBranchVersionError: error.output.isEmpty ? nil : error.output
                case let error as TransportError: error.presentation.message
                default: "\(error)"
                }
            return .refused(HeelerPluginActionFailure(
                message: String(localized: "Heeler could not check which plugin version the Host would install, so nothing changed. Check that the Host can reach github.com."),
                detail: detail))
        }
        guard published >= installed else {
            return .nothingNewer(HeelerPluginActionFailure(
                message: String(localized: "The Host has plugin \(String(describing: installed)), newer than the published \(String(describing: published)), so Heeler did not update it.")))
        }
        return .clear
    }
}

extension HeelerPluginPresentation {
    /// The update Update All runs without showing its commands first
    /// (ADR 0048): an enabled plugin with a version herdr read from a fresh
    /// manifest, older than the app's, whose notice already offers an install
    /// Heeler can run. A first install, a disabled plugin, a linked checkout
    /// and a plugin under its former name stay with the notice's sheet.
    static func unattendedUpdate(
        for status: HeelerPluginStatus, on host: Host,
        bundled: PluginVersion = HeelerPluginCompatibility.bundled
    ) -> Notice.Action? {
        guard let version = status.confirmedVersion, version < bundled,
            let action = HeelerPluginPresentation(
                status, session: host.sessionName, endpoint: host.herdrEndpoint, bundled: bundled
            ).notice?.action,
            action.steps.contains(.install)
        else { return nil }
        return action
    }
}
