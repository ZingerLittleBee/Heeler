//! Root module of libheeler_jni.so: re-exports every JNI bridge.
//! Symbol visibility is controlled by version-script.map (Java_* only).

pub const terminal = @import("heeler_terminal.zig");
pub const ssh = @import("heeler_ssh.zig");

comptime {
    _ = terminal;
    _ = ssh;
}
