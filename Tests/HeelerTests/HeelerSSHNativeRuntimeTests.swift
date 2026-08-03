import HeelerSSH
import Testing

@Suite("HeelerSSH Native Runtime")
struct HeelerSSHNativeRuntimeTests {
    @Test("libssh2 initializes and frees at runtime")
    func initializesAndFreesLibSSH2() {
        #expect(NativeRuntime.smokeTest())
    }
}
