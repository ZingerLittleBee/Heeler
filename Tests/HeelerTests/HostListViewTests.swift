import Foundation
import Testing

@testable import Heeler

@Suite("Host list connection presentation")
struct HostListViewTests {
    @Test func connectedHostShowsRoundedLatency() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            latency: .milliseconds(25) + .microseconds(600))

        #expect(presentation.title == "26 ms")
        #expect(presentation.accessibilityLabel == "Connected, latency 26 ms")
        #expect(presentation.tone == .connected)
    }

    @Test func subMillisecondLatencyStaysMeaningful() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            latency: .microseconds(400))

        #expect(presentation.title == "<1 ms")
    }

    @Test func disconnectedStatesNeverShowStaleLatency() {
        let latency = Duration.milliseconds(42)

        #expect(
            HostConnectionPresentation(
                status: .reconnecting(
                    attempt: 1,
                    delay: .seconds(1),
                    failure: .timedOut),
                latency: latency
            ).title == "Reconnecting…")
        #expect(
            HostConnectionPresentation(
                status: .failed(.authenticationFailed),
                latency: latency
            ).title == "Unavailable")
        #expect(
            HostConnectionPresentation(
                status: .suspended,
                latency: latency
            ).title == "Paused")
        #expect(
            HostConnectionPresentation(
                status: .connecting,
                latency: latency
            ).title == "Connecting…")
        #expect(
            HostConnectionPresentation(
                status: .connecting,
                standingFailure: .streamLocalOpenFailed(path: "/s"),
                latency: latency
            ).title == "Unavailable")
    }

    @Test func pausedAndReconnectingHostsHaveTheirOwnTones() {
        #expect(HostConnectionPresentation(status: .suspended, latency: nil).tone == .paused)
        #expect(
            HostConnectionPresentation(
                status: .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                latency: nil
            ).tone == .reconnecting)
    }

    /// Headers show the icon alone, so no two states may share a shape and
    /// differ only by color.
    @Test func nilStatusIsTheConstructionWindowAndSaysConnecting() {
        let presentation = HostConnectionPresentation(status: nil, latency: nil)
        #expect(presentation.title == "Connecting…")
        #expect(presentation.accessibilityLabel == "Connecting")
        #expect(presentation.tone == .pending)
    }

    @Test func connectingWithoutAStandingFailureIsPending() {
        let presentation = HostConnectionPresentation(
            status: .connecting, latency: .milliseconds(12))
        #expect(presentation.title == "Connecting…")
        #expect(presentation.accessibilityLabel == "Connecting")
        #expect(presentation.tone == .pending)
    }

    @Test func connectingWithAStandingFailureStaysUnavailable() {
        let presentation = HostConnectionPresentation(
            status: .connecting,
            standingFailure: .authenticationFailed,
            latency: .milliseconds(12))
        #expect(presentation.title == "Unavailable")
        #expect(presentation.accessibilityLabel == "Unavailable")
        #expect(presentation.tone == .unavailable)
    }

    @Test func connectedPresentationIgnoresInventoryAndStaysLatencyBased() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            standingFailure: .streamLocalOpenFailed(path: "/s"),
            latency: .milliseconds(25))
        #expect(presentation.title == "25 ms")
        #expect(presentation.tone == .connected)
        #expect(presentation.accessibilityLabel == "Connected, latency 25 ms")
    }
}

@Suite("Host row presentation")
struct HostRowPresentationTests {
    private let host = Host.fixture(name: "studio")

    private func row(
        _ status: EventsSessionStatus?, standingFailure: TransportError? = nil,
        syncIssue: String? = nil, canRetry: Bool = true
    ) -> HostRowPresentation {
        HostRowPresentation(
            host: host, status: status, standingFailure: standingFailure,
            latency: .milliseconds(148), syncIssue: syncIssue, canRetry: canRetry)
    }

    /// Nothing dials a Host with no Server on, so its row says how it is
    /// reached rather than reading as connecting.
    @Test func aHostWithNoServerOnIsNotConnected() {
        let record = Host(address: "box.example", username: "dev", serverKind: .unconfirmed)
        let presentation = HostMachineRowPresentation(machine: HostMachine.grouped([record])[0])

        #expect(presentation.group == .notConnected)
        #expect(presentation.tone == .paused)
        #expect(presentation.detail == "dev@box.example")
        #expect(!presentation.isProblem)
        #expect(presentation.servers.isEmpty)
        #expect(presentation.retryIDs.isEmpty)
        #expect(presentation.trailing == nil)
    }

    /// One row for a Host with several Servers on: the one that stopped files
    /// the row and names its reason, and each keeps its own state on its chip.
    @Test func aHostReadsFromTheServerThatMostNeedsTheUser() {
        let tui = Host(name: "studio", address: "box.example", username: "dev", serverKind: .herdrTUI)
        let tmux = Host(
            name: "studio", address: "box.example", username: "dev", serverKind: .tmux, sessionName: "work")
        let machine = HostMachine.grouped([tui, tmux])[0]

        let mixed = HostMachineRowPresentation(
            machine: machine,
            statuses: [tui.id: .connected, tmux.id: .failed(.timedOut)],
            latencies: [tui.id: .milliseconds(148)])
        #expect(mixed.name == "studio")
        #expect(mixed.group == .cannotConnect)
        #expect(mixed.detail == TransportError.timedOut.presentation.summary)
        #expect(mixed.isProblem)
        #expect(mixed.trailing == nil)
        #expect(mixed.servers.map(\.label) == ["Herdr TUI", "Tmux · work"])
        #expect(mixed.servers.map(\.tone) == [.connected, .unavailable])
        #expect(mixed.retryIDs == [tmux.id])
        #expect(mixed.subtitle == mixed.detail)

        let healthy = HostMachineRowPresentation(
            machine: machine,
            statuses: [tui.id: .connected, tmux.id: .connected],
            latencies: [tui.id: .milliseconds(148), tmux.id: .milliseconds(12)])
        #expect(healthy.group == .connected)
        #expect(healthy.detail == "dev@box.example")
        #expect(healthy.subtitle == "dev@box.example")
        #expect(healthy.trailing == "12 ms")
        #expect(healthy.retryIDs.isEmpty)
    }

    /// A Host named by no record reads as how it is reached, without repeating
    /// that same `user@address` on a second subtitle line.
    @Test func aHostWithNoNameReadsAsItsAccountAndAddress() {
        let tui = Host(address: "box.example", username: "dev", serverKind: .herdrTUI)
        let tmux = Host(address: "box.example", username: "dev", serverKind: .tmux)
        let presentation = HostMachineRowPresentation(
            machine: HostMachine.grouped([tui, tmux])[0], statuses: [tui.id: .connected, tmux.id: .connected])

        #expect(presentation.name == "dev@box.example")
        #expect(presentation.detail == "dev@box.example")
        #expect(presentation.subtitle == nil)
        #expect(presentation.servers.map(\.label) == ["Herdr TUI", "Tmux"])
        #expect(presentation.servers.map(\.id) == [tui.id, tmux.id])
    }

    @Test func hostListBadgesFormatServerNamesCompactly() {
        #expect(HostServerKey(kind: .herdrTUI, name: "").badgeLabel == "Herdr TUI")
        #expect(HostServerKey(kind: .herdrTUI, name: "heeler-win-test").badgeLabel == "heeler-win-test")
        #expect(HostServerKey(kind: .herdrCore, name: "").badgeLabel == "Herdr Core")
        #expect(HostServerKey(kind: .herdrCore, name: "work").badgeLabel == "Herdr Core · work")
        #expect(HostServerKey(kind: .tmux, name: "").badgeLabel == "Tmux")
        #expect(HostServerKey(kind: .tmux, name: "work").badgeLabel == "Tmux · work")
    }

    /// Among connected Servers the one out of sync speaks for the row, and
    /// the latency is still the best one measured.
    @Test func aServerOutOfSyncLeadsOneThatIsHealthy() {
        let tui = Host(name: "studio", address: "box.example", username: "dev", serverKind: .herdrTUI)
        let tmux = Host(name: "studio", address: "box.example", username: "dev", serverKind: .tmux)
        let presentation = HostMachineRowPresentation(
            machine: HostMachine.grouped([tui, tmux])[0],
            statuses: [tui.id: .connected, tmux.id: .connected],
            latencies: [tui.id: .milliseconds(12), tmux.id: .milliseconds(148)],
            syncIssues: [tmux.id: "Could not sync this Host's Agents. Retrying…"])

        #expect(presentation.group == .connected)
        #expect(presentation.tone == .warning)
        #expect(presentation.detail == "Sync issue")
        #expect(!presentation.isProblem)
        #expect(presentation.trailing == "12 ms")
        #expect(presentation.servers.map(\.tone) == [.connected, .warning])
    }

    @Test func aHostWithAServerStillConnectingIsFiledAsTrying() {
        let tui = Host(name: "studio", address: "box.example", username: "dev", serverKind: .herdrTUI)
        let tmux = Host(name: "studio", address: "box.example", username: "dev", serverKind: .tmux)
        let presentation = HostMachineRowPresentation(
            machine: HostMachine.grouped([tui, tmux])[0],
            statuses: [tui.id: .connected, tmux.id: .connecting],
            latencies: [tui.id: .milliseconds(12)])

        #expect(presentation.group == .trying)
        #expect(presentation.tone == .pending)
        #expect(presentation.detail == "Connecting…")
        #expect(presentation.trailing == nil)
        #expect(presentation.servers.map(\.tone) == [.connected, .pending])
        #expect(presentation.retryIDs.isEmpty)
    }

    /// One Retry dials every Server that stopped, and none where the list
    /// cannot retry at all.
    @Test func retryDialsEveryServerThatStopped() {
        let tui = Host(name: "studio", address: "box.example", username: "dev", serverKind: .herdrTUI)
        let tmux = Host(name: "studio", address: "box.example", username: "dev", serverKind: .tmux)
        let core = Host(name: "studio", address: "box.example", username: "dev", serverKind: .herdrCore)
        let machine = HostMachine.grouped([tui, tmux, core])[0]
        let statuses: [Host.ID: EventsSessionStatus] = [
            tui.id: .failed(.timedOut), tmux.id: .connected, core.id: .failed(.authenticationFailed),
        ]

        let stopped = HostMachineRowPresentation(machine: machine, statuses: statuses)
        #expect(stopped.retryIDs == [tui.id, core.id])
        // The first Server that stopped names the reason.
        #expect(stopped.detail == TransportError.timedOut.presentation.summary)
        #expect(stopped.servers.map(\.offersRetry) == [true, false, true])

        let fixed = HostMachineRowPresentation(machine: machine, statuses: statuses, canRetry: false)
        #expect(fixed.retryIDs.isEmpty)
        #expect(fixed.group == .cannotConnect)
    }

    /// The user's own retry stays where it was while it dials.
    @Test func aServerTheUserIsRetryingReadsAsDialing() {
        let tui = Host(name: "studio", address: "box.example", username: "dev", serverKind: .herdrTUI)
        let presentation = HostMachineRowPresentation(
            machine: HostMachine.grouped([tui])[0],
            statuses: [tui.id: .connecting], standingFailures: [tui.id: .timedOut])

        #expect(presentation.group == .cannotConnect)
        #expect(presentation.servers.map(\.isDialing) == [true])
        #expect(presentation.retryIDs == [tui.id])
        #expect(!presentation.isProblem)
    }

    // MARK: The chips in words

    private func chip(_ label: String, _ tone: HostConnectionTone) -> HostMachineRowPresentation.Server {
        HostMachineRowPresentation.Server(
            id: UUID(), label: label, tone: tone, offersRetry: false, isDialing: false)
    }

    /// A Hosts list row is one VoiceOver stop: where only a colored mark shows
    /// a Server's state, a word does.
    @MainActor
    @Test func eachServerThatIsOnIsSpokenWithItsState() {
        let chips = HostServerChips(
            servers: [
                chip("Herdr TUI", .connected), chip("tmux · work", .unavailable), chip("herdr-core", .pending),
                chip("tmux", .paused), chip("tmux · logs", .reconnecting), chip("Herdr TUI · play", .warning),
            ],
            unseen: [])

        #expect(
            chips.spokenSummary
                == "Herdr TUI, connected; tmux · work, unavailable; herdr-core, connecting; tmux, paused; "
                + "tmux · logs, reconnecting; Herdr TUI · play, sync issue")
    }

    @MainActor
    @Test func aHostWithNoServerOnSaysSo() {
        #expect(HostServerChips(servers: [], unseen: []).spokenSummary == "No servers on")
    }

    /// The row points at news and Host detail lists it: two are named and the
    /// rest counted.
    @MainActor
    @Test func serversFoundSinceAreSpokenAfterTheOnesThatAreOn() {
        let on = [chip("Herdr TUI", .connected)]

        #expect(
            HostServerChips(servers: on, unseen: ["tmux", "herdr-core"]).spokenSummary
                == "Herdr TUI, connected; tmux, found, not on; herdr-core, found, not on")
        #expect(
            HostServerChips(servers: on, unseen: ["tmux", "herdr-core", "tmux · work", "tmux · logs"])
                .spokenSummary
                == "Herdr TUI, connected; tmux, found, not on; herdr-core, found, not on; 2 more found")
        #expect(
            HostServerChips(servers: [], unseen: ["tmux"]).spokenSummary
                == "No servers on; tmux, found, not on")
    }

    @Test func hostsGroupByWhatTheyNeedFromTheUser() {
        #expect(row(.failed(.timedOut)).group == .cannotConnect)
        #expect(row(.connecting, standingFailure: .timedOut).group == .cannotConnect)
        #expect(row(.reconnecting(attempt: 2, delay: .seconds(2), failure: .timedOut)).group == .trying)
        #expect(row(.connecting).group == .trying)
        #expect(row(nil).group == .trying)
        #expect(row(.connected).group == .connected)
        #expect(row(.suspended).group == .notConnected)
        #expect(HostHealthGroup.allCases.sorted() == [.cannotConnect, .trying, .connected, .notConnected])
    }

    @Test func aStoppedHostNamesItsProblemBesideRetry() {
        let stopped = row(.failed(.authenticationFailed))
        #expect(stopped.detail == TransportError.authenticationFailed.presentation.summary)
        #expect(stopped.isProblem)
        #expect(stopped.offersRetry)
        #expect(stopped.tone == .unavailable)
        #expect(!row(.failed(.timedOut), canRetry: false).offersRetry)
    }

    @Test func theUsersOwnRetryStaysInPlaceWhileItDials() {
        let dialing = row(.connecting, standingFailure: .timedOut)
        #expect(dialing.isDialing)
        #expect(dialing.offersRetry)
        #expect(!dialing.isProblem)
    }

    @Test func recoveryStatesItsAttemptWithoutRetry() {
        let recovering = row(.reconnecting(attempt: 4, delay: .seconds(8), failure: .timedOut))
        #expect(recovering.detail == "\(TransportError.timedOut.presentation.summary) · Attempt 4")
        #expect(!recovering.offersRetry)
        #expect(row(.connecting).detail == "Connecting…")
    }

    @Test func aConnectedHostShowsItsAddressAndLatency() {
        let connected = row(.connected)
        #expect(connected.detail == "\(host.username)@\(host.address)")
        #expect(connected.trailing == "148 ms")
        #expect(row(.failed(.timedOut)).trailing == nil)
    }

    /// An endpoint Host names its session from the endpoint's socket, the
    /// same value Host detail shows; its default session adds nothing.
    @Test func aConnectedEndpointHostNamesItsEndpointSession() throws {
        let support = "/Users/ada/Library/Application Support/Example"
        var named = host
        named.herdrEndpoint = try #require(
            HerdrEndpoint(
                socketPath: "\(support)/herdr/sessions/work/herdr.sock",
                executablePath: "\(support)/bin/herdr"))
        var defaultSession = host
        defaultSession.herdrEndpoint = try #require(
            HerdrEndpoint(
                socketPath: "\(support)/herdr/herdr.sock",
                executablePath: "\(support)/bin/herdr"))
        var sessionName = host
        sessionName.sessionName = "work"

        let address = "\(host.username)@\(host.address)"
        for (candidate, detail) in [
            (named, "\(address) · session work"),
            (defaultSession, address),
            (sessionName, "\(address) · session work"),
        ] {
            let presentation = HostRowPresentation(
                host: candidate, status: .connected, standingFailure: nil,
                latency: .milliseconds(148))
            #expect(presentation.detail == detail)
        }
    }

    /// The Console calls this Host "Sync issue" in orange; its row must not
    /// read as a healthy green Connected.
    @Test func aConnectedHostThatCannotSyncWearsTheConsolesSyncIssueLook() {
        let outOfSync = row(.connected, syncIssue: "Could not sync this Host's Agents. Retrying…")
        let console = ConsoleHostStatusPresentation(
            host: host, status: .connected,
            syncError: "Could not sync this Host's Agents. Retrying…")
        #expect(outOfSync.tone == .warning)
        #expect(outOfSync.tone == console?.tone)
        #expect(outOfSync.detail == "Sync issue")
        #expect(outOfSync.detail == console?.status)
        #expect(outOfSync.group == .connected)
        #expect(outOfSync.trailing == "148 ms")
        #expect(!outOfSync.isProblem)
        #expect(!outOfSync.offersRetry)
    }

    /// A lost connection outranks a stale sync error.
    @Test func aSyncIssueNeverMasksAConnectionProblem() {
        let issue = "Could not sync this Host's Agents. Retrying…"
        let stopped = row(.failed(.authenticationFailed), syncIssue: issue)
        #expect(stopped.tone == .unavailable)
        #expect(stopped.detail == TransportError.authenticationFailed.presentation.summary)
        let recovering = row(
            .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), syncIssue: issue)
        #expect(recovering.tone == .reconnecting)
        #expect(row(.suspended, syncIssue: issue).tone == .paused)
    }

    @Test func onlyNonEmptyGroupsShowInOrder() {
        let entries = [("a", EventsSessionStatus.connected), ("b", .failed(.timedOut)), ("c", .connected)].map {
            name, status in
            let record = Host.fixture(name: name, address: "\(name).example")
            let machine = HostMachine.grouped([record])[0]
            return HostListEntry(
                machine: machine,
                presentation: HostMachineRowPresentation(machine: machine, statuses: [record.id: status]))
        }
        let sections = HostListEntry.grouped(entries)
        #expect(sections.map(\.group) == [.cannotConnect, .connected])
        #expect(sections.last?.entries.map(\.presentation.name) == ["a", "c"])
    }

    @Test func collapsedGroupsSurviveARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "HostHealthGroupTests-\(UUID())"))
        #expect(HostHealthGroup.collapsed(in: defaults).isEmpty)
        HostHealthGroup.save([.connected, .cannotConnect], in: defaults)
        #expect(HostHealthGroup.collapsed(in: defaults) == [.connected, .cannotConnect])
    }
}
