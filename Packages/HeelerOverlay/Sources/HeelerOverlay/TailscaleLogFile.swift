import Darwin
import Foundation

/// Keeps tsnet's own log lines in a file, each prefixed with the time it was
/// read.
///
/// tsnet writes bare lines to the descriptor `tailscale_set_logfd` is given,
/// and a stalled shutdown is only diagnosable against the device log's
/// timeline (#474), so the descriptor is the write end of a pipe and a
/// dedicated thread stamps and appends what arrives. The Go side owns the
/// write end from then on. libtailscale never closes it explicitly; Go's
/// finalizer does once the closed server is garbage collected, which ends
/// the thread, so a node's thread can outlive it until the next collection.
enum TailscaleLogFile {
    /// A file past this size is moved aside to `<name>.1` (replacing any
    /// older one) before the next node starts writing.
    static let rotationSize = 4 << 20

    /// The write end for `tailscale_set_logfd`, or -1 to discard the lines
    /// when the file or the pipe cannot be opened.
    static func open(_ url: URL) -> Int32 {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfLarge(url)
        let file = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard file >= 0 else { return -1 }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            Darwin.close(file)
            return -1
        }
        let readEnd = ends[0]
        let thread = Thread { pump(from: readEnd, to: file) }
        thread.name = "dev.bybee.heeler.overlay.tailscale.log"
        thread.start()
        return ends[1]
    }

    /// Copies lines from `source` to `file` until the writer closes,
    /// stamping each complete line; a line still open at the end is written
    /// as it is.
    static func pump(from source: Int32, to file: Int32) {
        defer {
            Darwin.close(source)
            Darwin.close(file)
        }
        // Local time, like `log show`, so lines line up with the device log.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS "
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: chunk[..<count])
            var stamped = Data()
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                stamped.append(contentsOf: Array(formatter.string(from: .now).utf8))
                stamped.append(pending[pending.startIndex...newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
            write(stamped, to: file)
        }
        if !pending.isEmpty {
            write(Data(formatter.string(from: .now).utf8) + pending + Data("\n".utf8), to: file)
        }
    }

    private static func write(_ data: Data, to file: Int32) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, base + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    private static func rotateIfLarge(_ url: URL) {
        let manager = FileManager.default
        guard
            let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
            size > rotationSize
        else { return }
        let previous = url.appendingPathExtension("1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
    }
}
