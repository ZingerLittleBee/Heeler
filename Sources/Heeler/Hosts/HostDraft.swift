import Foundation

/// Editable state of one route in `HostFormView` (ADR 0022). Text-field
/// friendly like `HostDraft`.
struct HostRouteDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var address = ""
    var port = "22"
    /// Blank means the device dials the Host itself. When set, Address/Port
    /// are resolved from the Jump Host, not from this device.
    var jumpAddress = ""
    var jumpPort = "22"
    /// Blank reuses the Host's own username.
    var jumpUsername = ""
    /// nil connects over this device's network; otherwise the Overlay
    /// Network carrying the first hop.
    var overlayNetworkID: UUID?

    init() {}

    init(route: HostRoute) {
        id = route.id
        address = route.address
        port = String(route.port)
        jumpAddress = route.jumpAddress
        jumpPort = String(route.jumpPort)
        jumpUsername = route.jumpUsername
        overlayNetworkID = route.overlayNetworkID
    }

    var portNumber: Int? {
        guard let value = Int(port), (1...65535).contains(value) else { return nil }
        return value
    }

    var jumpPortNumber: Int? {
        guard let value = Int(jumpPort), (1...65535).contains(value) else { return nil }
        return value
    }

    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isValid: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
            // A blank jump address disables the hop entirely, so its port only
            // has to parse when the hop is actually in use.
            && (!usesJumpHost || jumpPortNumber != nil)
    }

    /// The route this draft describes, or nil while invalid.
    func makeRoute() -> HostRoute? {
        guard isValid, let portNumber else { return nil }
        return HostRoute(
            id: id,
            address: address.trimmingCharacters(in: .whitespaces),
            port: portNumber,
            jumpAddress: jumpAddress.trimmingCharacters(in: .whitespaces),
            jumpPort: jumpPortNumber ?? 22,
            jumpUsername: jumpUsername.trimmingCharacters(in: .whitespaces),
            overlayNetworkID: overlayNetworkID)
    }
}

/// Editable form state behind `HostFormView`, validated before it becomes a
/// catalog Host. Text-field friendly (port is a string) so the view stays
/// dumb and the rules stay testable.
struct HostDraft: Equatable, Sendable {
    var name = ""
    var username = ""
    var authMethod: Host.AuthMethod = .deviceKey
    var backend: HostBackend = .herdr
    /// Blank means "keep the stored password" when editing.
    var password = ""
    var sessionName = ""
    /// The Pairing Code's herdr endpoint, carried through Edit and Duplicate
    /// unchanged. The form shows it read-only; nil for every other Host.
    var herdrEndpoint: HerdrEndpoint?
    /// The Host's routes in order. A new Host starts with none and cannot
    /// be saved until Add Route gives it one; the forwarding properties
    /// below create the first route when set.
    var routes: [HostRouteDraft] = []

    init() {}

    /// Prefill for editing an existing Host.
    init(host: Host) {
        name = host.name
        username = host.username
        authMethod = host.authMethod
        backend = host.backend
        sessionName = host.sessionName
        herdrEndpoint = host.herdrEndpoint
        routes = host.routes.map(HostRouteDraft.init(route:))
    }

    /// Prefill for adding a copy of `host`: every field Edit prefills, the
    /// stored `password` for password authentication, and the next free
    /// copy name among `existingNames` (display names).
    init(duplicating host: Host, password: String?, existingNames: [String]) {
        self.init(host: host)
        name = Self.duplicateName(of: host.displayName, existingNames: existingNames)
        // The copy's routes are its own.
        for index in routes.indices {
            routes[index].id = UUID()
        }
        if host.authMethod == .password {
            self.password = password ?? ""
        }
    }

    /// Names a copy the way Finder does: `name copy`, then `name copy 2`,
    /// `name copy 3`, … — the first one not taken. Duplicating a copy
    /// continues its series (`box copy` → `box copy 2`) instead of stacking
    /// (`box copy copy`).
    static func duplicateName(of name: String, existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.trimmingCharacters(in: .whitespaces) })
        let first = "\(copyStem(of: name.trimmingCharacters(in: .whitespaces))) copy"
        guard taken.contains(first) else { return first }
        var count = 2
        while taken.contains("\(first) \(count)") {
            count += 1
        }
        return "\(first) \(count)"
    }

    /// `box` for `box copy` and `box copy 3`; any other name is its own stem.
    private static func copyStem(of name: String) -> String {
        let suffix = " copy"
        var stem = Substring(name)
        if let space = stem.lastIndex(of: " ") {
            let number = stem[stem.index(after: space)...]
            if !number.isEmpty, number.allSatisfy({ ("0"..."9").contains($0) }),
               stem[..<space].hasSuffix(suffix)
            {
                stem = stem[..<space]
            }
        }
        if stem.hasSuffix(suffix) {
            stem = stem.dropLast(suffix.count)
        }
        return String(stem)
    }

    /// The first route; blank while there is none.
    var primaryRoute: HostRouteDraft {
        get { routes.first ?? HostRouteDraft() }
        set {
            if routes.isEmpty {
                routes = [newValue]
            } else {
                routes[0] = newValue
            }
        }
    }

    var address: String {
        get { primaryRoute.address }
        set { primaryRoute.address = newValue }
    }

    var port: String {
        get { primaryRoute.port }
        set { primaryRoute.port = newValue }
    }

    var jumpAddress: String {
        get { primaryRoute.jumpAddress }
        set { primaryRoute.jumpAddress = newValue }
    }

    var jumpPort: String {
        get { primaryRoute.jumpPort }
        set { primaryRoute.jumpPort = newValue }
    }

    var jumpUsername: String {
        get { primaryRoute.jumpUsername }
        set { primaryRoute.jumpUsername = newValue }
    }

    var overlayNetworkID: UUID? {
        get { primaryRoute.overlayNetworkID }
        set { primaryRoute.overlayNetworkID = newValue }
    }

    var portNumber: Int? { primaryRoute.portNumber }

    var jumpPortNumber: Int? { primaryRoute.jumpPortNumber }

    var usesJumpHost: Bool { primaryRoute.usesJumpHost }

    /// Removes the routes at `offsets`, keeping at least one.
    mutating func removeRoutes(atOffsets offsets: IndexSet) {
        guard offsets.count < routes.count else { return }
        for index in offsets.sorted(by: >) where routes.indices.contains(index) {
            routes.remove(at: index)
        }
    }

    /// Reorders routes as a list's move gesture does.
    mutating func moveRoutes(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().compactMap { routes.indices.contains($0) ? routes[$0] : nil }
        let insertion = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where routes.indices.contains(index) {
            routes.remove(at: index)
        }
        routes.insert(contentsOf: moving, at: max(0, min(insertion, routes.count)))
    }

    var isValid: Bool {
        return !routes.isEmpty
            && routes.allSatisfy(\.isValid)
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (herdrEndpoint == nil ? backend : .herdr).isValidSessionName(sessionName)
    }

    /// Form-level validity including credential intent. A blank password can
    /// only mean "keep current" when the existing Host already used password
    /// authentication; new Hosts and Device Key -> Password changes require
    /// an actual secret to persist.
    func canSave(editing existingHost: Host?) -> Bool {
        guard isValid else { return false }
        guard authMethod == .password, password.isEmpty else { return true }
        return existingHost?.authMethod == .password
    }

    /// The catalog Host this draft describes, or nil while invalid. Pass the
    /// existing id when editing so the Host keeps its identity (and its
    /// Keychain password account).
    func makeHost(id: UUID = UUID()) -> Host? {
        guard isValid else { return nil }
        let routes = routes.compactMap { $0.makeRoute() }
        guard routes.count == self.routes.count else { return nil }
        return Host(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            backend: backend,
            sessionName: sessionName.trimmingCharacters(in: .whitespaces),
            herdrEndpoint: herdrEndpoint,
            routes: routes)
    }

    /// What to hand `HostStore.add/update` as the password argument: a new
    /// secret to store, or nil for "leave storage as it is".
    var passwordUpdate: String? {
        guard authMethod == .password, !password.isEmpty else { return nil }
        return password
    }
}
