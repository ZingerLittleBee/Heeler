import CLibSSH2

public enum NativeRuntime {
    public static func smokeTest() -> Bool {
        guard libssh2_init(0) == 0 else {
            return false
        }

        libssh2_exit()
        return true
    }
}
