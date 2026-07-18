import Testing

@testable import HerdrMobile

// Pure path computation; resolving the home directory itself is exercised
// end-to-end in SSHTransportE2ETests.
@Suite struct HerdrSocketLocationTests {
    @Test func defaultSessionLivesUnderConfigDir() {
        let path = HerdrSocketLocation.defaultSession.path(homeDirectory: "/home/u")

        #expect(path == "/home/u/.config/herdr/herdr.sock")
    }

    @Test func namedSessionLivesUnderSessionsDir() {
        let path = HerdrSocketLocation.namedSession("work").path(homeDirectory: "/home/u")

        #expect(path == "/home/u/.config/herdr/sessions/work/herdr.sock")
    }

    @Test func absolutePathIgnoresHomeDirectory() {
        let path = HerdrSocketLocation.absolutePath("/tmp/custom.sock")
            .path(homeDirectory: "/home/u")

        #expect(path == "/tmp/custom.sock")
    }

    @Test func trailingSlashOnHomeDoesNotDoubleTheSeparator() {
        let path = HerdrSocketLocation.defaultSession.path(homeDirectory: "/home/u/")

        #expect(path == "/home/u/.config/herdr/herdr.sock")
    }
}
