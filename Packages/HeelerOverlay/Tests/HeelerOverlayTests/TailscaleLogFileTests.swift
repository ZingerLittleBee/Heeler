import Darwin
import Foundation
import Testing

@testable import HeelerOverlay

@Suite("Tailscale log file")
struct TailscaleLogFileTests {
    /// tsnet writes bare lines, sometimes split across writes; each one
    /// lands on its own line behind a local timestamp, and a last line the
    /// writer never ended is still kept.
    @Test func stampsEveryLineAndKeepsAnUnfinishedOne() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscale-log-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("node.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = TailscaleLogFile.open(url)
        try #require(writer >= 0)
        for part in ["netcheck: report", ": udp=false\nmagicsock: ", "closing\nclient.Shutdown ..."] {
            _ = part.withCString { Darwin.write(writer, $0, strlen($0)) }
        }
        Darwin.close(writer)

        let lines = try waitForLines(in: url, count: 3)
        let stamp = #/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} /#
        #expect(lines.allSatisfy { $0.contains(stamp) })
        #expect(
            lines.map { $0.replacing(stamp, with: "") }
                == ["netcheck: report: udp=false", "magicsock: closing", "client.Shutdown ..."])
    }

    /// The pump runs on its own thread and finishes once the writer closes.
    private func waitForLines(in url: URL, count: Int) throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(5)
        var lines: [String] = []
        while ContinuousClock.now < deadline {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            lines = text.split(separator: "\n").map(String.init)
            if lines.count >= count { break }
            usleep(10_000)
        }
        return lines
    }
}
