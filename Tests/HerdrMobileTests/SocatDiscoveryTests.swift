import Foundation
import Testing

@testable import HerdrMobile

// The probe command's shape, pinned without sshd: CI provisions none, so every
// e2e test covering discovery skips there. Real-shell behavior (fish login
// shell, POSIX sh probe, the fall-through cases) is covered by
// SSHTransportE2ETests and TransportFailureModesE2ETests.
@Suite("socat discovery probe")
struct SocatDiscoveryTests {
    private func probe(
        _ preferredPath: String, _ discovery: SocatDiscovery = .automatic
    ) -> String {
        SSHTransport.socatProbeCommand(preferredPath: preferredPath, discovery: discovery)
    }

    @Test func runsUnderPOSIXShellWithAStableLocale() {
        let command = probe("/usr/bin/socat")

        // Login shells do not share substitution syntax, and error
        // classification downstream must not shift with the Host's locale.
        #expect(command.hasPrefix("LC_ALL=C /bin/sh -c '"))
    }

    @Test func passesThePreferredPathAsAQuotedArgument() {
        let command = probe("/opt/homebrew/bin/socat")

        // Trailing arguments, not interpolation into the script body.
        #expect(command.hasSuffix(" herdr-socat-probe '/opt/homebrew/bin/socat' 1"))
    }

    @Test func automaticDiscoverySearchesPath() {
        #expect(probe("/usr/bin/socat", .automatic).hasSuffix(" 1"))
        #expect(probe("/usr/bin/socat", .automatic).contains("command -v socat"))
    }

    @Test func configuredPathOnlyDoesNotSearchPath() {
        let command = probe("/usr/bin/socat", .configuredPathOnly)

        // The flag is what disables the lookup; the branch stays in the script
        // so both policies run byte-identical shell code.
        #expect(command.hasSuffix(" '/usr/bin/socat' 0"))
    }

    @Test func emitsTheMarkerTheParserLooksFor() {
        #expect(probe("/usr/bin/socat").contains("__HERDR_MOBILE_SOCAT__=%s"))
    }

    @Test(arguments: [
        "/tmp/socat'; rm -rf ~; echo '",
        "/tmp/back\\slash",
        "/tmp/new\nline",
        "relative/socat",
        "",
    ])
    func unquotablePreferredPathIsNeverInterpolated(hostile: String) {
        let command = probe(hostile)

        // A path the quoting subset refuses is replaced by an empty argument,
        // which `[ -x ]` rejects. The dangerous text must not reach the Host at
        // all — not even inside quotes.
        #expect(command.hasSuffix(" herdr-socat-probe '' 1"))
        #expect(!command.contains(hostile) || hostile.isEmpty)
    }

    @Test func quotedPathsWithSpacesSurvive() {
        // Spaces are inside the conservative subset: single quotes handle them
        // identically in POSIX shells and fish.
        let command = probe("/opt/my tools/socat")

        #expect(command.hasSuffix(" herdr-socat-probe '/opt/my tools/socat' 1"))
    }
}
