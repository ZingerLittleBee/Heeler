import Foundation
import Testing

/// Two release commitments that no runtime assertion can reach, because they are
/// claims about what the code does *not* contain: obsolete SSH algorithms are
/// never negotiated, and a private key never leaves CryptoKit and the Keychain.
///
/// `Packages/HeelerSSH/Scripts/verify-native.sh` proves the same algorithm
/// policy against the built artifacts. This proves it against the source that
/// configures them, so a future edit cannot re-enable an algorithm the binaries
/// still contain, and cannot hand libssh2 private key material.
@Suite("HeelerSSH source policy")
struct SSHSourcePolicyTests {
    /// Obsolete algorithms ADR 0011 keeps disabled. libssh2 and OpenSSL still
    /// implement several of these, so the only thing keeping them off the wire
    /// is the method preference the driver installs.
    static let forbiddenAlgorithms = [
        "ssh-dss",
        "ssh-rsa",
        "diffie-hellman-group1-sha1",
        "diffie-hellman-group14-sha1",
        "diffie-hellman-group-exchange-sha1",
        "hmac-sha1",
        "hmac-md5",
        "aes128-cbc",
        "aes192-cbc",
        "aes256-cbc",
        "3des-cbc",
        "blowfish-cbc",
        "cast128-cbc",
        "arcfour",
    ]

    /// Ways libssh2 or OpenSSL can be handed private key material directly.
    /// #110 restricts the package to a public key blob plus a signing closure,
    /// so none of these may appear anywhere in it.
    static let forbiddenPrivateKeyEntryPoints = [
        "userauth_publickey_fromfile",
        "userauth_publickey_frommemory",
        "libssh2_agent",
        "PEM_read",
        "PEM_write",
        "d2i_PrivateKey",
        "d2i_AutoPrivateKey",
        "EVP_PKEY_new_raw_private_key",
    ]

    @Test("the session driver negotiates no obsolete algorithm")
    func methodPreferencesExcludeObsoleteAlgorithms() throws {
        let driver = try Self.read("Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift")

        for algorithm in Self.forbiddenAlgorithms {
            #expect(
                !driver.contains("\"\(algorithm)\""),
                "SessionDriver lists the obsolete algorithm \(algorithm)")
        }
        // The preference strings must actually be installed; an empty or absent
        // preference lets libssh2 fall back to its own defaults, which do
        // include the algorithms above.
        #expect(driver.contains("libssh2_session_method_pref"))
    }

    @Test("the SSH package has no private key entry point")
    func packageAcceptsNoPrivateKeyMaterial() throws {
        let sources = try Self.swiftAndCSources(under: "Packages/HeelerSSH/Sources")
        #expect(!sources.isEmpty)

        for (path, contents) in sources {
            for entryPoint in Self.forbiddenPrivateKeyEntryPoints {
                #expect(
                    !contents.contains(entryPoint),
                    "\(path) reaches private key material through \(entryPoint)")
            }
        }
    }

    /// The app hands the package a public key blob and a closure that signs
    /// inside CryptoKit. Nothing serializes the private half towards SSH.
    @Test("the transport signs through CryptoKit rather than exporting a key")
    func transportPassesOnlyPublicKeyAndSigner() throws {
        let adapter = try Self.read("Sources/Heeler/Transport/HeelerSSHTransport.swift")

        #expect(adapter.contains("publicKeyBlob"))
        #expect(!adapter.contains("privateKey.rawRepresentation"))
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HeelerTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private static func swiftAndCSources(under relativePath: String) throws -> [(String, String)] {
        let root = repositoryRoot.appendingPathComponent(relativePath)
        guard
            let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil)
        else { return [] }

        var sources: [(String, String)] = []
        for case let url as URL in walker where ["swift", "c", "h"].contains(url.pathExtension) {
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return sources
    }
}
