import Foundation
import HeelerSSH

/// The byte-stream boundary of herdr's non-PTY terminal controller.
protocol WindowsTerminalExecChannel: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func exitStatus(timeout: Duration) async throws -> Int32
    func close(timeout: Duration) async throws
}

extension SSHExecChannel: WindowsTerminalExecChannel {}

/// Adapts herdr's Windows-compatible terminal session controller to Attach.
/// Its frames are rendered viewports, rather than the pane's original output.
/// The virtual screen advertises SGR mouse input, which this adapter converts
/// to semantic commands so herdr can consult the actual pane's terminal modes.
actor WindowsTerminalChannel: HeelerSSHAttachChannel {
    // herdr 0.9.3 permits 32 MiB client frames, including inline graphics.
    // Base64 expands that payload by 4/3; the allowance covers JSON metadata.
    static let maximumRecordBytes = ((32 * 1024 * 1024 + 2) / 3) * 4 + 4_096
    // The controller interprets a complete bracketed paste semantically and
    // encodes it for the actual pane, including panes that do not enable 2004.
    static let screenStart = Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h".utf8)
    static let screenEnd = Data("\u{1B}[?2004l\u{1B}[?1006l\u{1B}[?1000l\u{1B}[?1049l".utf8)

    private let channel: any WindowsTerminalExecChannel
    private let maximumRecordBytes: Int
    private var pending = Data()
    private var decoded = Data()
    private var lastSequence: UInt64?
    private var ended = false
    private var reachedEOF = false
    private var failure: TransportError?
    private var closed = false

    init(
        channel: any WindowsTerminalExecChannel,
        maximumRecordBytes: Int = WindowsTerminalChannel.maximumRecordBytes
    ) {
        self.channel = channel
        self.maximumRecordBytes = max(1, maximumRecordBytes)
    }

    func write(_ data: Data, timeout: Duration) async throws {
        guard !ended, !closed else { throw SSHError.channelFailed }
        guard !data.isEmpty else { return }
        let commands = try WindowsTerminalCommandCodec.input(data)
        try await channel.write(commands, timeout: timeout)
    }

    func resize(columns: Int, rows: Int, timeout: Duration) async throws {
        guard !ended, !closed else { throw SSHError.channelFailed }
        guard (1...Int(UInt16.max)).contains(columns),
            (1...Int(UInt16.max)).contains(rows)
        else {
            throw TransportError.channelFailed(detail: String(localized: "invalid terminal controller geometry"))
        }
        try await channel.write(
            try WindowsTerminalCommandCodec.record(
                ["type": "terminal.resize", "cols": columns, "rows": rows]),
            timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        guard maximumBytes > 0 else { throw SSHError.channelFailed }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if !decoded.isEmpty {
                let bytes = Data(decoded.prefix(maximumBytes))
                decoded.removeFirst(bytes.count)
                return bytes
            }
            if let failure { throw failure }
            if ended || closed { return nil }

            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard line.count <= maximumRecordBytes else {
                    throw recordFailure(String(localized: "terminal controller record exceeded its size limit"))
                }
                try decode(line)
                continue
            }
            guard pending.count <= maximumRecordBytes else {
                throw recordFailure(String(localized: "terminal controller record exceeded its size limit"))
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw SSHError.timedOut }
            // Keep incomplete records across a normal read timeout. The SSH
            // channel owns cancellation and reclamation of native operations.
            guard let bytes = try await channel.read(
                maximumBytes: min(16 * 1024, maximumRecordBytes - pending.count + 1),
                timeout: remaining)
            else {
                guard pending.isEmpty else {
                    throw recordFailure(String(localized: "terminal controller ended inside a JSON record"))
                }
                ended = true
                reachedEOF = true
                if lastSequence != nil { decoded = Self.screenEnd }
                continue
            }
            pending.append(bytes)
        }
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // terminal.closed is an application record, not SSH EOF. The package
        // only accepts exitStatus after a real read has observed remote EOF.
        while !reachedEOF {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw SSHError.timedOut }
            if try await channel.read(maximumBytes: 16 * 1024, timeout: remaining) == nil {
                reachedEOF = true
            }
        }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw SSHError.timedOut }
        let status = try await channel.exitStatus(timeout: remaining)
        // herdr exits successfully after forwarding terminal.closed, even
        // when its reason describes a rejected target or lost ownership.
        return status == 0 && failure != nil ? 1 : status
    }

    func close(timeout: Duration) async throws {
        guard !closed else { return }
        closed = true
        if !ended {
            try? await channel.write(
                try WindowsTerminalCommandCodec.record(["type": "terminal.release"]),
                timeout: timeout)
        }
        try await channel.close(timeout: timeout)
    }

    private func decode(_ line: Data) throws {
        if line.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { return }
        let header: TerminalRecordHeader
        do {
            header = try JSONDecoder().decode(TerminalRecordHeader.self, from: line)
        } catch {
            throw recordFailure(String(localized: "invalid terminal controller JSON record"))
        }
        switch header.type {
        case "terminal.frame":
            guard let record = try? JSONDecoder().decode(TerminalFrameRecord.self, from: line) else {
                throw recordFailure(String(localized: "invalid terminal controller frame"))
            }
            guard record.encoding == "ansi", let sequence = record.seq, sequence > 0,
                let width = record.width, (1...Int(UInt16.max)).contains(width),
                let height = record.height, (1...Int(UInt16.max)).contains(height),
                let full = record.full, let encoded = record.bytes,
                let bytes = Data(base64Encoded: encoded)
            else {
                throw recordFailure(String(localized: "invalid terminal controller frame"))
            }
            if let previous = lastSequence {
                guard sequence > previous, full || sequence - previous == 1 else {
                    throw recordFailure(String(localized: "terminal controller frame sequence is incomplete"))
                }
            } else {
                guard full else {
                    throw recordFailure(String(localized: "terminal controller started with a partial frame"))
                }
                decoded.append(AttachBootstrapHandshake.marker)
                decoded.append(Self.screenStart)
            }
            lastSequence = sequence
            decoded.append(bytes)
        case "terminal.closed":
            guard let record = try? JSONDecoder().decode(TerminalClosedRecord.self, from: line) else {
                throw recordFailure(String(localized: "invalid terminal controller close record"))
            }
            ended = true
            let reason = record.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty, reason != "detached" {
                failure = .channelFailed(detail: String(localized: "terminal controller: \(reason)"))
            } else if lastSequence == nil {
                failure = .channelFailed(detail: String(localized: "terminal controller closed before its first frame"))
            }
            if lastSequence != nil { decoded.append(Self.screenEnd) }
        default:
            // Future controller metadata does not change the ANSI wire stream.
            break
        }
    }

    private func recordFailure(_ detail: String) -> TransportError {
        let error = TransportError.channelFailed(detail: detail)
        failure = error
        return error
    }

    private struct TerminalRecordHeader: Decodable {
        let type: String
    }

    private struct TerminalFrameRecord: Decodable {
        let seq: UInt64?
        let encoding: String?
        let width: Int?
        let height: Int?
        let full: Bool?
        let bytes: String?
    }

    private struct TerminalClosedRecord: Decodable {
        let reason: String?
    }
}

/// Controller records always encode arbitrary terminal bytes as base64.
/// A complete SGR mouse report instead uses herdr's semantic input, so a plain
/// shell never receives an escape sequence merely because this viewport made
/// mouse scrolling available to the client.
enum WindowsTerminalCommandCodec {
    static func input(_ bytes: Data) throws -> Data {
        if let reports = mouseReports(bytes) {
            return try reports.reduce(into: Data()) { $0.append(try record($1)) }
        }
        return try record(["type": "terminal.input", "bytes": bytes.base64EncodedString()])
    }

    static func record(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        data.append(0x0A)
        return data
    }

    private static func mouseReports(_ bytes: Data) -> [[String: Any]]? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        var tail = text[...]
        var commands: [[String: Any]] = []
        while !tail.isEmpty {
            guard tail.hasPrefix("\u{1B}[<") else { return nil }
            tail = tail.dropFirst(3)
            guard let end = tail.firstIndex(where: { $0 == "M" || $0 == "m" }) else { return nil }
            let values = tail[..<end].split(separator: ";", omittingEmptySubsequences: false)
            guard values.count == 3,
                let button = Int(values[0]), (0...127).contains(button),
                let column = Int(values[1]), (1...Int(UInt16.max)).contains(column),
                let row = Int(values[2]), (1...Int(UInt16.max)).contains(row)
            else { return nil }
            let release = tail[end] == "m"
            tail = tail[tail.index(after: end)...]
            let modifiers = (button & 4 != 0 ? 1 : 0)
                | (button & 8 != 0 ? 4 : 0)
                | (button & 16 != 0 ? 2 : 0)
            if button & 64 != 0 {
                guard !release, button & 3 < 2 else { return nil }
                commands.append([
                    "type": "terminal.scroll", "direction": button & 1 == 0 ? "up" : "down",
                    "lines": 1, "source": "wheel", "column": column - 1, "row": row - 1,
                    "modifiers": modifiers,
                ])
            } else {
                let index = button & 3
                guard index < 3 else { return nil }
                let action = release ? "up" : button & 32 != 0 ? "drag" : "down"
                commands.append([
                    "type": "terminal.mouse", "action": action,
                    "button": ["left", "middle", "right"][index],
                    "column": column - 1, "row": row - 1, "modifiers": modifiers,
                ])
            }
        }
        return commands.isEmpty ? nil : commands
    }
}
