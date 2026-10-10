import HeelerOverlay
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Add/edit form for an Overlay Network. Secrets go straight to the Keychain
/// through the store; a blank secret field keeps the stored one when editing.
/// Adding picks the kind first and ends with one button that says what
/// happens next (the network then signs in or connects). Optional settings
/// are one push away, in Advanced.
struct OverlayNetworkFormView: View {
    let store: OverlayNetworkStore
    var editing: OverlayNetwork?
    /// Called with a new network's id after it is saved, before the form
    /// closes; not called when editing.
    var onAdded: ((OverlayNetwork.ID) -> Void)?
    @State private var draft: OverlayNetworkDraft
    @State private var saveError: String?
    @State private var isConfirmingNodeIDForget = false
    @State private var nodeIDForgetError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        store: OverlayNetworkStore, editing: OverlayNetwork? = nil,
        onAdded: ((OverlayNetwork.ID) -> Void)? = nil
    ) {
        self.store = store
        self.editing = editing
        self.onAdded = onAdded
        _draft = State(
            initialValue: editing.map {
                OverlayNetworkDraft(network: $0, configServerURL: store.secretText(for: $0))
            } ?? OverlayNetworkDraft())
    }

    private var hasStoredSecret: Bool {
        editing.map(store.hasSecret(for:)) ?? false
    }

    private var canSave: Bool {
        draft.canSave(hasStoredSecret: hasStoredSecret)
    }

    /// The add button's title: what saving starts.
    private var addTitle: String {
        guard draft.kind == .tailscale else { return "Add and Connect" }
        return draft.secretUpdate == nil ? "Continue to Sign In" : "Add and Connect"
    }

    var body: some View {
        NavigationStack {
            Form {
                // The kind decides every field below, so it comes first.
                // It also decides where the secret lives; changing it on a
                // saved network would orphan that secret.
                if editing == nil {
                    kindPicker
                }
                identitySection
                kindSection
            }
            .navigationTitle(editing == nil ? "Add Network" : "Edit Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if editing != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .modifier(
                OverlayFormBottomBar(isPresented: editing == nil) {
                    Button(action: save) {
                        Text(addTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                })
            .alert(
                "Could not save the network",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    /// The network's name and what identifies it: the device name it
    /// joins as, or ZeroTier's network ID.
    private var identitySection: some View {
        Section {
            if let editing {
                LabeledContent("Type", value: editing.kind.displayName)
            }
            OverlayFormField(title: "Name", prompt: "Optional", text: $draft.name)
            switch draft.kind {
            case .tailscale, .easytier:
                OverlayFormField(title: "Device name", prompt: "heeler", text: $draft.hostname)
            case .zerotier:
                OverlayFormField(
                    title: "Network ID", prompt: "Required", text: $draft.networkID,
                    isMonospaced: true)
            }
        } header: {
            // EasyTier's source decides the sections below; a header keeps
            // it close to them instead of a row's spacing away.
            if draft.kind == .easytier {
                Picker("Source", selection: $draft.easyTierSource) {
                    Text("Network").tag(OverlayNetwork.EasyTierSource.manual)
                    Text("Config Server").tag(OverlayNetwork.EasyTierSource.configServer)
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
                .padding(.bottom, 8)
            }
        } footer: {
            switch draft.kind {
            case .tailscale: Text("How this device appears in your tailnet.")
            case .zerotier: Text("16 hex digits, from ZeroTier Central or your controller.")
            case .easytier: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        switch draft.kind {
        case .tailscale:
            Section {
                NavigationLink {
                    TailscaleAdvancedForm(draft: $draft, hasStoredSecret: hasStoredSecret)
                } label: {
                    LabeledContent("Advanced", value: tailscaleAdvancedSummary)
                }
            } footer: {
                if !draft.controlURLIsValid {
                    Text("The coordination server must be an https URL. Fix it in Advanced.")
                        .foregroundStyle(.red)
                }
            }
            if let editing, let nodeID = store.details[editing.id]?.nodeID {
                Section {
                    OverlayCopyableRow(title: "Node ID", value: nodeID)
                } header: {
                    Text("This Device")
                } footer: {
                    Text("Support and admin tools may ask for it.")
                }
            }
        case .zerotier:
            // No node ID is made just for looking at the form: the first
            // connect creates it, and the network's screen shows it.
            if let nodeID = store.zeroTierNodeID {
                zeroTierNodeIDSection(nodeID)
            }
            Section {
                NavigationLink {
                    ZeroTierAdvancedForm(draft: $draft)
                } label: {
                    LabeledContent("Advanced", value: zeroTierAdvancedSummary)
                }
            } footer: {
                if !draft.invalidMoons.isEmpty {
                    Text("A moon is not valid. Fix it in Advanced.")
                        .foregroundStyle(.red)
                } else if store.zeroTierNodeID == nil {
                    Text(
                        "Heeler creates this device's node ID when it connects. The network's "
                            + "screen then shows it, ready to authorize.")
                }
            }
        case .easytier:
            if draft.easyTierSource == .configServer {
                easyTierConfigServerSections
            } else {
                easyTierNetworkSections
            }
        }
    }

    /// The node ID this device already has, from an earlier ZeroTier
    /// network. Touch and hold forgets it while no network uses it.
    private func zeroTierNodeIDSection(_ nodeID: String) -> some View {
        Section {
            OverlayCopyableRow(title: "Node ID", value: nodeID)
                .contextMenu {
                    // Text, Text, Image: the menu shows the value as a subtitle.
                    Button {
                        UIPasteboard.general.string = nodeID
                    } label: {
                        Text("Copy Node ID")
                        Text(nodeID)
                        Image(systemName: "doc.on.doc")
                    }
                    if store.hasUnusedZeroTierIdentity {
                        Button(role: .destructive) {
                            isConfirmingNodeIDForget = true
                        } label: {
                            Label("Forget Node ID…", systemImage: "trash")
                        }
                    }
                }
        } header: {
            Text("This Device")
        } footer: {
            Text(
                "Authorize it on the network so this device can join. Every ZeroTier network on "
                    + "this device shares it.")
        }
        .confirmationDialog(
            "Forget node ID \(nodeID)?", isPresented: $isConfirmingNodeIDForget,
            titleVisibility: .visible
        ) {
            Button("Forget Node ID", role: .destructive) {
                do {
                    try store.removeUnusedZeroTierIdentity()
                } catch {
                    nodeIDForgetError = "The node ID could not be removed from the Keychain."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This device gets a new one when it next connects a ZeroTier network. An admin "
                    + "who authorized this one has to authorize the new one.")
        }
        .alert(
            "Could not forget the node ID",
            isPresented: Binding(
                get: { nodeIDForgetError != nil },
                set: { if !$0 { nodeIDForgetError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(nodeIDForgetError ?? "")
        }
    }

    @ViewBuilder
    private var easyTierConfigServerSections: some View {
        Section {
            OverlayFormField(title: "Server", prompt: "Server URL", text: $draft.configServer)
                .keyboardType(.URL)
        } header: {
            Text("Config Server")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let url = draft.configServerURL {
                    Text(
                        "Connects to \(Text(url).monospaced()). \(EasyTierConfigServerCopy.trustNote)")
                    if let warning = EasyTierConfigServerCopy.transportWarning(for: url) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(OverlayStatusTone.attention.textColor)
                    }
                } else if !draft.configServer.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(
                        "Enter a udp://, tcp://, ws://, or wss:// URL ending in your user "
                            + "name, such as wss://host/user.")
                        .foregroundStyle(.red)
                } else {
                    Text(EasyTierConfigServerCopy.serverNote)
                }
            }
        }
        Section {
            OverlayCopyableRow(
                title: "Machine ID", value: draft.machineID.uuidString.lowercased(), isCompact: true)
        } header: {
            Text("This Device")
        } footer: {
            Text(EasyTierConfigServerCopy.machineIDNote)
        }
        Section {
            NavigationLink {
                EasyTierConfigServerAdvancedForm(draft: $draft)
            } label: {
                LabeledContent(
                    "Advanced",
                    value: draft.requireEncryption ? "Encryption required" : "Encryption not required")
            }
        }
    }

    @ViewBuilder
    private var easyTierNetworkSections: some View {
        Section {
            OverlayFormField(title: "Network name", prompt: "Required", text: $draft.networkName)
            secretField("Secret", prompt: "Required")
            VStack(alignment: .leading, spacing: 4) {
                Text("Peers")
                TextField(
                    "Peers", text: $draft.peers,
                    prompt: Text("tcp://host:11010, one per line"), axis: .vertical)
                    .lineLimit(2...6)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .labelsHidden()
                    .accessibilityLabel("Peers")
            }
        } header: {
            Text("Network")
        } footer: {
            if let invalid = draft.invalidPeers.first {
                Text("“\(invalid)” is not a peer such as tcp://host:11010 or udp://host:11010.")
                    .foregroundStyle(.red)
            } else {
                Text(
                    "The same name and secret as on your Mac. Peers are how the two find each "
                        + "other, such as tcp://public.easytier.top:11010, one per line.")
            }
        }
        Section {
            NavigationLink {
                EasyTierAdvancedForm(draft: $draft)
            } label: {
                LabeledContent("Advanced", value: easyTierAdvancedSummary)
            }
        } footer: {
            if !draft.ipv4IsValid {
                Text("The fixed address is not valid. Fix it in Advanced.")
                    .foregroundStyle(.red)
            }
        }
    }

    /// Which optional Tailscale settings are set, beside Advanced.
    private var tailscaleAdvancedSummary: String {
        var parts: [String] = []
        if !draft.controlURL.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(draft.controlURLValue?.host() ?? "Invalid server")
        }
        if draft.secretUpdate != nil {
            parts.append("Auth key")
        } else if hasStoredSecret {
            parts.append("Auth key saved")
        }
        return parts.isEmpty ? "Optional" : parts.joined(separator: ", ")
    }

    /// The moons and custom planet, beside Advanced.
    private var zeroTierAdvancedSummary: String {
        var parts: [String] = []
        let moons = draft.moons.filter { !$0.isBlank }.count
        if moons > 0 {
            parts.append(moons == 1 ? "1 moon" : "\(moons) moons")
        }
        if draft.planet != nil {
            parts.append("Custom planet")
        }
        return parts.isEmpty ? "Optional" : parts.joined(separator: ", ")
    }

    /// The fixed address, or DHCP, beside Advanced.
    private var easyTierAdvancedSummary: String {
        let ipv4 = draft.ipv4.trimmingCharacters(in: .whitespaces)
        return ipv4.isEmpty ? "DHCP" : ipv4
    }

    /// The kinds side by side, each with what joining it takes. A header,
    /// not a row: a row clips to the section's larger corner radius, which
    /// cuts the outer corners of the first and last card.
    private var kindPicker: some View {
        Section {
        } header: {
            OverlayKindPicker(selection: $draft.kind)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
                .padding(.top, 12)
        }
    }

    private func secretField(_ title: String, prompt: String) -> some View {
        // No password content type: these are network secrets, not account
        // passwords, and must not be offered to (or saved by) AutoFill.
        LabeledContent {
            SecureField(
                title, text: $draft.secret,
                prompt: Text(hasStoredSecret ? "Blank keeps current" : prompt))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Network secret")
        } label: {
            Text(title)
        }
    }

    private func save() {
        guard canSave, let network = draft.makeNetwork(id: editing?.id ?? UUID()) else { return }
        do {
            if editing == nil {
                try store.add(network, secret: draft.secretUpdate)
                onAdded?(network.id)
            } else {
                try store.update(network, secret: draft.secretUpdate)
            }
        } catch {
            saveError = (error as? OverlayNetworkStoreError)?.message
                ?? "The network or its secret could not be saved."
            return
        }
        dismiss()
    }
}

enum EasyTierConfigServerCopy {
    static let serverNote =
        "The full URL from the server's operator, ending in your user name. \(trustNote)"

    static let trustNote =
        "The server knows the network secrets and decides which peers this device connects to."

    static let machineIDNote =
        "Assign up to 8 networks to it in the EasyTier console, with different subnets: a Host "
        + "reaches the one its address or name is on. Heeler only connects out and drops their "
        + "listeners."

    static let encryptionOffWarning =
        "Without it, a server that offers no encryption gets the user name and network secret "
        + "in clear text: anyone on the network path can read them, change the network the "
        + "server sends, or pose as the server."

    /// The risk of a config server URL's transport, or nil for wss://, the
    /// only one that authenticates the server.
    static func transportWarning(for url: String) -> String? {
        switch URLComponents(string: url)?.scheme?.lowercased() {
        case "ws":
            return "ws:// sends the user name (the server's token) in clear text when it connects, "
                + "and nothing verifies the server. Prefer wss://."
        case "udp", "tcp":
            return "udp:// and tcp:// encrypt the session but do not verify the server: someone who "
                + "can intercept the connection could pose as it and learn the network secret. "
                + "Prefer wss:// on networks you do not trust."
        default:
            return nil
        }
    }
}

/// Add Network's kind choice: a card per kind, side by side (stacked at
/// accessibility text sizes), each saying what joining it takes.
private struct OverlayKindPicker: View {
    @Binding var selection: OverlayKind
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            ForEach(OverlayKind.allCases, id: \.self) { kind in
                card(kind)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Type")
    }

    private func card(_ kind: OverlayKind) -> some View {
        let isSelected = selection == kind
        return Button {
            selection = kind
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                OverlayKindGlyph(kind: kind)
                Text(kind.displayName)
                    .font(.subheadline.weight(.semibold))
                    // Explicit colors: a section header dims its content.
                    .foregroundStyle(Color.primary)
                Text(Self.blurb(kind))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func blurb(_ kind: OverlayKind) -> String {
        switch kind {
        case .tailscale: "Sign in with your account"
        case .zerotier: "Join by network ID"
        case .easytier: "Peers or a config server"
        }
    }
}

/// A titled row: the title stays visible beside what was typed, so a
/// filled-in form still says what each value is. A monospaced value keeps
/// its title in the body font.
private struct OverlayFormField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var isMonospaced = false

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(prompt))
                .font(isMonospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // A prompt alone is not a label; VoiceOver names the field.
                .accessibilityLabel(title)
        } label: {
            Text(title)
        }
    }
}

/// ZeroTier's optional settings: moons, and a custom planet imported from
/// Files.
private struct ZeroTierAdvancedForm: View {
    @Binding var draft: OverlayNetworkDraft
    @State private var isImportingPlanet = false
    @State private var planetError: String?

    var body: some View {
        Form {
            Section {
                ForEach($draft.moons) { $moon in
                    VStack(alignment: .leading) {
                        OverlayFormField(
                            title: "World ID", prompt: "10–16 hex digits", text: $moon.worldID,
                            isMonospaced: true)
                        OverlayFormField(
                            title: "Seed", prompt: "Root node ID", text: $moon.seed, isMonospaced: true)
                    }
                }
                .onDelete { draft.moons.remove(atOffsets: $0) }
                Button {
                    draft.moons.append(OverlayNetworkDraft.MoonDraft())
                } label: {
                    Label("Add Moon", systemImage: "plus")
                }
            } header: {
                Text("Moons")
            } footer: {
                if !draft.invalidMoons.isEmpty {
                    Text(
                        "A moon's world ID is 10 to 16 hexadecimal digits and its seed is a "
                            + "10-digit node ID; neither may be zero.")
                        .foregroundStyle(.red)
                } else {
                    Text(
                        "Extra roots, as in zerotier-cli orbit: the moon's world ID and the node ID "
                            + "of one of its roots.")
                }
            }
            planetSection
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var planetSection: some View {
        Section {
            LabeledContent(
                "Planet",
                value: draft.planet.map { "Custom (\($0.count) bytes)" } ?? "ZeroTier default")
            Button {
                isImportingPlanet = true
            } label: {
                Label(
                    draft.planet == nil ? "Import Planet File…" : "Replace Planet File…",
                    systemImage: "square.and.arrow.down")
            }
            if draft.planet != nil {
                Button(role: .destructive) {
                    draft.planet = nil
                    planetError = nil
                } label: {
                    Label("Use ZeroTier's Planet", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("Custom Planet")
        } footer: {
            if let planetError {
                Text(planetError)
                    .foregroundStyle(.red)
            } else {
                Text(
                    "For a controller on self-hosted roots: the planet file its operator made with "
                        + "mkworld. Only this network uses it.")
            }
        }
        .fileImporter(isPresented: $isImportingPlanet, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                do {
                    draft.planet = try OverlayNetworkStore.readZeroTierPlanet(from: url)
                    planetError = nil
                } catch {
                    planetError = (error as? OverlayNetworkStoreError)?.message
                        ?? OverlayNetworkStoreError.zeroTierPlanetNotSaved.message
                }
            case .failure:
                planetError = OverlayNetworkStoreError.zeroTierPlanetNotSaved.message
            }
        }
    }
}

/// An EasyTier network's optional fixed address.
private struct EasyTierAdvancedForm: View {
    @Binding var draft: OverlayNetworkDraft

    var body: some View {
        Form {
            Section {
                OverlayFormField(title: "Fixed IPv4", prompt: "DHCP", text: $draft.ipv4)
                    .keyboardType(.numbersAndPunctuation)
            } footer: {
                if !draft.ipv4IsValid {
                    Text(
                        "A fixed address is a private IPv4 address with a prefix, such as "
                            + "10.144.144.7/24 (not 0.x, 127.x, or 224 and up).")
                        .foregroundStyle(.red)
                } else if draft.ipv4IsHostPrefix {
                    Text(
                        "EasyTier treats a /32 address as part of its /24. Use the network's own "
                            + "prefix.")
                } else {
                    Text(
                        "Leave blank to get an address from the network, or enter one with its "
                            + "prefix, such as 10.144.144.7/24.")
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A config server's optional setting: whether it must encrypt.
private struct EasyTierConfigServerAdvancedForm: View {
    @Binding var draft: OverlayNetworkDraft

    var body: some View {
        Form {
            Section {
                Toggle("Require Encryption", isOn: $draft.requireEncryption)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !draft.requireEncryption {
                        Label(EasyTierConfigServerCopy.encryptionOffWarning, systemImage: "lock.open")
                            .foregroundStyle(OverlayStatusTone.attention.textColor)
                    }
                    Text("Leave it on unless your own server can't encrypt.")
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Tailscale's optional settings, one push away from the form: a Headscale
/// server and an auth key that signs in without the browser.
private struct TailscaleAdvancedForm: View {
    @Binding var draft: OverlayNetworkDraft
    let hasStoredSecret: Bool

    var body: some View {
        Form {
            Section {
                TextField("Coordination server", text: $draft.controlURL, prompt: Text("Tailscale"))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Coordination Server")
            } footer: {
                if draft.controlURLIsValid {
                    Text(
                        "Leave blank for a Tailscale account. Enter an https URL to use your own "
                            + "Headscale server.")
                } else {
                    Text("Enter an https URL, such as https://headscale.example.com.")
                        .foregroundStyle(.red)
                }
            }
            Section {
                // No password content type: an auth key is not an account
                // password and must not be offered to (or saved by) AutoFill.
                SecureField(
                    "Auth key", text: $draft.secret,
                    prompt: Text(hasStoredSecret ? "Blank keeps current" : "None"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Auth Key")
            } footer: {
                Text("Signs this device in without the browser. Heeler keeps it in the Keychain.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The form's one button at the bottom, above the keyboard, with the
/// system's scroll edge effect where there is one.
private struct OverlayFormBottomBar<Bar: View>: ViewModifier {
    let isPresented: Bool
    @ViewBuilder let bar: Bar

    func body(content: Content) -> some View {
        if !isPresented {
            content
        } else if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom) {
                bar.background(Color(.systemGroupedBackground))
            }
        }
    }
}
