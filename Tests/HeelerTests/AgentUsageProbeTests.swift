import Foundation
import Testing

@testable import Heeler

@Suite("Agent Usage probe")
struct AgentUsageProbeTests {
    @Test("usage rejects invalid time zones before building a shell script")
    func invalidTimeZoneIsRejected() throws {
        #expect(throws: (any Error).self) {
            try AgentUsageProbe.script(
                pluginRoot: "/plugins/heeler", timeZone: "UTC'; touch /tmp/injected; '",
                claudeLimits: false, nonce: "test", launcher: nil)
        }
    }

    @Test("usage accepts only its complete nonce-framed response")
    func nonceMarkersBoundTheResponse() throws {
        let json = #"{"version":1,"runtime":"missing"}"#
        let valid = "shell noise\n__HEELER_USAGE_BEGIN_test\n\(json)\n__HEELER_USAGE_END_test:0\nnoise"
        let report = try AgentUsageProbe.parse(stdout: Data(valid.utf8), nonce: "test")
        #expect(report.runtime == "missing")
        for invalid in [json, valid.replacingOccurrences(of: "END_test", with: "END_other"),
                        valid.replacingOccurrences(of: "END_test:0", with: "END_test:1")] {
            #expect(throws: (any Error).self) {
                try AgentUsageProbe.parse(stdout: Data(invalid.utf8), nonce: "test")
            }
        }
    }
}
