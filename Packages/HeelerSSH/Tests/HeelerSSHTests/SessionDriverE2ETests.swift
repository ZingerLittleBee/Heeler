import Foundation
import Testing

@testable import HeelerSSH

@Suite(
    "Session driver resource e2e",
    .enabled(
        if: SessionDriverTestEnvironment.current != nil,
        "requires a password-authenticated sshd fixture"),
    .serialized)
struct SessionDriverE2ETests {
    @Test("public connection resolves localhost before authenticating")
    func publicConnectionResolvesLocalhost() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "localhost", port: environment.endpoint.port),
            timeout: .seconds(5))

        try await connection.authenticate(
            username: environment.username,
            password: environment.password,
            timeout: .seconds(5))
        let result = try await connection.execute(
            "printf resolved",
            timeout: .seconds(5))

        #expect(result.stdout == Data("resolved".utf8))
        #expect(result.exitStatus == 0)
        try await connection.close(timeout: .seconds(1))
    }

    @Test("remote transport loss reclaims every owned native resource")
    func remoteTransportLossReclaimsResources() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for _ in 0..<3 {
            let driver = SessionDriver()
            _ = try await driver.handshake(
                endpoint: environment.endpoint,
                timeout: .seconds(5))
            try await driver.authenticate(
                username: environment.username,
                password: environment.password,
                timeout: .seconds(5))

            await #expect(throws: SSHError.self) {
                _ = try await driver.execute(
                    command: "kill -9 $PPID; sleep 30",
                    input: Data(),
                    timeout: .seconds(5))
            }

            let state = await driver.resourceStateForTesting()
            #expect(state == SessionDriverResourceState(
                hasSession: false,
                descriptorIsOpen: false,
                isValid: false))
        }
    }
}

private struct SessionDriverTestEnvironment: Sendable {
    let endpoint: SSHEndpoint
    let username: String
    let password: String

    static let current: SessionDriverTestEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["HEELER_SSH_E2E_REQUIRED"] == "1",
            let host = environment["HEELER_SSH_E2E_HOST"],
            let portText = environment["HEELER_SSH_E2E_PORT"],
            let port = UInt16(portText),
            let username = environment["HEELER_SSH_E2E_USERNAME"],
            let password = environment["HEELER_SSH_E2E_PASSWORD"]
        else {
            return nil
        }
        return SessionDriverTestEnvironment(
            endpoint: SSHEndpoint(host: host, port: port),
            username: username,
            password: password)
    }()
}
