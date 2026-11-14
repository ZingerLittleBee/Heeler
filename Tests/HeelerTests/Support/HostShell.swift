import Darwin
import Foundation

/// Runs a program on the Mac the Simulator runs on, for tests that hand the
/// scripts Heeler sends a Host to a real `/bin/sh`.
enum HostShell {
    enum Failure: Error, CustomStringConvertible {
        case spawn(Int32)
        case wait
        case signal(Int32)

        var description: String {
            switch self {
            case .spawn(let code): "posix_spawn failed (\(code))"
            case .wait: "waitpid failed"
            case .signal(let raw): "ended by signal (\(raw & 0x7f))"
            }
        }
    }

    /// The program's exit status. `environment` is laid over the test's own.
    static func run(_ program: String, arguments: [String], environment: [String: String] = [:]) throws -> Int32 {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        var pid: pid_t = 0
        let code = try withCStrings([program] + arguments) { argv in
            try withCStrings(merged.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, program, nil, nil, argv, envp)
            }
        }
        guard code == 0 else { throw Failure.spawn(code) }
        var raw: Int32 = 0
        guard waitpid(pid, &raw, 0) == pid else { throw Failure.wait }
        guard raw & 0x7f == 0 else { throw Failure.signal(raw) }
        return (raw >> 8) & 0xff
    }

    private static func withCStrings(
        _ values: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> Int32
    ) throws -> Int32 {
        let allocated: [UnsafeMutablePointer<CChar>] = try values.map { value in
            try value.withCString { pointer in
                guard let copy = strdup(pointer) else { throw Failure.spawn(Int32(ENOMEM)) }
                return copy
            }
        }
        defer { allocated.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = allocated
        pointers.append(nil)
        return try pointers.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw Failure.spawn(Int32(EINVAL)) }
            return try body(base)
        }
    }
}
