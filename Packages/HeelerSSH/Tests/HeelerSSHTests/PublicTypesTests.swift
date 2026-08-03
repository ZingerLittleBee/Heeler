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

@Test("Host Key algorithms preserve the NIOSSH prefix before modern RSA fallback")
func hostKeyAlgorithmsPreserveNIOSSHOrder() {
    #expect(SessionDriver.hostKeyAlgorithms == [
        "ssh-ed25519",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp521",
        "rsa-sha2-512",
        "rsa-sha2-256",
    ])
}
