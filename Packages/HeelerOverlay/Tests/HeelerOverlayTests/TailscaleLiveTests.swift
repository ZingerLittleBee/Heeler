import Foundation
import Testing

@testable import HeelerOverlay

/// Starts a real tsnet node without an auth key against Tailscale's
/// coordination server and expects the interactive-login URL. Needs Internet
/// access, so it only runs with `HEELER_OVERLAY_LIVE=1`.
@Suite(
    "Tailscale live node",
    .enabled(if: ProcessInfo.processInfo.environment["HEELER_OVERLAY_LIVE"] == "1"))
struct TailscaleLiveTests {
    @Test(.timeLimit(.minutes(2)))
    func nodeWithoutAuthKeyAsksForLogin() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsnet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = OverlayNodes.tailscale(
            TailscaleConfiguration(
                stateDirectory: directory, hostname: "heeler-test", authKey: nil, controlURL: nil))

        #expect(LiveTailscaleNative.logUploadDisabled)
        do {
            try await node.start(timeout: .seconds(60))
            Issue.record("a fresh node without an auth key came online")
        } catch OverlayError.loginRequired(let url) {
            #expect(url.scheme == "https")
            #expect(await node.status() == .needsLogin(url))
        }
        // tsnet buffers log lines for upload in tailscaled.log*.txt under the
        // state directory; with upload disabled nothing is ever buffered.
        let buffered = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("tailscaled.log") && $0.hasSuffix(".txt") }
            .map { directory.appendingPathComponent($0) }
            .reduce(0) { total, file in
                total + ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
            }
        #expect(buffered == 0, "tsnet buffered \(buffered) bytes of logs for upload")
        // Never logged in: LocalAPI's logout has no node key to drop, so it
        // succeeds, and the state directory is left empty.
        try await node.logout(timeout: .seconds(30))
        #expect(await node.status() == .stopped)
        #expect(await node.details() == OverlayNodeDetails())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
