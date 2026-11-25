import SwiftUI

/// What the Console says of the connections to Hosts' Servers, as Host
/// detail reads it (ADR 0058).
struct HostConsoleLink {
    var statuses: [Host.ID: EventsSessionStatus] = [:]
    var standingFailures: [Host.ID: TransportError] = [:]
    /// The route each connected Server reached, by its own record's route.
    var routeIDs: [Host.ID: HostRoute.ID] = [:]
    var syncIssues: [Host.ID: String] = [:]
    /// Servers whose Reconnect press is still being served.
    var manualReconnects: Set<Host.ID> = []
    /// Dials every Server of a Host again; nil where Host detail stands
    /// outside the Console.
    var reconnect: (@MainActor @Sendable (HostMachine) async -> Void)?
    var stopConnecting: (@MainActor @Sendable (HostMachine) async -> Void)?
    /// Dials one Server again, leaving the Host's other Servers alone.
    var retry: (@MainActor @Sendable (Host.ID) async -> Void)?

    func lookFollowUp(of machine: HostMachine) -> HostLookFollowUp {
        HostLookFollowUp(servers: machine.servers.map { (id: $0.id, status: statuses[$0.id]) })
    }

    /// A look just reached the Host: the Servers waiting on its connection
    /// dial again at once, on whichever route wins.
    @MainActor
    func redialAfterLook(at machine: HostMachine) async {
        guard let retry else { return }
        let waiting = lookFollowUp(of: machine).redials
        await withTaskGroup(of: Void.self) { group in
            for record in waiting {
                group.addTask { await retry(record) }
            }
        }
    }

    func routes(of machine: HostMachine) -> HostRoutesPresentation {
        HostRoutesPresentation(
            hostName: machine.name,
            routeCount: machine.representative.routes.count,
            servers: machine.servers.map { record in
                HostRoutesPresentation.Server(
                    routes: record.routes, status: statuses[record.id], routeID: routeIDs[record.id],
                    standingFailure: standingFailures[record.id])
            },
            isManualReconnectInFlight: machine.servers.contains { manualReconnects.contains($0.id) })
    }

    func stateLine(of record: Host, found: FoundServer?) -> HostServerStateLine {
        HostServerStateLine(
            found: found, status: statuses[record.id], standingFailure: standingFailures[record.id],
            syncIssue: syncIssues[record.id], usesHerdrEndpoint: record.herdrEndpoint != nil)
    }
}

/// Host detail's Routes (ADR 0058): every route of the Host, with the one
/// its connections hold marked, or each route's own failure when a dial
/// reached none. Its header carries the Host's one Reconnect, which is Stop
/// while a Server dials. Routes are added and edited in Edit.
struct HostRoutesSection: View {
    let routes: [HostRoute]
    let presentation: HostRoutesPresentation
    let reconnect: (@MainActor () -> Void)?
    let stopConnecting: (@MainActor () -> Void)?

    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    var body: some View {
        Section {
            ForEach(Array(routes.enumerated()), id: \.element.id) { @Sendable item in
                MainActorContent { row(item.offset, item.element) }
            }
        } header: {
            header
        } footer: {
            footer
        }
    }

    private func row(_ index: Int, _ route: HostRoute) -> some View {
        let failure = presentation.failures[index]
        return HostRouteLabel(kind: HostRouteKind(route)) {
            Text(route.endpointDescription.wrappingAtAddressSeparators)
                .font(.body.monospaced())
                .accessibilityLabel(route.endpointDescription)
        } subtitle: {
            if let failure {
                // Over the label's secondary: the reason is why it is red.
                Text(failure).foregroundStyle(Color.errorInk)
            } else {
                Text(description(route))
            }
        } trailing: {
            if index == presentation.inUse {
                HostRouteTag(text: String(localized: "In Use"), tint: .green)
            } else if failure != nil {
                HostRouteTag(text: String(localized: "Failed"), tint: .red)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Routes")
            if presentation.isDialing {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            Spacer()
            Group {
                if presentation.isDialing, let stopConnecting {
                    Button("Stop", role: .cancel, action: stopConnecting)
                        .accessibilityLabel("Stop Connecting")
                        .accessibilityHint(
                            String(
                                localized:
                                    "Stops trying to connect without waiting for a timeout. The Host stays paused until you reconnect."))
                        .accessibilityIdentifier("hosts.host.stopConnecting")
                } else if presentation.offersReconnect, !presentation.isDialing, let reconnect {
                    Button("Reconnect", action: reconnect)
                        .accessibilityIdentifier("hosts.host.reconnect")
                }
            }
            .font(.subheadline)
            .textCase(nil)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch presentation.footer {
        case .none:
            EmptyView()
        case .note(let text):
            Text(text)
        case .problem(let text):
            Text(text)
                .foregroundStyle(.errorInk)
        }
    }

    /// How a route reaches the Host, under its address: `Direct`, its
    /// Overlay Network, or `via` its Jump Host.
    private func description(_ route: HostRoute) -> String {
        var parts: [String] = []
        if let networkID = route.overlayNetworkID {
            parts.append(
                overlayNetworks?.network(id: networkID)?.displayName
                    ?? String(localized: "Unavailable overlay network"))
        }
        if route.usesJumpHost {
            let jump = route.jumpAddress.trimmingCharacters(in: .whitespaces)
            let jumpEndpoint = route.jumpPort == 22 ? jump : "\(jump):\(route.jumpPort)"
            parts.append(String(localized: "via \(jumpEndpoint)"))
        }
        return parts.isEmpty ? String(localized: "Direct") : parts.joined(separator: " · ")
    }
}
