import Foundation

/// TOFU persistence: the host key fingerprint the user trusted for each
/// Host, keyed by host and port. Not a secret — it guards against future
/// impostors, it does not authenticate us — so app-level storage is fine.
/// Injectable so tests can seed and observe it.
protocol KnownHostsStore: Sendable {
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint?
    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async
}

/// Volatile store for tests and previews.
actor InMemoryKnownHostsStore: KnownHostsStore {
    private var fingerprints: [String: HostKeyFingerprint] = [:]

    func fingerprint(host: String, port: Int) -> HostKeyFingerprint? {
        fingerprints[Self.key(host: host, port: port)]
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        fingerprints[Self.key(host: host, port: port)] = fingerprint
    }

    static func key(host: String, port: Int) -> String {
        "\(host):\(port)"
    }
}

/// The app's persistent store: digests in UserDefaults, keyed "host:port".
struct UserDefaultsKnownHostsStore: KnownHostsStore {
    private static let defaultsKey = "knownHostFingerprints"
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint? {
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]
        guard
            let base64 = stored?[InMemoryKnownHostsStore.key(host: host, port: port)],
            let digest = Data(base64Encoded: base64)
        else { return nil }
        return HostKeyFingerprint(digest: digest)
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async {
        var stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        stored[InMemoryKnownHostsStore.key(host: host, port: port)] =
            fingerprint.digest.base64EncodedString()
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}
