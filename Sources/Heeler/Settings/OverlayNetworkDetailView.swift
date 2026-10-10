import HeelerOverlay
import SwiftUI
import UIKit

/// One network: a status card with the switch (or the step in progress,
/// or Sign In) and what others need of this device (its address, or the
/// ZeroTier node ID or EasyTier machine ID to authorize), then the
/// network's machines. Edit, Copy Node ID, Sign Out, and Delete are in the
/// … menu.
struct OverlayNetworkDetailView: View {
    let store: OverlayNetworkStore
    let networkID: OverlayNetwork.ID
    let onHostAdded: (Host.ID) -> Void
    /// Set for a network just added or signed in from the list: a Tailscale
    /// network starts its sign-in (or Connect, with an auth key) when the
    /// screen opens, any other network its Connect.
    var startsOnAppear = false
    @State private var didStartOnAppear = false
    @State private var isEditing = false
    @State private var isEnteringAuthKey = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingMachineIDReset = false
    @State private var deleteFailed = false
    @State private var authKeyError: String?
    @State private var hostRequest: HostFormRequest?
    @State private var pendingOnboardingHostID: Host.ID?
    /// The Sign In in progress: owned here rather than by `.task(id:)`,
    /// which a navigation push can start twice for one request.
    @State private var signInTask: Task<Void, Never>?
    @State private var signInToken: UUID?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Injected app-wide by `ContentView`; absent in previews, where
    /// machines offer no Add Host….
    @Environment(HostStore.self) private var hostStore: HostStore?

    private static let adminConsoleURL = URL(string: "https://login.tailscale.com/admin/machines")

    var body: some View {
        Group {
            if let network = store.network(id: networkID) {
                content(network)
            } else {
                ContentUnavailableView("Network Removed", systemImage: "network.slash")
            }
        }
        .task {
            if store.network(id: networkID)?.kind == .zerotier {
                await store.prepareZeroTierIdentity()
            }
        }
        .task {
            // Once: coming back from Diagnostics runs this task again.
            guard startsOnAppear, !didStartOnAppear else { return }
            didStartOnAppear = true
            guard let network = store.network(id: networkID) else { return }
            switch store.primaryAction(for: network) {
            case .signIn: startSignIn()
            // Not this task's: pushing Diagnostics would cancel it.
            case .connect: Task { await store.connect(networkID) }
            case .connecting, .disconnect: break
            }
        }
        .task {
            // Sign-in, approval, and address assignment complete on their
            // own; follow them while this screen is visible.
            while !Task.isCancelled {
                await store.refreshStatus(networkID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Leaving the screen abandons a sign-in it started.
        .onDisappear { cancelSignIn() }
        .sheet(item: $hostRequest, onDismiss: {
            // As in Hosts, wait for the form to close before onboarding can
            // present its first-connection trust alert (#359, #426).
            guard let id = pendingOnboardingHostID else { return }
            pendingOnboardingHostID = nil
            onHostAdded(id)
        }) { request in
            if let hostStore {
                switch request {
                case .add(let request):
                    HostFormView(store: hostStore, prefill: request.draft, focusesUsername: true) {
                        saved in
                        pendingOnboardingHostID = saved.id
                    }
                case .edit(let host):
                    HostFormView(store: hostStore, editing: host)
                }
            }
        }
    }

    private func content(_ network: OverlayNetwork) -> some View {
        let status = store.statuses[networkID] ?? .stopped
        let details = store.details[networkID] ?? OverlayNodeDetails()
        let isStartingSignIn = signInTask != nil
        let headline = OverlayNetworkHeadline(
            network: network, store: store, isStartingSignIn: isStartingSignIn)
        let control = store.control(for: network)
        let isSigningOut = control == .signingOut
        // Before the node is online its peer list says nothing useful.
        let peers = status.isOnline ? details.peers : nil
        let searchesMachines = OverlayPeerList.offersPeers(network.kind) && !(peers ?? []).isEmpty
        let isSearching = searchesMachines && !query.trimmingCharacters(in: .whitespaces).isEmpty
        return List {
            if isSearching {
                searchResults(peers ?? [], kind: network.kind)
            } else {
                statusSection(
                    network, headline: headline, control: control, status: status, details: details,
                    isStartingSignIn: isStartingSignIn)

                if let peers {
                    peersSections(network, peers: peers, assigned: details.assignedNetworks)
                        .disabled(isSigningOut)
                }

                if network.kind == .zerotier {
                    Section {
                        NavigationLink {
                            OverlayDiagnosticsView(store: store, networkID: networkID)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Diagnostics")
                                    Text("Roots, routes, paths, events")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "stethoscope")
                            }
                        }
                    }
                }
            }
        }
        // The status card sits right under the bar, not a header's height
        // below it.
        .contentMargins(.top, 8, for: .scrollContent)
        .modifier(
            MachineSearch(
                isEnabled: searchesMachines, query: $query,
                prompt: network.kind == .tailscale ? "Machines" : "Peers"))
        .onChange(of: searchesMachines) { _, searches in
            if !searches { query = "" }
        }
        .navigationTitle(network.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                moreMenu(
                    network, nodeID: network.kind == .zerotier ? nil : details.nodeID,
                    control: control, isStartingSignIn: isStartingSignIn)
            }
        }
        .sheet(isPresented: $isEditing) {
            OverlayNetworkFormView(store: store, editing: network)
        }
        .sheet(isPresented: $isEnteringAuthKey) {
            TailscaleAuthKeySheet { signIn(withAuthKey: $0) }
        }
        .confirmationDialog(
            "Delete \(network.displayName)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Network", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(OverlayNetworkCopy.deleteMessage)
        }
        .confirmationDialog(
            "Sign out of \(network.displayName)?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await store.signOut(networkID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This device is logged out of the tailnet and its login is deleted. Hosts "
                    + "using this network disconnect and stay disconnected until you tap Sign In "
                    + "here, which signs in automatically if an auth key is saved.")
        }
        .confirmationDialog(
            "Reset the machine ID?",
            isPresented: $isConfirmingMachineIDReset,
            titleVisibility: .visible
        ) {
            Button("Reset Machine ID", role: .destructive) {
                try? store.resetMachineID(networkID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The EasyTier console then lists this device as a new one, which needs a "
                    + "network assigned again. Hosts on this network reconnect afterwards.")
        }
        .alert("Could not delete the network", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        }
        .alert(
            "Could not save the auth key",
            isPresented: Binding(
                get: { authKeyError != nil },
                set: { if !$0 { authKeyError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authKeyError ?? "")
        }
    }

    // MARK: Status

    /// The status card: what the network is doing, its switch or the step
    /// in progress, the sign-in or approval it waits on, and this device's
    /// address once it has one.
    private func statusSection(
        _ network: OverlayNetwork, headline: OverlayNetworkHeadline, control: OverlayNetworkControl,
        status: OverlayNodeStatus, details: OverlayNodeDetails, isStartingSignIn: Bool
    ) -> some View {
        let offersSignIn = isStartingSignIn || control == .signIn
        let waitReason = OverlayWaitReason(
            network: network, status: status, failure: store.connectFailures[networkID])
        return Section {
            VStack(alignment: .leading, spacing: 14) {
                OverlayStatusHeader(headline: headline) {
                    // While the browser sign-in is being prepared, the
                    // card's own button shows it.
                    if !isStartingSignIn {
                        OverlayNetworkControlView(
                            network: network, store: store,
                            onCancel: {
                                store.cancelConnect(networkID)
                                cancelSignIn()
                            })
                    }
                }
                if offersSignIn {
                    signInButtons(isStartingSignIn: isStartingSignIn)
                } else if headline.isAwaitingApproval, network.tailscaleControlURL == nil,
                    let url = Self.adminConsoleURL
                {
                    Link(destination: url) {
                        Label("Open Admin Console", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .fontWeight(.semibold)
                    .accessibilityHint("Opens the tailnet's machines in the browser to approve this device")
                } else if waitReason == .zeroTierAuthorization, let url = network.zeroTierCentralURL {
                    Link(destination: url) {
                        Label("Open ZeroTier Central", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .fontWeight(.semibold)
                    .accessibilityHint("Opens the network in the browser to authorize this device")
                }
            }
            .padding(.vertical, 4)
            .animation(.snappy, value: headline)
            deviceRow(network, status: status, details: details, waitReason: waitReason)
        } footer: {
            if let footer = statusFooter(
                network, headline: headline, control: control, status: status,
                waitReason: waitReason, offersSignIn: offersSignIn)
            {
                Text(footer)
            }
        }
    }

    /// Sign In with Browser, which shows its own progress while the login
    /// page is prepared, and the auth-key alternative (Cancel meanwhile).
    private func signInButtons(isStartingSignIn: Bool) -> some View {
        VStack(spacing: 12) {
            OverlayActivityButton(
                title: isStartingSignIn ? "Opening Browser…" : "Sign In with Browser",
                style: .filled, isLoading: isStartingSignIn, action: startSignIn)
            Button(isStartingSignIn ? "Cancel" : "Use an Auth Key Instead") {
                if isStartingSignIn {
                    store.cancelConnect(networkID)
                    cancelSignIn()
                } else {
                    isEnteringAuthKey = true
                }
            }
            // Its own tap target, not the row's.
            .buttonStyle(.borderless)
            .accessibilityLabel(isStartingSignIn ? "Cancel sign-in" : "Use an auth key instead")
        }
        .frame(maxWidth: .infinity)
    }

    /// The card's lower half: this device's addresses once it has them,
    /// and before that what an admin needs to let it in.
    @ViewBuilder
    private func deviceRow(
        _ network: OverlayNetwork, status: OverlayNodeStatus, details: OverlayNodeDetails,
        waitReason: OverlayWaitReason?
    ) -> some View {
        let addresses = status.isOnline ? details.addresses : []
        switch network.settings {
        case .zerotier:
            // One node ID for every ZeroTier network on this device.
            let nodeID = store.zeroTierNodeID ?? details.nodeID
            if !addresses.isEmpty {
                OverlayDeviceAddresses(
                    label: nodeID.map { "This device · \($0)" } ?? "This device", addresses: addresses)
            } else if let nodeID {
                OverlayDeviceIdentifier(label: "This device · Node ID", title: "node ID", value: nodeID)
            } else {
                LabeledContent("Node ID", value: "Created when you first connect")
            }
        case .easytierConfigServer(_, let machineID, _, _):
            let lines = OverlayAssignedAddressLine.lines(status.isOnline ? details.assignedNetworks : [])
            if !lines.isEmpty {
                OverlayAssignedAddresses(label: Self.deviceLabel(details), lines: lines)
            } else if !addresses.isEmpty {
                OverlayDeviceAddresses(label: Self.deviceLabel(details), addresses: addresses)
            } else if waitReason == .configServerAssignment {
                OverlayDeviceIdentifier(
                    label: "This device · Machine ID", title: "machine ID",
                    value: machineID.uuidString.lowercased(), isCompact: true)
            }
        case .tailscale, .easytier:
            if !addresses.isEmpty {
                OverlayDeviceAddresses(label: Self.deviceLabel(details), addresses: addresses)
            }
        }
    }

    private static func deviceLabel(_ details: OverlayNodeDetails) -> String {
        details.hostname.map { "This device · \($0)" } ?? "This device"
    }

    /// What the card's state means for Hosts, or what happens next.
    private func statusFooter(
        _ network: OverlayNetwork, headline: OverlayNetworkHeadline, control: OverlayNetworkControl,
        status: OverlayNodeStatus, waitReason: OverlayWaitReason?, offersSignIn: Bool
    ) -> String? {
        if let signOutFailure = store.signOutFailures[networkID] {
            return "Heeler signed this device out and forgot its login, but could not reach "
                + "the coordination server (\(signOutFailure.presentation.summary)). Remove "
                + "the device in the tailnet's admin console if it is still listed."
        }
        switch waitReason {
        case .zeroTierAuthorization:
            return "Heeler joins on its own once authorized. With your own controller, authorize "
                + "it there."
        case .configServerAssignment:
            return "Heeler starts each network as soon as it is assigned, up to 8."
        case .configServerConnection:
            return "Hosts on this network wait for it."
        case nil:
            break
        }
        if offersSignIn {
            return "\(network.deviceName ?? "This device") joins the tailnet as its own device. "
                + "Its address and the tailnet's machines appear here afterwards."
        }
        switch control {
        case .connecting:
            return "Hosts on this network wait for it."
        case .signingOut, .signIn:
            return nil
        case .toggle:
            break
        }
        if headline.isAwaitingApproval {
            guard let server = network.tailscaleControlURL?.host() else {
                return "Heeler joins on its own once approved."
            }
            return "Heeler joins on its own once the device is approved on \(server)."
        }
        if headline.tone == .failed {
            return "Turn the switch on to try again. If it keeps failing, check the internet "
                + "connection, or the network's settings in Edit."
        }
        if network.kind == .zerotier, !status.isOnline {
            return ZeroTierNodeIDCopy.authorizationHint
        }
        return nil
    }

    // MARK: Machines

    @ViewBuilder
    private func peersSections(
        _ network: OverlayNetwork, peers: [OverlayPeer], assigned: [OverlayAssignedNetwork]
    ) -> some View {
        switch network.kind {
        case .zerotier:
            zeroTierMembersSection(peers)
        case .tailscale:
            machinesSection(peers, network: network)
        case .easytier:
            if assigned.isEmpty {
                machinesSection(peers, network: network)
            } else {
                // A config server's networks, one section each.
                let groups = OverlayPeerList.assignedGroups(peers, assigned: assigned)
                ForEach(groups) { group in
                    assignedNetworkSection(group, isLast: group.id == groups.last?.id)
                }
            }
        }
    }

    private func machinesSection(_ peers: [OverlayPeer], network: OverlayNetwork) -> some View {
        Section {
            if peers.isEmpty {
                emptyMachines(network)
            } else {
                ForEach(OverlayPeerList.sorted(peers.map(OverlayPeerCandidate.init))) { candidate in
                    machineRow(candidate)
                }
            }
        } header: {
            if !peers.isEmpty {
                Text(network.kind == .tailscale ? "Machines" : "Peers")
            }
        } footer: {
            if !peers.isEmpty {
                addFooter(network.kind)
            }
        }
    }

    @ViewBuilder
    private func addFooter(_ kind: OverlayKind) -> some View {
        if hostStore != nil {
            Text(
                "Tap a \(kind == .tailscale ? "machine" : "peer") to add it as a Host. Touch "
                    + "and hold to copy its address.")
        }
    }

    @ViewBuilder
    private func emptyMachines(_ network: OverlayNetwork) -> some View {
        switch network.settings {
        case .tailscale:
            ContentUnavailableView {
                Label("Only This Device So Far", systemImage: OverlayKind.glyphSymbol)
            } description: {
                Text(
                    "Install Tailscale on your Mac and sign in with the same account. It appears "
                        + "here, ready to add as a Host.")
            }
        case .easytier(let networkName, _, _, _):
            ContentUnavailableView {
                Label("No Peers Yet", systemImage: OverlayKind.glyphSymbol)
            } description: {
                Text(
                    "Run EasyTier on your Mac with network name \(networkName) and the same "
                        + "secret. It appears here, ready to add as a Host.")
            }
        case .zerotier, .easytierConfigServer:
            Text("No peers yet")
                .foregroundStyle(.secondary)
        }
    }

    /// One network a config server assigned: its peers, or why it does
    /// not run.
    private func assignedNetworkSection(_ group: OverlayAssignedPeerGroup, isLast: Bool) -> some View {
        Section {
            if let error = group.error {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not running")
                        Text(error.hasSuffix(".") ? error : error + ".")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                .accessibilityElement(children: .combine)
            } else if !group.isRunning {
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            } else if group.peers.isEmpty {
                Text("No peers yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(OverlayPeerList.sorted(group.peers.map(OverlayPeerCandidate.init))) {
                    candidate in
                    machineRow(candidate)
                }
            }
        } header: {
            Text(group.header)
        } footer: {
            if isLast {
                addFooter(.easytier)
            }
        }
    }

    private func searchResults(_ peers: [OverlayPeer], kind: OverlayKind) -> some View {
        let matches = OverlayPeerList.sorted(
            OverlayPeerList.filter(peers.map(OverlayPeerCandidate.init), query: query))
        return Section {
            if matches.isEmpty {
                Text(kind == .tailscale ? "No matching machines" : "No matching peers")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { candidate in
                    machineRow(candidate)
                }
            }
        } footer: {
            Text("Matches names and addresses.")
        }
    }

    private func machineRow(_ candidate: OverlayPeerCandidate) -> some View {
        let host = hostStore.flatMap {
            OverlayPeerList.host(for: candidate, networkID: networkID, among: $0.hosts)
        }
        let canAdd = hostStore != nil && !candidate.addresses.isEmpty
        return OverlayMachineRow(
            candidate: candidate, isHost: host != nil,
            onAdd: canAdd
                ? {
                    hostRequest = .add(
                        OverlayPeerHostRequest(
                            draft: HostDraft(overlayPeer: candidate, networkID: networkID)))
                } : nil,
            onEditHost: host.map { host in { hostRequest = .edit(host) } })
    }

    /// ZeroTier reports the node's peers across every network it joined,
    /// with physical paths (public IP/port) rather than overlay addresses,
    /// so a member cannot be added as a Host. Roots (planet and moons) are
    /// in Diagnostics.
    private func zeroTierMembersSection(_ peers: [OverlayPeer]) -> some View {
        let members = OverlayPeerList.sorted(
            peers.filter { !OverlayStatusCopy.isZeroTierRoot($0) }.map(OverlayPeerCandidate.init))
        return Section {
            if members.isEmpty {
                ContentUnavailableView {
                    Label("No Members Yet", systemImage: OverlayKind.glyphSymbol)
                } description: {
                    Text(
                        "A member appears after this device first reaches it. Your Mac's managed "
                            + "IP is in ZeroTier Central or your controller.")
                }
            } else {
                ForEach(members) { member in
                    ZeroTierMemberRow(peer: member.peer)
                }
            }
        } header: {
            if !members.isEmpty {
                Text("Members")
            }
        } footer: {
            if !members.isEmpty {
                Text(
                    "Nodes this device has reached on any of its ZeroTier networks. ZeroTier "
                        + "doesn't share their managed IPs: for a Host, copy your Mac's IP from "
                        + "ZeroTier Central or your controller.")
            }
        }
    }

    // MARK: Menu

    /// Everything but the switch: Edit, what support may ask for, and the
    /// destructive actions, which confirm first.
    private func moreMenu(
        _ network: OverlayNetwork, nodeID: String?, control: OverlayNetworkControl,
        isStartingSignIn: Bool
    ) -> some View {
        // Sign Out only once there may be a login to forget.
        let offersSignOut = network.kind == .tailscale && !store.needsSignIn(network)
        return Menu {
            Button {
                isEditing = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if let nodeID {
                Button {
                    UIPasteboard.general.string = nodeID
                    AccessibilityNotification.Announcement("Copied").post()
                } label: {
                    Label("Copy Node ID", systemImage: "doc.on.doc")
                }
            }
            Divider()
            if case .easytierConfigServer = network.settings {
                Button(role: .destructive) {
                    isConfirmingMachineIDReset = true
                } label: {
                    Label("Reset Machine ID", systemImage: "arrow.counterclockwise")
                }
            }
            if offersSignOut {
                Button(role: .destructive) {
                    isConfirmingSignOut = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(control == .connecting || isStartingSignIn)
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Network", systemImage: "trash")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        // Nothing to change while the device leaves the tailnet.
        .disabled(control == .signingOut)
    }

    // MARK: Actions

    /// Starts the node and opens its login page once it has one. A newer
    /// Sign In or Cancel supersedes this one, which then opens nothing.
    private func startSignIn() {
        signInTask?.cancel()
        let token = UUID()
        signInToken = token
        signInTask = Task {
            let url = await store.signIn(networkID)
            guard !Task.isCancelled, signInToken == token else { return }
            signInTask = nil
            signInToken = nil
            if let url { openURL(url) }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInToken = nil
    }

    /// Saves the auth key like Edit would, then signs in with it: no
    /// browser unless the key is refused.
    private func signIn(withAuthKey key: String) {
        guard let network = store.network(id: networkID) else { return }
        do {
            try store.update(network, secret: key)
        } catch {
            authKeyError = (error as? OverlayNetworkStoreError)?.message
                ?? "The auth key could not be saved in the Keychain."
            return
        }
        startSignIn()
    }

    private func delete() {
        do {
            try store.remove(networkID)
            dismiss()
        } catch {
            deleteFailed = true
        }
    }
}

/// The Host form a machine opens: a new Host prefilled with it, or the
/// Host that already reaches it.
private enum HostFormRequest: Identifiable {
    case add(OverlayPeerHostRequest)
    case edit(Host)

    var id: UUID {
        switch self {
        case .add(let request): request.id
        case .edit(let host): host.id
        }
    }
}

/// Machine search, offered once there are machines to search.
private struct MachineSearch: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String
    let prompt: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: prompt)
        } else {
            content
        }
    }
}

/// The top of the status card: a tinted badge for the state, the title and
/// line under it, and the network's switch (or the step in progress) at the
/// trailing edge, below them at accessibility text sizes.
private struct OverlayStatusHeader<Trailing: View>: View {
    let headline: OverlayNetworkHeadline
    @ViewBuilder let trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var badgeSize = 36.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                Image(systemName: headline.symbol)
                    .font(.system(size: badgeSize * 0.42, weight: .semibold))
                    .foregroundStyle(headline.tone.color)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: badgeSize, height: badgeSize)
                    .background(headline.tone.color.opacity(0.15), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline.title)
                        .font(.body.weight(.semibold))
                        .contentTransition(.opacity)
                    if let subtitle = headline.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Status: \(headline.title)" + (headline.subtitle.map { ", \($0)" } ?? ""))
            }
            trailing
        }
    }
}

/// This device's addresses on the network: the one to share in large type
/// with a copy button, the rest under it. Touch and hold copies any. An
/// IPv6 address, too long for large type, is set smaller.
private struct OverlayDeviceAddresses: View {
    let label: String
    let addresses: [String]

    init(label: String, addresses: [String]) {
        self.label = label
        self.addresses = addresses.map { $0.lowercased() }
    }

    var body: some View {
        let primary = addresses.first { !$0.contains(":") } ?? addresses.first ?? ""
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(primary)
                    .font(
                        primary.contains(":")
                            ? .callout.monospaced().weight(.medium)
                            : .title2.monospaced().weight(.semibold)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OverlayCardCopyButton(value: primary, accessibilityLabel: "Copy \(primary)")
            }
            ForEach(addresses.filter { $0 != primary }, id: \.self) { address in
                Text(address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            ForEach(addresses, id: \.self) { address in
                OverlayCopyAddressButton(address: address, among: addresses) {
                    OverlayCardCopyButton.copy(address)
                }
            }
        }
    }
}

/// What an admin needs to let this device in (the ZeroTier node ID, the
/// EasyTier machine ID), in the card with a copy button.
private struct OverlayDeviceIdentifier: View {
    let label: String
    /// Spoken in "Copy node ID".
    let title: String
    let value: String
    /// Smaller type for a long value (a machine ID), still on one line.
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(value)
                    .font(
                        isCompact
                            ? .footnote.monospaced().weight(.medium)
                            : .title2.monospaced().weight(.semibold)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OverlayCardCopyButton(value: value, accessibilityLabel: "Copy \(title)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// This device's address on each network a config server assigned, by
/// network name, each with its own copy button.
private struct OverlayAssignedAddresses: View {
    let label: String
    let lines: [OverlayAssignedAddressLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(lines) { line in
                    GridRow {
                        Text(line.network)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(line.address)
                            .font(.body.monospaced().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        OverlayCardCopyButton(
                            value: line.address, size: 30,
                            accessibilityLabel: "Copy the address on \(line.network)")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A running assigned network's name and this device's bare address on it.
struct OverlayAssignedAddressLine: Identifiable, Equatable {
    let id: String
    let network: String
    let address: String

    /// The running networks with an address, in the server's order.
    static func lines(_ networks: [OverlayAssignedNetwork]) -> [OverlayAssignedAddressLine] {
        networks.compactMap { network in
            guard network.isRunning, network.error == nil, let address = network.address,
                let bare = OverlayPeerCandidate.orderedAddresses([address]).first
            else { return nil }
            return OverlayAssignedAddressLine(
                id: network.id, network: OverlayStatusCopy.assignedNetworkName(network), address: bare)
        }
    }
}

/// The card's round copy button, with a checkmark for a moment after.
private struct OverlayCardCopyButton: View {
    let value: String
    var size = 36.0
    let accessibilityLabel: String
    @State private var copied = false

    var body: some View {
        Button {
            Self.copy(value)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font((size < 36 ? Font.footnote : .body).weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Color.accentColor.opacity(0.12), in: .circle)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    static func copy(_ value: String) {
        UIPasteboard.general.string = value
        AccessibilityNotification.Announcement("Copied").post()
    }
}

/// "Copy IPv4" with the address under it, in a context menu.
private struct OverlayCopyAddressButton: View {
    let address: String
    let among: [String]
    let action: () -> Void

    var body: some View {
        // Text, Text, Image: a menu shows the second Text as a subtitle,
        // which it drops from a Label's title.
        Button(action: action) {
            Text("Copy \(OverlayStatusCopy.addressTitle(address, among: among))")
            Text(address)
            Image(systemName: "doc.on.doc")
        }
    }
}

/// A machine on the network: online dot, name, the address a Host would
/// use and how it is reached, and Add (or a Host tag once a Host reaches
/// it). Touch and hold copies its addresses.
private struct OverlayMachineRow: View {
    let candidate: OverlayPeerCandidate
    let isHost: Bool
    /// nil where it cannot be a Host (no address, or no Host store).
    let onAdd: (() -> Void)?
    let onEditHost: (() -> Void)?

    var body: some View {
        let primaryAction = onEditHost ?? onAdd
        HStack(spacing: 10) {
            Button {
                primaryAction?()
            } label: {
                details
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(primaryAction == nil)
            .accessibilityHint(
                isHost ? "Edits the Host on this machine" : onAdd == nil ? "" : "Adds it as a Host")
            if isHost {
                Text("Host")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
                    .accessibilityHidden(true)
            } else if let onAdd {
                Button("Add", action: onAdd)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fontWeight(.semibold)
                    .accessibilityLabel("Add \(candidate.displayName) as a Host")
            }
        }
        .contextMenu {
            if let onEditHost {
                Button(action: onEditHost) {
                    Label("Edit Host…", systemImage: "pencil")
                }
            } else if let onAdd {
                Button(action: onAdd) {
                    Label("Add Host…", systemImage: "plus")
                }
            }
            if !candidate.addresses.isEmpty {
                Divider()
            }
            ForEach(candidate.addresses, id: \.self) { address in
                OverlayCopyAddressButton(address: address, among: candidate.addresses) {
                    UIPasteboard.general.string = address
                }
            }
        }
    }

    private var details: some View {
        let reachability = OverlayStatusCopy.peerReachability(candidate.peer)
        let address = candidate.ipv4 ?? candidate.addresses.first
        return HStack(spacing: 10) {
            if let isOnline = candidate.isOnline {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isOnline ? .green : .secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName)
                    .foregroundStyle(candidate.isOffline ? .secondary : .primary)
                Group {
                    switch (address, reachability.isEmpty) {
                    case (let address?, false):
                        Text("\(Text(address).monospaced()) · \(reachability)")
                    case (let address?, true):
                        Text(address).monospaced()
                    case (nil, _):
                        Text(reachability)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isHost ? "Host" : "")
    }
}

/// A ZeroTier member: its node ID and how it is reached. Its paths are
/// where traffic goes, not addresses for a Host, so it offers no Add;
/// touch and hold copies the node ID or a path, for troubleshooting.
private struct ZeroTierMemberRow: View {
    let peer: OverlayPeer

    var body: some View {
        let reachability = OverlayStatusCopy.peerReachability(peer)
        HStack(spacing: 10) {
            if let isOnline = peer.isOnline {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isOnline ? .green : .secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let name = peer.name, !name.isEmpty {
                        Text(name)
                    } else {
                        Text(peer.id).monospaced()
                    }
                }
                .foregroundStyle(peer.isOnline == false ? .secondary : .primary)
                if !reachability.isEmpty {
                    Text(reachability)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            copyButton("Copy Node ID", value: peer.id)
            ForEach(OverlayStatusCopy.uniquePaths(peer), id: \.self) { path in
                copyButton("Copy Path", value: path)
            }
        }
    }

    private func copyButton(_ title: String, value: String) -> some View {
        // Text, Text, Image: the menu shows the value as a subtitle.
        Button {
            UIPasteboard.general.string = value
        } label: {
            Text(title)
            Text(value)
            Image(systemName: "doc.on.doc")
        }
    }
}

/// A ZeroTier root in Diagnostics: the planet or moon server, and the
/// paths traffic to it takes.
private struct ZeroTierPeerRow: View {
    let peer: OverlayPeer

    var body: some View {
        let summary = OverlayStatusCopy.peerSummary(peer)
        let paths = OverlayStatusCopy.uniquePaths(peer)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let isOnline = peer.isOnline {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(isOnline ? .green : .secondary)
                        .accessibilityHidden(true)
                }
                Text(peer.name ?? peer.id)
            }
            if !paths.isEmpty {
                Text("Path: " + paths.joined(separator: ", "))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Use an Auth Key Instead": one field, then Sign In with it.
private struct TailscaleAuthKeySheet: View {
    let onSignIn: (String) -> Void
    @State private var key = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // No password content type: an auth key is not an
                    // account password and must not be offered to AutoFill.
                    SecureField("Auth key", text: $key, prompt: Text("tskey-auth-…"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } footer: {
                    Text(
                        "Create one in the tailnet's admin console under Settings › Keys. Heeler "
                            + "keeps it in the Keychain and signs in with it again after a sign-out.")
                }
            }
            .navigationTitle("Auth Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In", action: signIn)
                        .disabled(trimmedKey.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { isFocused = true }
    }

    private func signIn() {
        guard !trimmedKey.isEmpty else { return }
        onSignIn(trimmedKey)
        dismiss()
    }
}

/// Settings › Overlay Networks › a network › Diagnostics: the node's raw
/// state, read-only, with Copy All for a bug report. Never starts the node.
struct OverlayDiagnosticsView: View {
    let store: OverlayNetworkStore
    let networkID: OverlayNetwork.ID
    @State private var diagnostics = OverlayDiagnostics()
    @State private var copied = false

    var body: some View {
        let roots = (store.details[networkID]?.peers ?? []).filter(OverlayStatusCopy.isZeroTierRoot)
        List {
            if diagnostics.isEmpty {
                ContentUnavailableView(
                    "No Diagnostics", systemImage: "stethoscope",
                    description: Text("Connect the network to see its state."))
            } else {
                if !roots.isEmpty {
                    Section {
                        ForEach(roots) { peer in
                            ZeroTierPeerRow(peer: peer)
                        }
                    } header: {
                        Text("Roots")
                    } footer: {
                        Text(
                            "The planet and moon servers this device uses to find members and "
                                + "relay traffic. On a self-hosted planet the root is often the "
                                + "network controller as well.")
                    }
                }
                Section("State") {
                    ForEach(Array(diagnostics.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    if diagnostics.events.isEmpty {
                        Text("No events yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(diagnostics.events.reversed().enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(event.message)
                                .font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Recent Events")
                } footer: {
                    Text("Newest first; the last 50 of this app session.")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = diagnostics.text
                    copied = true
                    AccessibilityNotification.Announcement("Copied").post()
                } label: {
                    Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(diagnostics.isEmpty)
            }
        }
        .task {
            while !Task.isCancelled {
                // The network's screen stops refreshing while this one is
                // pushed over it; the roots come from its details.
                await store.refreshStatus(networkID)
                diagnostics = await store.diagnostics(networkID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
