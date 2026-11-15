import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Host server discoveries")
struct HostServerDiscoveryStoreTests {
    private static let tmuxPath = "/home/dev/.local/bin/tmux"
    private static let defaultTmux = HostServerKey(kind: .tmux, name: "")
    private static let workTmux = HostServerKey(kind: .tmux, name: "work")
    private static let core = HostServerKey(kind: .herdrCore, name: "")
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(address: String = "studio.example", kind: ServerKind = .herdrTUI, session: String = "") -> Host {
        Host(name: "Studio", address: address, username: "dev", serverKind: kind, sessionName: session)
    }

    private func machine(_ records: Host...) -> HostMachine {
        HostMachine.grouped(records)[0]
    }

    /// A look that found a tmux Server on each of `sockets`, and a core that is
    /// installed and runs or not where `coreRuns` says.
    private func scan(tmux sockets: [String] = [], coreRuns: Bool? = nil) async throws -> HostServerScan {
        let locator =
            switch coreRuns {
            case nil: ScriptedCoreHost.locatorLines(executable: nil)
            case false?: ScriptedCoreHost.locatorLines()
            case true?: ScriptedCoreHost.locatorLines(socketFile: true)
            }
        let host = ScriptedCoreHost(
            locator: locator,
            tmuxProbe: sockets.isEmpty
                ? ScriptedCoreHost.tmuxLines() : ScriptedCoreHost.tmuxLines(executable: Self.tmuxPath, sockets: sockets),
            channel: .refused)
        return HostServerScan(try await ServerKindDetection.run(over: host, session: ""))
    }

    // MARK: What a look found

    @Test func nothingIsKnownOfAHostBeforeItsFirstLook() {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())

        #expect(store.found(on: studio.id).isEmpty)
        #expect(store.lastLook(at: studio.id) == nil)
        #expect(store.unseen(on: studio).isEmpty)
        #expect(store.isDue(studio.id, at: Self.start))
    }

    @Test func aLookIsKeptWithWhenItWasMadeAndTheNextReplacesIt() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        let first = try await scan(tmux: ["default", "work"])
        let second = try await scan(tmux: ["default"], coreRuns: false)

        store.note(first, on: studio.id, at: Self.start)
        #expect(store.found(on: studio.id) == first.servers)
        #expect(store.lastLook(at: studio.id) == Self.start)

        store.note(second, on: studio.id, at: Self.start + 60)
        #expect(store.found(on: studio.id) == second.servers)
        #expect(store.lastLook(at: studio.id) == Self.start + 60)
    }

    // MARK: What the user has not seen

    /// A Server is news while it runs, is off, and was not shown. One that is
    /// installed and not running has not turned up yet.
    @Test func onlyARunningServerThatIsOffIsUnseen() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let tui = record()
        let tmux = record(kind: .tmux)
        store.note(try await scan(tmux: ["default", "work"], coreRuns: false), on: machine(tui).id)

        #expect(store.unseen(on: machine(tui)).map(\.key) == [Self.defaultTmux, Self.workTmux])
        // The Host's tmux is on: only the other socket is left to point out.
        #expect(store.unseen(on: machine(tui, tmux)).map(\.key) == [Self.workTmux])
    }

    @Test func aLookTheUserWatchedLeavesNothingUnseen() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())

        store.note(try await scan(tmux: ["default", "work"]), on: studio.id, shown: true)

        #expect(store.found(on: studio.id).count == 2)
        #expect(store.unseen(on: studio).isEmpty)
    }

    @Test func markingAHostShownClearsWhatWasFoundThere() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        let other = machine(record(address: "build.example"))
        let found = try await scan(tmux: ["default"])
        store.note(found, on: studio.id)
        store.note(found, on: other.id)

        store.markShown(on: studio.id)

        #expect(store.unseen(on: studio).isEmpty)
        #expect(store.unseen(on: other).map(\.key) == [Self.defaultTmux])
    }

    /// Only a Server seen running counts as shown: one that starts later is
    /// still news.
    @Test func aServerThatStartsRunningLaterIsUnseenAgain() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        store.note(try await scan(tmux: ["default"], coreRuns: false), on: studio.id, shown: true)
        #expect(store.unseen(on: studio).isEmpty)

        store.note(try await scan(tmux: ["default"], coreRuns: true), on: studio.id)

        #expect(store.unseen(on: studio).map(\.key) == [Self.core])
    }

    // MARK: When a background look is due

    @Test func aHostIsLookedAtAgainOnceTheIntervalHasPassed() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        store.note(try await scan(tmux: ["default"]), on: studio.id, at: Self.start)

        #expect(!store.isDue(studio.id, at: Self.start + 3599))
        #expect(store.isDue(studio.id, at: Self.start + 3600))
        #expect(store.isDue(studio.id, at: Self.start + 30, interval: 30))
    }

    /// A look that found nothing leaves no date behind, so the attempt itself
    /// holds the next one off.
    @Test func anAttemptHoldsOffTheNextForTheRetryInterval() {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        let other = machine(record(address: "build.example"))

        store.noteAttempt(at: studio.id, date: Self.start)

        #expect(!store.isDue(studio.id, at: Self.start + 599))
        #expect(store.isDue(studio.id, at: Self.start + 600))
        #expect(!store.isDue(studio.id, at: Self.start + 59, retryInterval: 60))
        #expect(store.isDue(studio.id, at: Self.start + 60, retryInterval: 60))
        #expect(store.isDue(other.id, at: Self.start))
    }

    // MARK: Hosts that left the catalog

    @Test func retainingForgetsEveryHostTheCatalogNoLongerHas() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        let gone = machine(record(address: "build.example"))
        let found = try await scan(tmux: ["default"])
        store.note(found, on: studio.id, at: Self.start)
        store.note(found, on: gone.id, at: Self.start)

        store.retain([studio.id])

        #expect(store.found(on: studio.id) == found.servers)
        #expect(store.found(on: gone.id).isEmpty)
        #expect(store.lastLook(at: gone.id) == nil)
        #expect(store.unseen(on: gone).isEmpty)
    }

    // MARK: Across launches

    @Test func whatWasFoundAndShownSurvivesARelaunch() async throws {
        let suiteName = "HostServerDiscoveryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let studio = machine(record())
        let other = machine(record(address: "build.example"))
        let found = try await scan(tmux: ["default", "work"], coreRuns: false)
        let store = HostServerDiscoveryStore(defaults: defaults)
        store.note(found, on: studio.id, shown: true, at: Self.start)
        store.note(found, on: other.id, at: Self.start + 60)
        store.noteAttempt(at: studio.id, date: Self.start + 7200)
        #expect(!store.isDue(studio.id, at: Self.start + 7201))

        let relaunched = HostServerDiscoveryStore(defaults: defaults)

        #expect(relaunched.found(on: studio.id) == found.servers)
        #expect(relaunched.lastLook(at: studio.id) == Self.start)
        #expect(relaunched.unseen(on: studio).isEmpty)
        #expect(relaunched.unseen(on: other).map(\.key) == [Self.defaultTmux, Self.workTmux])
        #expect(relaunched.lastLook(at: other.id) == Self.start + 60)
        // An attempt is not kept: a new launch may look again.
        #expect(relaunched.isDue(studio.id, at: Self.start + 7201))
    }

    @Test func aStoreWithNoDefaultsKeepsNothingBeyondItself() async throws {
        let store = HostServerDiscoveryStore(defaults: nil)
        let studio = machine(record())
        store.note(try await scan(tmux: ["default"]), on: studio.id)

        #expect(HostServerDiscoveryStore(defaults: nil).found(on: studio.id).isEmpty)
    }
}
