import Foundation
import HeelerSSH
import Synchronization

/// Whether one Host's SSH server has refused the SFTP subsystem.
///
/// Asking costs the connection when the answer is no: libssh2 can discard a
/// refused subsystem request only by tearing its session down
/// (`SessionDriver.openSFTP`). So the Host is asked once, and its refusal
/// stands past the connection that met it until the user asks again: Retry
/// in Chat, Check Again in Files, Reconnect on the Host, or a file they
/// attach. A Transport that kept the refusal to itself was replaced along
/// with it, the next one asked again, and a Chat left open on such a Host
/// replaced the Host's connection every few seconds (#596).
final class HostSFTPRefusal: Sendable {
    private let refused = Mutex(false)

    /// Whether the Host refused and has not been asked again since.
    var stands: Bool { refused.withLock { $0 } }

    /// The user asked again, so the next SFTP open goes to the Host.
    func forget() { refused.withLock { $0 = false } }

    /// Opens an SFTP channel with `open` and keeps the Host's answer. While
    /// the refusal stands, `open` is not run and this fails as the refused
    /// open did. `again` is the user asking: the Host is asked whatever it
    /// answered before.
    func asking<Channel: Sendable>(
        again: Bool = false, _ open: @Sendable () async throws -> Channel
    ) async throws -> Channel {
        if stands, !again { throw SSHError.sftpUnavailable }
        do {
            let channel = try await open()
            forget()
            return channel
        } catch SSHError.sftpUnavailable {
            refused.withLock { $0 = true }
            throw SSHError.sftpUnavailable
        }
    }
}

/// Every Host's answer, for as long as the app runs. Connections to one Host
/// share its answer, whichever Server or route they are for.
final class HostSFTPRefusals: Sendable {
    static let shared = HostSFTPRefusals()

    private let byHost = Mutex<[HostMachine.Connection: HostSFTPRefusal]>([:])

    func refusal(for host: HostMachine.Connection) -> HostSFTPRefusal {
        byHost.withLock { refusals in
            if let known = refusals[host] { return known }
            let refusal = HostSFTPRefusal()
            refusals[host] = refusal
            return refusal
        }
    }
}
