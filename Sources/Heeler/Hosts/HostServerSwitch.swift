import Foundation

/// Turns a Host's Servers on and off (ADR 0047): the catalog's part, and the
/// host key trust beside it, which lives outside the catalog and which every
/// record of a Host shares.
@MainActor
struct HostServerSwitch {
    let catalog: HostStore
    let knownHosts: any KnownHostsStore
    /// A herdr-core Server was found on a native Windows machine, which its
    /// first connection may never reach to say.
    var noteWindowsCore: @MainActor (Host.ID) -> Void = { _ in }

    init(catalog: HostStore, dependencies: HostOnboardingDependencies) {
        self.catalog = catalog
        knownHosts = dependencies.knownHosts
        noteWindowsCore = dependencies.noteWindowsCore
    }

    /// Turns `server` on for the Host that `member` is a record of, with what
    /// `scan` read of it where a look just found it. A record added for it has
    /// the Host's trusted keys before it exists, so the Console's first
    /// connection to it never meets an unknown key.
    @discardableResult
    func turnOn(
        _ server: HostServerKey, onHostOf member: Host.ID, scan: HostServerScan? = nil
    ) async throws -> Host {
        guard let machine = catalog.machine(containing: member) else { throw HostStoreError.unknownHost }
        let recordID = UUID()
        let addsRecord = machine.needsRecord(for: server)
        if addsRecord {
            await knownHosts.copyTrust(from: machine.representative.id, to: recordID)
        }
        do {
            let record = try catalog.turnOn(
                server, onHostOf: member, tmuxPaths: scan?.tmuxPaths(for: server), newRecordID: recordID)
            if server.kind == .herdrCore, scan?.isNativeWindows == true { noteWindowsCore(record.id) }
            return record
        } catch {
            if addsRecord { await knownHosts.forgetHost(recordID) }
            throw error
        }
    }

    /// Gives the Host's records that trust no key yet the keys `record` trusts,
    /// after a look just reached the Host through it. A record with a key of
    /// its own keeps it: only the user replaces a trusted key.
    func shareTrust(of record: Host.ID) async {
        guard let machine = catalog.machine(containing: record) else { return }
        for member in machine.members where member.id != record {
            let key = HostKeyTrust.hostKey(member.id)
            if await knownHosts.fingerprints(host: key.host, port: key.port).isEmpty {
                await knownHosts.copyTrust(from: record, to: member.id)
            }
        }
    }

    /// Why a Server could not be turned on, for the user to read.
    func refusal(_ error: any Error, turningOn server: HostServerKey) -> String {
        switch error {
        case HostStoreError.sessionNameRefused(let reason):
            return reason
        case HostStoreError.catalogUnreadable where server.kind == .tmux && catalog.tmuxCatalogLoadError != nil:
            return String(localized: "The saved tmux Hosts could not be read, so no tmux Host can be added.")
        case HostStoreError.catalogUnreadable where server.kind == .herdrCore && catalog.coreCatalogLoadError != nil:
            return String(
                localized: "The saved herdr-core Hosts could not be read, so no herdr-core Host can be added.")
        default:
            return String(localized: "The Server could not be turned on. (\(String(describing: error)))")
        }
    }
}
