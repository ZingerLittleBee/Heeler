import Foundation

/// TOFU persistence: fingerprints are keyed by endpoint and SSH key
/// algorithm, matching OpenSSH's ability to trust more than one host-key
/// algorithm for the same machine. Not a secret: it guards against future
/// impostors, it does not authenticate us.
protocol KnownHostsStore: Sendable {
    func fingerprints(host: String, port: Int) async -> [HostKeyFingerprint]
    func fingerprint(host: String, port: Int, algorithm: String) async -> HostKeyFingerprint?
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint?
    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async
}

extension KnownHostsStore {
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint? {
        await fingerprints(host: host, port: port).first
    }
}

/// Volatile store for tests and previews.
actor InMemoryKnownHostsStore: KnownHostsStore {
    private var storedFingerprints: [String: HostKeyFingerprint] = [:]

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        let prefix = Self.algorithmKeyPrefix(host: host, port: port)
        return storedFingerprints
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        storedFingerprints[Self.algorithmKey(host: host, port: port, algorithm: algorithm)]
            ?? storedFingerprints[
                Self.algorithmKey(
                    host: host, port: port, algorithm: HostKeyFingerprint.unknownAlgorithm)]
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        if fingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm {
            storedFingerprints[
                Self.algorithmKey(
                    host: host, port: port, algorithm: HostKeyFingerprint.unknownAlgorithm)] = nil
        }
        storedFingerprints[
            Self.algorithmKey(host: host, port: port, algorithm: fingerprint.algorithm)] =
            fingerprint
    }

    static func endpointKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    static func algorithmKeyPrefix(host: String, port: Int) -> String {
        let endpoint = endpointKey(host: host, port: port)
        return "v2|\(endpoint.utf8.count)|\(endpoint)|"
    }

    static func algorithmKey(host: String, port: Int, algorithm: String) -> String {
        algorithmKeyPrefix(host: host, port: port) + algorithm
    }
}

/// The app's persistent store. Production uses one shared actor so concurrent
/// first connects cannot lose each other's read-modify-write updates.
actor UserDefaultsKnownHostsStore: KnownHostsStore {
    static let shared = UserDefaultsKnownHostsStore()
    private static let defaultsKey = "knownHostFingerprints"
    private let defaults: UserDefaults

    init() {
        defaults = .standard
    }

    init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        let stored = storedValues()
        let prefix = InMemoryKnownHostsStore.algorithmKeyPrefix(host: host, port: port)
        var fingerprints = stored.compactMap { key, base64 -> HostKeyFingerprint? in
            guard key.hasPrefix(prefix), let digest = Data(base64Encoded: base64) else {
                return nil
            }
            let algorithm = String(key.dropFirst(prefix.count))
            return HostKeyFingerprint(digest: digest, algorithm: algorithm)
        }
        if let legacy = legacyFingerprint(in: stored, host: host, port: port) {
            fingerprints.append(legacy)
        }
        return fingerprints
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        let stored = storedValues()
        let key = InMemoryKnownHostsStore.algorithmKey(
            host: host, port: port, algorithm: algorithm)
        if let base64 = stored[key], let digest = Data(base64Encoded: base64) {
            return HostKeyFingerprint(digest: digest, algorithm: algorithm)
        }
        return legacyFingerprint(in: stored, host: host, port: port)
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        var stored = storedValues()
        if fingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm {
            stored[InMemoryKnownHostsStore.endpointKey(host: host, port: port)] = nil
        }
        stored[
            InMemoryKnownHostsStore.algorithmKey(
                host: host, port: port, algorithm: fingerprint.algorithm)] =
                fingerprint.digest.base64EncodedString()
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    private func storedValues() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func legacyFingerprint(
        in stored: [String: String], host: String, port: Int
    ) -> HostKeyFingerprint? {
        guard
            let base64 = stored[InMemoryKnownHostsStore.endpointKey(host: host, port: port)],
            let digest = Data(base64Encoded: base64)
        else { return nil }
        return HostKeyFingerprint(digest: digest)
    }
}
