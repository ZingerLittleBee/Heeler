import Foundation
import HeelerSSH

/// Removes the account shell's startup output before a Windows JSON stream.
/// NoProfile applies to our child PowerShell, not sshd's outer DefaultShell.
actor BootstrappedExecChannel: WindowsTerminalExecChannel {
    private let channel: any WindowsTerminalExecChannel
    private var pending = Data()
    private var admitted = Data()
    private var ready = false
    private let marker: Data
    private let lfMarker: Data
    private let startupFailure: String

    init(
        channel: any WindowsTerminalExecChannel,
        marker: String = PowerShellCommand.streamMarker,
        startupFailure: String = "The Windows herdr command exited before starting its stream"
    ) {
        self.channel = channel
        self.marker = Data((marker + "\r\n").utf8)
        lfMarker = Data((marker + "\n").utf8)
        self.startupFailure = startupFailure
    }

    func write(_ data: Data, timeout: Duration) async throws {
        try await channel.write(data, timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        guard maximumBytes > 0 else { throw SSHError.channelFailed }
        if !admitted.isEmpty { return takeAdmitted(maximumBytes: maximumBytes) }
        if ready { return try await channel.read(maximumBytes: maximumBytes, timeout: timeout) }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if let range = pending.range(of: marker) ?? pending.range(of: lfMarker) {
                ready = true
                admitted = Data(pending[range.upperBound...])
                pending.removeAll()
                if !admitted.isEmpty { return takeAdmitted(maximumBytes: maximumBytes) }
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw SSHError.timedOut }
            if ready {
                return try await channel.read(maximumBytes: maximumBytes, timeout: remaining)
            }
            guard let bytes = try await channel.read(maximumBytes: maximumBytes, timeout: remaining) else {
                throw TransportError.channelFailed(
                    detail: startupFailure)
            }
            pending.append(bytes)
            // Search before discarding chatter: one real SSH read can contain
            // both the marker and a first JSON frame larger than this tail.
            if pending.count > 8192,
                pending.range(of: marker) == nil, pending.range(of: lfMarker) == nil
            {
                pending = Data(pending.suffix(8192))
            }
        }
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        try await channel.exitStatus(timeout: timeout)
    }

    func close(timeout: Duration) async throws {
        try await channel.close(timeout: timeout)
    }

    private func takeAdmitted(maximumBytes: Int) -> Data {
        let bytes = Data(admitted.prefix(maximumBytes))
        admitted.removeFirst(bytes.count)
        return bytes
    }
}
