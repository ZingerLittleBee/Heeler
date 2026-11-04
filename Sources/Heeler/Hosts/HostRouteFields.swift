import SwiftUI

/// The sections that edit one route (ADR 0022): its Overlay Network, the
/// Host's address and port, and an optional Jump Host. Each route has its own
/// page, opened from the Host form's Routes list.
struct HostRouteFields: View {
    @Binding var route: HostRouteDraft
    /// Steers the Jump Host footer's credential requirement.
    let authMethod: Host.AuthMethod
    /// Shows the peer picker, which the enclosing Form presents with
    /// `overlayPeerPicker(isPresented:route:otherHosts:onPeerChosen:)`.
    @Binding var isChoosingOverlayPeer: Bool

    /// Absent in previews and hosting tests; the Network picker then offers
    /// only Direct (plus the route's current choice).
    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    var body: some View {
        // The network decides which address to enter (and offers its peers
        // beside it), so it leads once there is one to choose.
        if networkLeads {
            networkSection
        }
        Section("Address") {
            TextField("Address", text: $route.address)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Port", text: $route.port)
                .keyboardType(.numberPad)
        }
        jumpSection
        if !networkLeads {
            networkSection
        }
    }

    /// Without Overlay Networks the Network section is only a pointer to
    /// Settings, so it stays at the end, out of a direct route's way.
    private var networkLeads: Bool {
        !(overlayNetworks?.networks.isEmpty ?? true) || route.overlayNetworkID != nil
    }

    /// The Overlay Network the route names, when it still exists.
    private var selectedOverlayNetwork: OverlayNetwork? {
        route.overlayNetworkID.flatMap { overlayNetworks?.network(id: $0) }
    }

    private var jumpSection: some View {
        Section {
            TextField("Jump Host address (optional)", text: $route.jumpAddress)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if route.usesJumpHost {
                TextField("Jump Host port", text: $route.jumpPort)
                    .keyboardType(.numberPad)
                TextField("Jump Host user (blank = same as Host)", text: $route.jumpUsername)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Jump Host")
        } footer: {
            if route.usesJumpHost {
                Text(jumpHostFooter)
            } else {
                Text("Leave blank to connect to the Host directly.")
            }
        }
    }

    private var jumpHostFooter: String {
        let credentialRequirement =
            switch authMethod {
            case .deviceKey:
                "Both machines must authorize the Device Key."
            case .rsaKey:
                "Both machines must authorize the RSA Key."
            case .password:
                "Both machines must accept the same password; separate passwords are not supported."
            }
        return "The Host's Address and Port are resolved from the Jump Host, usually through "
            + "a loopback-only reverse tunnel. \(credentialRequirement) You confirm each "
            + "machine's host key fingerprint independently on first connect."
    }

    /// Under the network: pick the first hop's address (the Host's, or the
    /// Jump Host's when one is set) from its peers instead of typing it.
    /// Once that address is a known peer's, as after Add on a machine in
    /// Settings, the row names the peer like a picker showing its choice.
    /// ZeroTier reports no member addresses; its footer says where they are.
    @ViewBuilder
    private var overlayPeerChooser: some View {
        if let network = selectedOverlayNetwork, OverlayPeerList.offersPeers(network.kind) {
            Button {
                isChoosingOverlayPeer = true
            } label: {
                if let chosen = chosenOverlayPeer(on: network) {
                    // Styled like the Network picker above, not as a tinted button.
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(chosen.displayName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    } label: {
                        // `.primary` would resolve to the button's tint.
                        Text(network.kind == .tailscale ? "Machine" : "Peer")
                            .foregroundStyle(Color.primary)
                    }
                } else {
                    Text(OverlayPeerList.chooseTitle(for: network.kind))
                }
            }
            .accessibilityHint("Lists the peers of \(network.displayName)")
        }
    }

    /// The peer the first hop already dials, from the network's last report.
    private func chosenOverlayPeer(on network: OverlayNetwork) -> OverlayPeerCandidate? {
        let peers = overlayNetworks?.details[network.id]?.peers ?? []
        return OverlayPeerList.chosen(
            among: OverlayPeerList.candidates(from: peers), address: route.overlayPeerAddress)
    }

    /// Direct, or one of Settings › Overlay Networks. A route still naming a
    /// removed network keeps that choice visible as unavailable instead of
    /// silently becoming Direct.
    private var networkSection: some View {
        let networks = overlayNetworks?.networks ?? []
        let selectionIsMissing =
            route.overlayNetworkID.map { id in !networks.contains { $0.id == id } } ?? false
        return Section {
            Picker("Network", selection: $route.overlayNetworkID) {
                Text("Direct").tag(UUID?.none)
                ForEach(networks) { @Sendable network in
                    Text("\(network.displayName) (\(network.kind.displayName))")
                        .tag(UUID?.some(network.id))
                }
                if selectionIsMissing {
                    Text("Unavailable network").tag(route.overlayNetworkID)
                }
            }
            overlayPeerChooser
        } header: {
            Text("Network")
        } footer: {
            Text(networkFooter(hasNetworks: !networks.isEmpty, selectionIsMissing: selectionIsMissing))
        }
    }

    private func networkFooter(hasNetworks: Bool, selectionIsMissing: Bool) -> String {
        if selectionIsMissing {
            return "This route's overlay network was removed. Choose another network or Direct."
        }
        guard route.overlayNetworkID != nil else {
            return hasNetworks
                ? "Direct uses this device's own network connection."
                : "Direct uses this device's own network connection. Add Tailscale, ZeroTier, "
                    + "or EasyTier networks in Settings › Overlay Networks."
        }
        let target = route.usesJumpHost ? "the Jump Host" : "this Host"
        let base = "Heeler reaches \(target) through this network without turning on a VPN."
        guard let network = selectedOverlayNetwork, !OverlayPeerList.offersPeers(network.kind) else {
            return base
        }
        return base + " ZeroTier does not report member addresses; copy \(target)'s managed IP "
            + "from ZeroTier Central or your controller."
    }
}

/// Presents the peer picker of a route's Overlay Network.
private struct OverlayPeerPickerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let route: HostRouteDraft
    /// Hosts the peer picker may tag as already reached.
    let otherHosts: [Host]
    let onPeerChosen: (OverlayPeerCandidate, OverlayPeerCandidate.AddressStyle) -> Void

    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let overlayNetworks,
               let network = route.overlayNetworkID.flatMap({ overlayNetworks.network(id: $0) })
            {
                OverlayPeerPickerView(
                    network: network,
                    target: route.overlayPeerTarget,
                    chosenAddress: route.overlayPeerAddress,
                    model: OverlayPeerPickerModel(store: overlayNetworks, networkID: network.id),
                    hosts: otherHosts
                ) { candidate, style in
                    onPeerChosen(candidate, style)
                }
            }
        }
    }
}

extension View {
    /// Presents the peer picker `HostRouteFields` asks for. Apply it to the
    /// whole Form: a sheet on one of its Sections is installed more than
    /// once, so a tap presents it several times and dismissing the extra
    /// presentations closes the sheet holding the Form.
    func overlayPeerPicker(
        isPresented: Binding<Bool>,
        route: HostRouteDraft,
        otherHosts: [Host],
        onPeerChosen: @escaping (OverlayPeerCandidate, OverlayPeerCandidate.AddressStyle) -> Void
    ) -> some View {
        modifier(
            OverlayPeerPickerSheet(
                isPresented: isPresented, route: route, otherHosts: otherHosts,
                onPeerChosen: onPeerChosen))
    }
}

/// A page pushed from a Host form.
enum HostRoutePage: Hashable {
    /// A listed route, edited in place like the rest of the form.
    case route(HostRouteDraft.ID)
    /// Add Route's page, whose route joins the Host only on Save.
    case newRoute
}

/// Add Route's page. It edits a copy of the Host with the new route
/// appended, written back only on Save, so going Back adds nothing. A peer
/// chosen here names a still-unnamed Host, as on any route's page.
struct NewHostRouteView: View {
    @Binding var draft: HostDraft
    let otherHosts: [Host]

    /// Both fixed at first appearance: a parent redraw re-runs `init`, and a
    /// fresh id there would no longer name the route `pending` holds.
    @State private var pending: HostDraft
    @State private var routeID: HostRouteDraft.ID
    @State private var isChoosingOverlayPeer = false
    @Environment(\.dismiss) private var dismiss

    init(draft: Binding<HostDraft>, otherHosts: [Host]) {
        _draft = draft
        self.otherHosts = otherHosts
        let route = HostRouteDraft()
        _routeID = State(initialValue: route.id)
        var pending = draft.wrappedValue
        pending.routes.append(route)
        _pending = State(initialValue: pending)
    }

    var body: some View {
        Form {
            HostRouteFields(
                route: route,
                authMethod: pending.authMethod,
                isChoosingOverlayPeer: $isChoosingOverlayPeer)
        }
        .overlayPeerPicker(
            isPresented: $isChoosingOverlayPeer, route: route.wrappedValue, otherHosts: otherHosts
        ) { candidate, style in
            pending.applyOverlayPeer(candidate, style: style, toRoute: routeID)
        }
        .navigationTitle("New Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    draft = pending
                    dismiss()
                }
                .disabled(!route.wrappedValue.isValid)
            }
        }
    }

    /// The appended route; `pending` always holds it.
    private var route: Binding<HostRouteDraft> {
        Binding(
            get: { pending.routes.first { $0.id == routeID } ?? HostRouteDraft() },
            set: { updated in
                if let index = pending.routes.firstIndex(where: { $0.id == routeID }) {
                    pending.routes[index] = updated
                }
            })
    }
}

/// One listed route's own page.
struct HostRouteFormView: View {
    @Binding var draft: HostDraft
    let routeID: HostRouteDraft.ID
    let otherHosts: [Host]

    @State private var isChoosingOverlayPeer = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let index {
                HostRouteFields(
                    route: route,
                    authMethod: draft.authMethod,
                    isChoosingOverlayPeer: $isChoosingOverlayPeer)
                if draft.routes.count > 1 {
                    Section {
                        Button("Delete Route", role: .destructive) {
                            draft.removeRoutes(atOffsets: IndexSet(integer: index))
                            dismiss()
                        }
                    }
                }
            }
        }
        .overlayPeerPicker(
            isPresented: $isChoosingOverlayPeer, route: route.wrappedValue, otherHosts: otherHosts
        ) { candidate, style in
            draft.applyOverlayPeer(candidate, style: style, toRoute: routeID)
        }
        .navigationTitle(index.map { "Route \($0 + 1)" } ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var index: Int? {
        draft.routes.firstIndex { $0.id == routeID }
    }

    /// Looked up by id on every access, so the page outlives its route
    /// being deleted or moved without indexing past the list.
    private var route: Binding<HostRouteDraft> {
        Binding(
            get: { draft.routes.first { $0.id == routeID } ?? HostRouteDraft() },
            set: { updated in
                if let index = draft.routes.firstIndex(where: { $0.id == routeID }) {
                    draft.routes[index] = updated
                }
            })
    }
}

/// A route's row in a Host form's Routes list.
struct HostRouteRow: View {
    let route: HostRouteDraft

    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    var body: some View {
        HostRouteLabel(
            kind: HostRouteKind(
                usesOverlay: route.overlayNetworkID != nil, usesJumpHost: route.usesJumpHost)
        ) {
            Text(title)
                .font(.body.monospaced())
                .foregroundStyle(route.isValid ? Color.primary : Color.red)
        } subtitle: {
            Text(subtitle)
        }
    }

    private var address: String {
        route.address.trimmingCharacters(in: .whitespaces)
    }

    private var title: String {
        guard !address.isEmpty else { return "No address" }
        return route.port == "22" ? address : "\(address):\(route.port)"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let networkID = route.overlayNetworkID {
            parts.append(
                overlayNetworks?.network(id: networkID)?.displayName ?? "Unavailable network")
        }
        if route.usesJumpHost {
            parts.append("via \(route.jumpAddress.trimmingCharacters(in: .whitespaces))")
        }
        return parts.isEmpty ? "Direct" : parts.joined(separator: " · ")
    }
}

/// How a route reaches its Host, as its row's icon shows it. An Overlay
/// Network leads: it carries the first hop, Jump Host or not.
enum HostRouteKind: Equatable {
    case direct
    case overlay
    case jumpHost

    init(usesOverlay: Bool, usesJumpHost: Bool) {
        self = usesOverlay ? .overlay : usesJumpHost ? .jumpHost : .direct
    }

    init(_ route: HostRoute) {
        self.init(usesOverlay: route.overlayNetworkID != nil, usesJumpHost: route.usesJumpHost)
    }

    var systemImage: String {
        switch self {
        case .direct: "wifi"
        case .overlay: "point.3.connected.trianglepath.dotted"
        case .jumpHost: "arrow.triangle.branch"
        }
    }

    var tint: Color {
        switch self {
        case .direct: .blue
        case .overlay: .indigo
        case .jumpHost: .orange
        }
    }
}

/// A route's row content: its kind's icon, then the address over a
/// subtitle, and an optional trailing tag.
struct HostRouteLabel<Title: View, Subtitle: View, Trailing: View>: View {
    let kind: HostRouteKind
    @ViewBuilder let title: Title
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let trailing: Trailing

    @ScaledMetric(relativeTo: .body) private var iconSize = 30

    init(
        kind: HostRouteKind,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.kind = kind
        self.title = title()
        self.subtitle = subtitle()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(kind.tint)
                .frame(width: iconSize, height: iconSize)
                .background(kind.tint.opacity(0.14), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                subtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// A short capsule beside a route: In Use, Failed.
struct HostRouteTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: .capsule)
    }
}
