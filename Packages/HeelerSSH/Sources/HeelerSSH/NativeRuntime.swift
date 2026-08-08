import CLibSSH2

public enum NativeRuntime {
    public static func smokeTest() -> Bool {
        NativeLibrary.initializationResult == 0
    }
}
