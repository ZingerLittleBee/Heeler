import HeelerSSH
import Testing

@Suite("HeelerSSH Native Runtime")
struct HeelerSSHNativeRuntimeTests {
    @Test("libssh2 initializes at runtime")
    func initializesLibSSH2() {
        #expect(NativeRuntime.smokeTest())
    }
}
