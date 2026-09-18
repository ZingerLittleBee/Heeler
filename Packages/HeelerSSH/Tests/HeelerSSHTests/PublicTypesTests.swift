import Foundation
import Testing

@testable import HeelerSSH

@Test("public session values preserve their data")
func publicSessionValuesPreserveTheirData() {
    let endpoint = SSHEndpoint(host: "example.com", port: 2222)
    let hostKey = SSHHostKey(algorithm: "ssh-ed25519", key: Data([1, 2, 3]))
    let result = SSHExecResult(
        stdout: Data("out".utf8),
        stderr: Data("err".utf8),
        exitStatus: 7,
        reachedEOF: true)

    #expect(endpoint.host == "example.com")
    #expect(endpoint.port == 2222)
    #expect(hostKey.algorithm == "ssh-ed25519")
    #expect(hostKey.key == Data([1, 2, 3]))
    #expect(result.stdout == Data("out".utf8))
    #expect(result.stderr == Data("err".utf8))
    #expect(result.exitStatus == 7)
    #expect(result.reachedEOF)
}

/// Frozen order, not a preference to tune: an existing algorithm-aware TOFU
/// record must keep matching, so reordering these would present a stored Host
/// as a key change (ADR 0011).
@Test("Host Key algorithms preserve the migrated prefix before modern RSA fallback")
func hostKeyAlgorithmsPreserveMigratedOrder() {
    #expect(SessionDriver.hostKeyAlgorithms == [
        "ssh-ed25519",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp521",
        "rsa-sha2-512",
        "rsa-sha2-256",
    ])
}

@Test("Client RSA signatures are pinned to RSA-SHA2-512")
func clientRSASignaturesUseSHA512Only() {
    #expect(SessionDriver.signatureAlgorithms == ["rsa-sha2-512"])
}

@Test("An RSA key is signed only for RSA-SHA2-512 user-auth requests")
func rsaKeySignsOnlyForRSASHA512() {
    let publicKey = sshString("ssh-rsa")
        + sshString(Data([1, 0, 1]))
        + sshString(Data([0, 0xC3]))

    #expect(PublicKeySignaturePolicy.permits(
        publicKey: publicKey,
        signedData: userAuthSignedData(algorithm: "rsa-sha2-512", publicKey: publicKey)))
    // libssh2 keeps the default `ssh-rsa` name when the server sent no
    // `server-sig-algs`; signing then would label SHA-512 bytes as SHA-1.
    #expect(!PublicKeySignaturePolicy.permits(
        publicKey: publicKey,
        signedData: userAuthSignedData(algorithm: "ssh-rsa", publicKey: publicKey)))
    #expect(!PublicKeySignaturePolicy.permits(
        publicKey: publicKey,
        signedData: userAuthSignedData(algorithm: "rsa-sha2-256", publicKey: publicKey)))
    #expect(!PublicKeySignaturePolicy.permits(
        publicKey: publicKey,
        signedData: Data("not a user-auth request".utf8)))
}

@Test("A non-RSA key is not constrained by the RSA signature pin")
func nonRSAKeysAreNotConstrained() {
    let publicKey = sshString("ssh-ed25519") + sshString(Data(repeating: 7, count: 32))

    #expect(PublicKeySignaturePolicy.permits(
        publicKey: publicKey,
        signedData: userAuthSignedData(algorithm: "ssh-ed25519", publicKey: publicKey)))
}

@Test("The requested algorithm is read from the RFC 4252 signed data")
func requestedAlgorithmIsReadFromSignedData() {
    let signedData = userAuthSignedData(
        algorithm: "rsa-sha2-512",
        publicKey: sshString("ssh-rsa"))

    #expect(PublicKeySignaturePolicy.requestedAlgorithm(in: signedData) == "rsa-sha2-512")
    // Cut inside the user name: a truncated request names no algorithm.
    #expect(PublicKeySignaturePolicy.requestedAlgorithm(in: signedData.prefix(40)) == nil)
}

private func userAuthSignedData(algorithm: String, publicKey: Data) -> Data {
    sshString(Data(repeating: 0xAB, count: 32))
        + Data([50])
        + sshString("heeler")
        + sshString("ssh-connection")
        + sshString("publickey")
        + Data([1])
        + sshString(algorithm)
        + sshString(publicKey)
}

private func sshString(_ value: String) -> Data {
    sshString(Data(value.utf8))
}

private func sshString(_ value: Data) -> Data {
    var length = UInt32(value.count).bigEndian
    return Data(bytes: &length, count: 4) + value
}
