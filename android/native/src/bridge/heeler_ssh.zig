//! Nonblocking libssh2 JNI bridge for the Kotlin SSH driver.
//!
//! JNI/libssh2 plumbing and Android socket patterns are adapted from chuchu
//! (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.

const std = @import("std");

const c = @cImport({
    @cInclude("jni.h");
    @cInclude("libssh2.h");
    @cInclude("libssh2_sftp.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/types.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
});

const allocator = std.heap.c_allocator;
const AGAIN: c_int = c.LIBSSH2_ERROR_EAGAIN;
const max_bridge_buffer_bytes = 64 * 1024;
const bridge_chunk_bytes = 8 * 1024;

const BridgeBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    head: usize = 0,

    fn deinit(self: *BridgeBuffer) void {
        self.bytes.deinit(allocator);
    }

    fn pending(self: *const BridgeBuffer) []const u8 {
        return self.bytes.items[self.head..];
    }

    fn clearConsumed(self: *BridgeBuffer) void {
        if (self.head == 0) return;
        if (self.head == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        if (self.head < 4096 and self.head * 2 < self.bytes.items.len) return;
        const remainder = self.bytes.items[self.head..];
        std.mem.copyForwards(u8, self.bytes.items[0..remainder.len], remainder);
        self.bytes.items.len = remainder.len;
        self.head = 0;
    }

    fn append(self: *BridgeBuffer, input: []const u8) !void {
        self.clearConsumed();
        try self.bytes.appendSlice(allocator, input);
    }

    fn consume(self: *BridgeBuffer, count: usize) void {
        self.head += count;
        self.clearConsumed();
    }
};

const ChannelBridge = struct {
    relay_fd: c_int,
    to_channel: BridgeBuffer = .{},
    to_relay: BridgeBuffer = .{},
    peer_closed: bool = false,
    sent_eof: bool = false,

    fn deinit(self: *ChannelBridge) void {
        if (self.relay_fd >= 0) _ = c.close(self.relay_fd);
        self.relay_fd = -1;
        self.to_channel.deinit();
        self.to_relay.deinit();
    }
};

const ChannelEntry = struct {
    channel: *c.LIBSSH2_CHANNEL,
    bridge: ?ChannelBridge = null,
    closed: bool = false,
};

const SftpEntry = struct {
    sftp: *c.LIBSSH2_SFTP,
    file_ids: std.AutoHashMapUnmanaged(u64, void) = .empty,
};

const SftpFileEntry = struct {
    file: *c.LIBSSH2_SFTP_HANDLE,
    sftp_id: u64,
};

const NativeSession = struct {
    session: *c.LIBSSH2_SESSION,
    socket_fd: c_int = -1,
    last_errno: c_int = 0,
    last_error: std.ArrayListUnmanaged(u8) = .empty,
    next_child_id: u64 = 1,
    channels: std.AutoHashMapUnmanaged(u64, *ChannelEntry) = .empty,
    sftps: std.AutoHashMapUnmanaged(u64, *SftpEntry) = .empty,
    files: std.AutoHashMapUnmanaged(u64, *SftpFileEntry) = .empty,
};

var init_mutex: std.Thread.Mutex = .{};
var libssh2_initialized = false;
var registry_mutex: std.Thread.Mutex = .{};
var next_session_id: u64 = 1;
var sessions: std.AutoHashMapUnmanaged(u64, *NativeSession) = .empty;

fn ensureLibssh2Initialized() bool {
    init_mutex.lock();
    defer init_mutex.unlock();
    if (libssh2_initialized) return true;
    if (c.libssh2_init(0) != 0) return false;
    libssh2_initialized = true;
    return true;
}

fn sessionFromHandle(handle: c.jlong) ?*NativeSession {
    const key: u64 = @bitCast(handle);
    if (key == 0) return null;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    return sessions.get(key);
}

fn allocateChildId(session: *NativeSession) u64 {
    const id = session.next_child_id;
    session.next_child_id +%= 1;
    if (session.next_child_id == 0) session.next_child_id = 1;
    return id;
}

fn setError(session: *NativeSession, comptime format: []const u8, args: anytype) void {
    session.last_error.clearRetainingCapacity();
    std.fmt.format(session.last_error.writer(allocator), format, args) catch {};
}

fn clearError(session: *NativeSession) void {
    session.last_errno = 0;
    session.last_error.clearRetainingCapacity();
}

fn setLibssh2Error(session: *NativeSession, context: []const u8, result: c_int) void {
    session.last_errno = result;
    var message_ptr: [*c]const u8 = null;
    var message_len: c_int = 0;
    _ = c.libssh2_session_last_error(session.session, @ptrCast(&message_ptr), &message_len, 0);
    if (message_ptr != null and message_len > 0) {
        setError(session, "{s}: {s} (rc={d})", .{ context, message_ptr[0..@intCast(message_len)], result });
    } else {
        setError(session, "{s}: libssh2 rc={d}", .{ context, result });
    }
}

fn recordResult(session: *NativeSession, context: []const u8, result: c_int) c_int {
    if (result == 0) {
        clearError(session);
    } else if (result == AGAIN) {
        session.last_errno = AGAIN;
    } else if (result < 0) {
        setLibssh2Error(session, context, result);
    } else {
        clearError(session);
    }
    return result;
}

fn recordPointerFailure(session: *NativeSession, context: []const u8) void {
    const result = c.libssh2_session_last_errno(session.session);
    if (result == AGAIN) {
        session.last_errno = AGAIN;
    } else {
        setLibssh2Error(session, context, result);
    }
}

fn errnoValue() c_int {
    return c.__errno().*;
}

fn recordErrno(session: *NativeSession, context: []const u8) c_int {
    const result = -errnoValue();
    session.last_errno = result;
    setError(session, "{s}: errno={d}", .{ context, -result });
    return result;
}

fn closeSocket(fd: c_int) void {
    if (fd >= 0) _ = c.close(fd);
}

fn setSocketNonblocking(fd: c_int) bool {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    return c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) == 0;
}

fn closeChannelEntry(entry: *ChannelEntry) void {
    if (entry.bridge) |*bridge| bridge.deinit();
    _ = c.libssh2_channel_free(entry.channel);
    allocator.destroy(entry);
}

fn closeSftpFileEntry(entry: *SftpFileEntry) void {
    _ = c.libssh2_sftp_close_handle(entry.file);
    allocator.destroy(entry);
}

fn closeSftpEntry(entry: *SftpEntry) void {
    _ = c.libssh2_sftp_shutdown(entry.sftp);
    entry.file_ids.deinit(allocator);
    allocator.destroy(entry);
}

fn destroySession(session: *NativeSession) void {
    var file_iterator = session.files.valueIterator();
    while (file_iterator.next()) |entry| closeSftpFileEntry(entry.*);
    session.files.deinit(allocator);

    var sftp_iterator = session.sftps.valueIterator();
    while (sftp_iterator.next()) |entry| closeSftpEntry(entry.*);
    session.sftps.deinit(allocator);

    var channel_iterator = session.channels.valueIterator();
    while (channel_iterator.next()) |entry| closeChannelEntry(entry.*);
    session.channels.deinit(allocator);

    _ = c.libssh2_session_disconnect_ex(session.session, c.SSH_DISCONNECT_BY_APPLICATION, "Heeler disconnect", "en");
    _ = c.libssh2_session_free(session.session);
    closeSocket(session.socket_fd);
    session.last_error.deinit(allocator);
    allocator.destroy(session);
}

fn registerChannel(session: *NativeSession, channel: *c.LIBSSH2_CHANNEL) c.jlong {
    const entry = allocator.create(ChannelEntry) catch {
        _ = c.libssh2_channel_free(channel);
        session.last_errno = -c.ENOMEM;
        setError(session, "channel registry allocation failed", .{});
        return 0;
    };
    entry.* = .{ .channel = channel };
    const id = allocateChildId(session);
    session.channels.put(allocator, id, entry) catch {
        closeChannelEntry(entry);
        session.last_errno = -c.ENOMEM;
        setError(session, "channel registry allocation failed", .{});
        return 0;
    };
    clearError(session);
    return @bitCast(id);
}

fn channelFromHandle(session: *NativeSession, handle: c.jlong) ?*ChannelEntry {
    const id: u64 = @bitCast(handle);
    if (id == 0) return null;
    return session.channels.get(id);
}

fn sftpFromHandle(session: *NativeSession, handle: c.jlong) ?*SftpEntry {
    const id: u64 = @bitCast(handle);
    if (id == 0) return null;
    return session.sftps.get(id);
}

fn fileFromHandle(session: *NativeSession, handle: c.jlong) ?*SftpFileEntry {
    const id: u64 = @bitCast(handle);
    if (id == 0) return null;
    return session.files.get(id);
}

fn jniNewString(env: *c.JNIEnv, bytes: []const u8) c.jstring {
    const z = allocator.allocSentinel(u8, bytes.len, 0) catch return null;
    defer allocator.free(z);
    @memcpy(z[0..bytes.len], bytes);
    return env.*.*.NewStringUTF.?(env, z.ptr);
}

fn jniNewStringOrNull(env: *c.JNIEnv, bytes: []const u8) c.jstring {
    if (bytes.len == 0) return null;
    return jniNewString(env, bytes);
}

fn jniNewByteArray(env: *c.JNIEnv, bytes: []const u8) c.jbyteArray {
    const array = env.*.*.NewByteArray.?(env, @intCast(bytes.len));
    if (array == null) return null;
    if (bytes.len > 0) {
        env.*.*.SetByteArrayRegion.?(env, array, 0, @intCast(bytes.len), @ptrCast(bytes.ptr));
    }
    return array;
}

fn hostKeyAlgorithm(host_key: []const u8) []const u8 {
    if (host_key.len < 4) return "";
    const length: usize = (@as(usize, host_key[0]) << 24) |
        (@as(usize, host_key[1]) << 16) |
        (@as(usize, host_key[2]) << 8) |
        @as(usize, host_key[3]);
    if (length == 0 or length > host_key.len - 4) return "";
    return host_key[4 .. 4 + length];
}

fn currentHostKey(session: *NativeSession) ?[]const u8 {
    var length: usize = 0;
    var kind: c_int = 0;
    const pointer = c.libssh2_session_hostkey(session.session, &length, &kind) orelse return null;
    if (length == 0) return null;
    return pointer[0..length];
}

fn waitForConnect(fd: c_int, timeout_ms: c_int) bool {
    var poll_fd: c.struct_pollfd = .{
        .fd = fd,
        .events = c.POLLOUT,
        .revents = 0,
    };
    if (c.poll(&poll_fd, 1, timeout_ms) <= 0) return false;
    var socket_error: c_int = 0;
    var socket_error_size: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &socket_error_size) != 0) return false;
    return socket_error == 0;
}

fn connectToHost(session: *NativeSession, host: [*:0]const u8, port: c.jint, timeout_ms: c.jint) c_int {
    if (session.socket_fd >= 0 or port <= 0 or port > 65535 or timeout_ms < 0) {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid socket connection request", .{});
        return session.last_errno;
    }

    var service: [6]u8 = undefined;
    const service_text = std.fmt.bufPrintZ(&service, "{d}", .{port}) catch {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid SSH port", .{});
        return session.last_errno;
    };
    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;

    var addresses: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(host, service_text.ptr, &hints, &addresses) != 0) {
        session.last_errno = -c.EHOSTUNREACH;
        setError(session, "DNS lookup failed", .{});
        return session.last_errno;
    }
    defer if (addresses) |resolved| c.freeaddrinfo(resolved);

    const started = std.time.milliTimestamp();
    var candidate = addresses;
    while (candidate) |address| : (candidate = address.ai_next) {
        const elapsed = std.time.milliTimestamp() - started;
        const remaining: i64 = @as(i64, timeout_ms) - elapsed;
        if (remaining < 0) break;

        const fd = c.socket(address.ai_family, address.ai_socktype, address.ai_protocol);
        if (fd < 0) continue;
        if (!setSocketNonblocking(fd)) {
            closeSocket(fd);
            continue;
        }
        if (c.connect(fd, address.ai_addr, address.ai_addrlen) == 0) {
            session.socket_fd = fd;
            clearError(session);
            return 0;
        }
        const connect_errno = errnoValue();
        if (connect_errno == c.EINPROGRESS or connect_errno == c.EALREADY) {
            const bounded_wait: c_int = @intCast(@min(remaining, @as(i64, std.math.maxInt(c_int))));
            if (waitForConnect(fd, bounded_wait)) {
                session.socket_fd = fd;
                clearError(session);
                return 0;
            }
        }
        closeSocket(fd);
    }

    session.last_errno = -c.ETIMEDOUT;
    setError(session, "TCP connection timed out", .{});
    return session.last_errno;
}

fn bridgeReceive(bridge: *ChannelBridge) c_int {
    if (bridge.peer_closed or bridge.to_channel.pending().len >= max_bridge_buffer_bytes) return 0;
    var buffer: [bridge_chunk_bytes]u8 = undefined;
    const max_read = @min(buffer.len, max_bridge_buffer_bytes - bridge.to_channel.pending().len);
    const received = c.recv(bridge.relay_fd, @ptrCast(&buffer), max_read, 0);
    if (received > 0) {
        bridge.to_channel.append(buffer[0..@intCast(received)]) catch return -c.ENOMEM;
        return @intCast(received);
    }
    if (received == 0) {
        bridge.peer_closed = true;
        return 0;
    }
    const err = errnoValue();
    if (err == c.EAGAIN or err == c.EWOULDBLOCK) return 0;
    return -err;
}

fn bridgeSend(bridge: *ChannelBridge) c_int {
    const pending = bridge.to_relay.pending();
    if (pending.len == 0) return 0;
    const sent = c.send(bridge.relay_fd, @ptrCast(pending.ptr), pending.len, 0);
    if (sent > 0) {
        bridge.to_relay.consume(@intCast(sent));
        return @intCast(sent);
    }
    if (sent == 0) return 0;
    const err = errnoValue();
    if (err == c.EAGAIN or err == c.EWOULDBLOCK) return 0;
    return -err;
}

fn bridgeWriteChannel(bridge: *ChannelBridge, channel: *c.LIBSSH2_CHANNEL) c_int {
    const pending = bridge.to_channel.pending();
    if (pending.len == 0) return 0;
    const result = c.libssh2_channel_write_ex(channel, 0, @ptrCast(pending.ptr), @intCast(pending.len));
    if (result > 0) {
        bridge.to_channel.consume(@intCast(result));
        return @intCast(result);
    }
    if (result == AGAIN) return 0;
    return @intCast(result);
}

fn bridgeReadChannel(bridge: *ChannelBridge, channel: *c.LIBSSH2_CHANNEL) c_int {
    if (bridge.to_relay.pending().len >= max_bridge_buffer_bytes) return 0;
    var buffer: [bridge_chunk_bytes]u8 = undefined;
    const max_read = @min(buffer.len, max_bridge_buffer_bytes - bridge.to_relay.pending().len);
    const result = c.libssh2_channel_read_ex(channel, 0, @ptrCast(&buffer), @intCast(max_read));
    if (result > 0) {
        bridge.to_relay.append(buffer[0..@intCast(result)]) catch return -c.ENOMEM;
        return @intCast(result);
    }
    if (result == AGAIN or result == 0) return 0;
    return @intCast(result);
}

fn pumpBridge(session: *NativeSession, entry: *ChannelEntry) c_int {
    const bridge = &(entry.bridge orelse {
        session.last_errno = -c.EINVAL;
        setError(session, "channel has no socket bridge", .{});
        return session.last_errno;
    });

    var moved: c_int = 0;
    const first_write = bridgeWriteChannel(bridge, entry.channel);
    if (first_write < 0) return recordResult(session, "socket bridge write to SSH channel failed", first_write);
    moved += first_write;

    const first_send = bridgeSend(bridge);
    if (first_send < 0) return recordResult(session, "socket bridge write to child failed", first_send);
    moved += first_send;

    const received = bridgeReceive(bridge);
    if (received < 0) return recordResult(session, "socket bridge read from child failed", received);
    moved += received;

    const channel_read = bridgeReadChannel(bridge, entry.channel);
    if (channel_read < 0) return recordResult(session, "socket bridge read from SSH channel failed", channel_read);
    moved += channel_read;

    const second_write = bridgeWriteChannel(bridge, entry.channel);
    if (second_write < 0) return recordResult(session, "socket bridge write to SSH channel failed", second_write);
    moved += second_write;

    const second_send = bridgeSend(bridge);
    if (second_send < 0) return recordResult(session, "socket bridge write to child failed", second_send);
    moved += second_send;

    if (bridge.peer_closed and bridge.to_channel.pending().len == 0 and !bridge.sent_eof) {
        const result = c.libssh2_channel_send_eof(entry.channel);
        if (result == 0) {
            bridge.sent_eof = true;
        } else if (result != AGAIN) {
            return recordResult(session, "socket bridge EOF failed", result);
        }
    }
    if (moved > 0) clearError(session);
    return moved;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_version(env: *c.JNIEnv, thiz: c.jobject) callconv(.c) c.jstring {
    _ = thiz;
    const value = c.libssh2_version(0);
    if (value == null) return jniNewString(env, "unknown");
    return jniNewString(env, std.mem.span(value));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sessionNew(env: *c.JNIEnv, thiz: c.jobject) callconv(.c) c.jlong {
    _ = env;
    _ = thiz;
    if (!ensureLibssh2Initialized()) return 0;
    const ssh_session = c.libssh2_session_init_ex(null, null, null, null) orelse return 0;
    c.libssh2_session_set_blocking(ssh_session, 0);
    const native = allocator.create(NativeSession) catch {
        _ = c.libssh2_session_free(ssh_session);
        return 0;
    };
    native.* = .{ .session = ssh_session };

    registry_mutex.lock();
    defer registry_mutex.unlock();
    const id = next_session_id;
    next_session_id +%= 1;
    if (next_session_id == 0) next_session_id = 1;
    sessions.put(allocator, id, native) catch {
        destroySession(native);
        return 0;
    };
    return @bitCast(id);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_connectSocket(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, host: c.jstring, port: c.jint, timeout_ms: c.jint) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const host_chars = env.*.*.GetStringUTFChars.?(env, host, null) orelse {
        session.last_errno = -c.EINVAL;
        setError(session, "missing SSH host", .{});
        return session.last_errno;
    };
    defer env.*.*.ReleaseStringUTFChars.?(env, host, host_chars);
    if (std.mem.span(host_chars).len == 0) {
        session.last_errno = -c.EINVAL;
        setError(session, "missing SSH host", .{});
        return session.last_errno;
    }
    return connectToHost(session, host_chars, port, timeout_ms);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_connectSocketFd(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, fd: c.jint) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse {
        if (fd >= 0) closeSocket(fd);
        return -c.EINVAL;
    };
    if (fd < 0 or session.socket_fd >= 0 or !setSocketNonblocking(fd)) {
        if (fd >= 0) closeSocket(fd);
        session.last_errno = -c.EINVAL;
        setError(session, "invalid forwarded SSH socket", .{});
        return session.last_errno;
    }
    session.socket_fd = fd;
    clearError(session);
    return 0;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_handshake(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    if (session.socket_fd < 0) {
        session.last_errno = -c.ENOTCONN;
        setError(session, "SSH socket is not connected", .{});
        return session.last_errno;
    }
    return recordResult(session, "SSH handshake failed", c.libssh2_session_handshake(session.session, session.socket_fd));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_hostKey(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jbyteArray {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return null;
    const host_key = currentHostKey(session) orelse return null;
    return jniNewByteArray(env, host_key);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_hostKeyType(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jstring {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return null;
    const host_key = currentHostKey(session) orelse return null;
    return jniNewStringOrNull(env, hostKeyAlgorithm(host_key));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_userauthList(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, username: c.jstring) callconv(.c) c.jstring {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return null;
    const username_chars = env.*.*.GetStringUTFChars.?(env, username, null) orelse return null;
    defer env.*.*.ReleaseStringUTFChars.?(env, username, username_chars);
    const username_bytes = std.mem.span(username_chars);
    const methods = c.libssh2_userauth_list(session.session, username_chars, @intCast(username_bytes.len));
    if (methods == null) {
        recordPointerFailure(session, "userauth list failed");
        return null;
    }
    clearError(session);
    return jniNewString(env, std.mem.span(methods));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_userauthPublicKeyFromMemory(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, username: c.jstring, public_key: c.jbyteArray, private_key: c.jbyteArray, passphrase: c.jstring) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const username_chars = env.*.*.GetStringUTFChars.?(env, username, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, username, username_chars);
    const passphrase_chars = env.*.*.GetStringUTFChars.?(env, passphrase, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, passphrase, passphrase_chars);
    const private_bytes = env.*.*.GetByteArrayElements.?(env, private_key, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseByteArrayElements.?(env, private_key, private_bytes, c.JNI_ABORT);
    const private_length = env.*.*.GetArrayLength.?(env, private_key);

    var public_bytes: [*c]c.jbyte = null;
    var public_length: c.jsize = 0;
    if (public_key != null) {
        public_bytes = env.*.*.GetByteArrayElements.?(env, public_key, null) orelse return -c.EINVAL;
        public_length = env.*.*.GetArrayLength.?(env, public_key);
    }
    defer if (public_bytes != null) env.*.*.ReleaseByteArrayElements.?(env, public_key, public_bytes, c.JNI_ABORT);

    const username_length = std.mem.span(username_chars).len;
    const result = c.libssh2_userauth_publickey_frommemory(
        session.session,
        username_chars,
        @intCast(username_length),
        @ptrCast(public_bytes),
        @intCast(public_length),
        @ptrCast(private_bytes),
        @intCast(private_length),
        passphrase_chars,
    );
    return recordResult(session, "public-key authentication failed", result);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_userauthPassword(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, username: c.jstring, password: c.jstring) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const username_chars = env.*.*.GetStringUTFChars.?(env, username, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, username, username_chars);
    const password_chars = env.*.*.GetStringUTFChars.?(env, password, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, password, password_chars);
    return recordResult(session, "password authentication failed", c.libssh2_userauth_password_ex(
        session.session,
        username_chars,
        @intCast(std.mem.span(username_chars).len),
        password_chars,
        @intCast(std.mem.span(password_chars).len),
        null,
    ));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_isAuthenticated(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jboolean {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return c.JNI_FALSE;
    return if (c.libssh2_userauth_authenticated(session.session) != 0) c.JNI_TRUE else c.JNI_FALSE;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_blockDirections(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const directions = c.libssh2_session_block_directions(session.session);
    var output: c_int = 0;
    if ((directions & c.LIBSSH2_SESSION_BLOCK_INBOUND) != 0) output |= 1;
    if ((directions & c.LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0) output |= 2;
    return output;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_poll(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, timeout_ms: c.jint) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    if (session.socket_fd < 0 or timeout_ms < 0) {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid SSH poll request", .{});
        return session.last_errno;
    }
    const directions = c.libssh2_session_block_directions(session.session);
    var events: c_short = 0;
    if ((directions & c.LIBSSH2_SESSION_BLOCK_INBOUND) != 0) events |= c.POLLIN;
    if ((directions & c.LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0) events |= c.POLLOUT;
    if (events == 0) events = c.POLLIN | c.POLLOUT;
    var poll_fd: c.struct_pollfd = .{ .fd = session.socket_fd, .events = events, .revents = 0 };
    const result = c.poll(&poll_fd, 1, timeout_ms);
    if (result < 0) return recordErrno(session, "SSH poll failed");
    if (result == 0) return 0;
    clearError(session);
    return result;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sessionDisconnect(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, description: c.jstring) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const description_chars = env.*.*.GetStringUTFChars.?(env, description, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, description, description_chars);
    return recordResult(session, "SSH disconnect failed", c.libssh2_session_disconnect_ex(session.session, c.SSH_DISCONNECT_BY_APPLICATION, description_chars, "en"));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sessionFree(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) void {
    _ = env;
    _ = thiz;
    const key: u64 = @bitCast(handle);
    if (key == 0) return;
    registry_mutex.lock();
    const removed = sessions.fetchRemove(key);
    registry_mutex.unlock();
    if (removed) |entry| destroySession(entry.value);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_keepaliveConfig(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, interval_seconds: c.jint) callconv(.c) void {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return;
    if (interval_seconds < 0) {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid keepalive interval", .{});
        return;
    }
    c.libssh2_keepalive_config(session.session, 1, @intCast(interval_seconds));
    clearError(session);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_keepaliveSend(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    var seconds_to_next: c_int = 0;
    return recordResult(session, "SSH keepalive failed", c.libssh2_keepalive_send(session.session, &seconds_to_next));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_lastError(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jstring {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return jniNewString(env, "invalid SSH session");
    return jniNewString(env, session.last_error.items);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_lastErrno(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    return session.last_errno;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelOpenSession(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jlong {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const channel = c.libssh2_channel_open_ex(
        session.session,
        "session",
        7,
        c.LIBSSH2_CHANNEL_WINDOW_DEFAULT,
        c.LIBSSH2_CHANNEL_PACKET_DEFAULT,
        null,
        0,
    ) orelse {
        recordPointerFailure(session, "session channel open failed");
        return 0;
    };
    return registerChannel(session, channel);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelOpenStreamLocal(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, socket_path: c.jstring) callconv(.c) c.jlong {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const path_chars = env.*.*.GetStringUTFChars.?(env, socket_path, null) orelse return 0;
    defer env.*.*.ReleaseStringUTFChars.?(env, socket_path, path_chars);
    const path = std.mem.span(path_chars);
    if (path.len == 0 or path[0] != '/') {
        session.last_errno = -c.EINVAL;
        setError(session, "streamlocal socket path must be absolute", .{});
        return 0;
    }
    const channel = c.libssh2_channel_direct_streamlocal_ex(session.session, path_chars, "127.0.0.1", 0) orelse {
        recordPointerFailure(session, "streamlocal channel open failed");
        return 0;
    };
    return registerChannel(session, channel);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelOpenDirectTcpIp(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, host: c.jstring, port: c.jint) callconv(.c) c.jlong {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const host_chars = env.*.*.GetStringUTFChars.?(env, host, null) orelse return 0;
    defer env.*.*.ReleaseStringUTFChars.?(env, host, host_chars);
    if (std.mem.span(host_chars).len == 0 or port <= 0 or port > 65535) {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid direct TCP target", .{});
        return 0;
    }
    const channel = c.libssh2_channel_direct_tcpip_ex(session.session, host_chars, port, "127.0.0.1", 0) orelse {
        recordPointerFailure(session, "direct TCP channel open failed");
        return 0;
    };
    return registerChannel(session, channel);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelCreateSocketBridge(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid channel handle", .{});
        return session.last_errno;
    };
    if (entry.bridge != null) {
        session.last_errno = -c.EALREADY;
        setError(session, "channel already has a socket bridge", .{});
        return session.last_errno;
    }
    var pair: [2]c_int = .{ -1, -1 };
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) return recordErrno(session, "socket bridge allocation failed");
    if (!setSocketNonblocking(pair[0]) or !setSocketNonblocking(pair[1])) {
        closeSocket(pair[0]);
        closeSocket(pair[1]);
        return recordErrno(session, "socket bridge setup failed");
    }
    entry.bridge = .{ .relay_fd = pair[0] };
    clearError(session);
    return pair[1];
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelPumpSocketBridge(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse {
        session.last_errno = -c.EINVAL;
        setError(session, "invalid channel handle", .{});
        return session.last_errno;
    };
    return pumpBridge(session, entry);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelRequestPty(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong, term: c.jstring, cols: c.jint, rows: c.jint) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    if (cols <= 0 or rows <= 0) return -c.EINVAL;
    const term_chars = env.*.*.GetStringUTFChars.?(env, term, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, term, term_chars);
    return recordResult(session, "PTY request failed", c.libssh2_channel_request_pty_ex(
        entry.channel,
        term_chars,
        @intCast(std.mem.span(term_chars).len),
        null,
        0,
        cols,
        rows,
        0,
        0,
    ));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelResizePty(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong, cols: c.jint, rows: c.jint) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    if (cols <= 0 or rows <= 0) return -c.EINVAL;
    return recordResult(session, "PTY resize failed", c.libssh2_channel_request_pty_size_ex(entry.channel, cols, rows, 0, 0));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelExec(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong, command: c.jstring) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    const command_chars = env.*.*.GetStringUTFChars.?(env, command, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, command, command_chars);
    return recordResult(session, "channel exec failed", c.libssh2_channel_process_startup(entry.channel, "exec", 4, command_chars, @intCast(std.mem.span(command_chars).len)));
}

fn readChannel(env: *c.JNIEnv, session: *NativeSession, entry: *ChannelEntry, stream: c_int, buffer: c.jbyteArray) c.jint {
    const length = env.*.*.GetArrayLength.?(env, buffer);
    if (length <= 0) return 0;
    const bytes = env.*.*.GetByteArrayElements.?(env, buffer, null) orelse return -c.ENOMEM;
    defer env.*.*.ReleaseByteArrayElements.?(env, buffer, bytes, 0);
    const result = c.libssh2_channel_read_ex(entry.channel, stream, @ptrCast(bytes), @intCast(length));
    return recordResult(session, "channel read failed", @intCast(result));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelRead(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong, buffer: c.jbyteArray) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    return readChannel(env, session, entry, 0, buffer);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelReadStderr(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong, buffer: c.jbyteArray) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    return readChannel(env, session, entry, 1, buffer);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelWrite(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong, data: c.jbyteArray, offset: c.jint, length: c.jint) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    const array_length = env.*.*.GetArrayLength.?(env, data);
    if (offset < 0 or length < 0 or offset > array_length or length > array_length - offset) return -c.EINVAL;
    if (length == 0) return 0;
    const bytes = env.*.*.GetByteArrayElements.?(env, data, null) orelse return -c.ENOMEM;
    defer env.*.*.ReleaseByteArrayElements.?(env, data, bytes, c.JNI_ABORT);
    const result = c.libssh2_channel_write_ex(
        entry.channel,
        0,
        @ptrCast(bytes + @as(usize, @intCast(offset))),
        @intCast(length),
    );
    return recordResult(session, "channel write failed", @intCast(result));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelSendEof(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    return recordResult(session, "channel EOF failed", c.libssh2_channel_send_eof(entry.channel));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelEof(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) c.jboolean {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return c.JNI_TRUE;
    const entry = channelFromHandle(session, channel_handle) orelse return c.JNI_TRUE;
    return if (c.libssh2_channel_eof(entry.channel) != 0) c.JNI_TRUE else c.JNI_FALSE;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelClose(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const entry = channelFromHandle(session, channel_handle) orelse return -c.EINVAL;
    const result = recordResult(session, "channel close failed", c.libssh2_channel_close(entry.channel));
    if (result == 0) entry.closed = true;
    return result;
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelExitStatus(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -1;
    const entry = channelFromHandle(session, channel_handle) orelse return -1;
    if (!entry.closed or c.libssh2_channel_eof(entry.channel) == 0) return -1;
    return c.libssh2_channel_get_exit_status(entry.channel);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_channelFree(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, channel_handle: c.jlong) callconv(.c) void {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return;
    const id: u64 = @bitCast(channel_handle);
    const removed = session.channels.fetchRemove(id) orelse return;
    closeChannelEntry(removed.value);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpInit(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jlong {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const sftp = c.libssh2_sftp_init(session.session) orelse {
        recordPointerFailure(session, "SFTP init failed");
        return 0;
    };
    const entry = allocator.create(SftpEntry) catch {
        _ = c.libssh2_sftp_shutdown(sftp);
        session.last_errno = -c.ENOMEM;
        setError(session, "SFTP registry allocation failed", .{});
        return 0;
    };
    entry.* = .{ .sftp = sftp };
    const id = allocateChildId(session);
    session.sftps.put(allocator, id, entry) catch {
        closeSftpEntry(entry);
        session.last_errno = -c.ENOMEM;
        setError(session, "SFTP registry allocation failed", .{});
        return 0;
    };
    clearError(session);
    return @bitCast(id);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpOpen(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, sftp_handle: c.jlong, path: c.jstring, flags: c.jint, mode: c.jint) callconv(.c) c.jlong {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const sftp = sftpFromHandle(session, sftp_handle) orelse return 0;
    const path_chars = env.*.*.GetStringUTFChars.?(env, path, null) orelse return 0;
    defer env.*.*.ReleaseStringUTFChars.?(env, path, path_chars);
    const path_length = std.mem.span(path_chars).len;
    const file = c.libssh2_sftp_open_ex(sftp.sftp, path_chars, @intCast(path_length), @intCast(flags), @intCast(mode), c.LIBSSH2_SFTP_OPENFILE) orelse {
        recordPointerFailure(session, "SFTP open failed");
        return 0;
    };
    const entry = allocator.create(SftpFileEntry) catch {
        _ = c.libssh2_sftp_close_handle(file);
        session.last_errno = -c.ENOMEM;
        setError(session, "SFTP file registry allocation failed", .{});
        return 0;
    };
    const id = allocateChildId(session);
    const sftp_id: u64 = @bitCast(sftp_handle);
    entry.* = .{ .file = file, .sftp_id = sftp_id };
    session.files.put(allocator, id, entry) catch {
        closeSftpFileEntry(entry);
        session.last_errno = -c.ENOMEM;
        setError(session, "SFTP file registry allocation failed", .{});
        return 0;
    };
    sftp.file_ids.put(allocator, id, {}) catch {
        _ = session.files.fetchRemove(id);
        closeSftpFileEntry(entry);
        session.last_errno = -c.ENOMEM;
        setError(session, "SFTP file registry allocation failed", .{});
        return 0;
    };
    clearError(session);
    return @bitCast(id);
}

fn sftpWrite(env: *c.JNIEnv, session: *NativeSession, file: *SftpFileEntry, data: c.jbyteArray, offset: c.jint, length: c.jint) c.jint {
    const array_length = env.*.*.GetArrayLength.?(env, data);
    if (offset < 0 or length < 0 or offset > array_length or length > array_length - offset) return -c.EINVAL;
    if (length == 0) return 0;
    const bytes = env.*.*.GetByteArrayElements.?(env, data, null) orelse return -c.ENOMEM;
    defer env.*.*.ReleaseByteArrayElements.?(env, data, bytes, c.JNI_ABORT);
    const result = c.libssh2_sftp_write(
        file.file,
        @ptrCast(bytes + @as(usize, @intCast(offset))),
        @intCast(length),
    );
    return recordResult(session, "SFTP write failed", @intCast(result));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpWrite(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, file_handle: c.jlong, data: c.jbyteArray, offset: c.jint, length: c.jint) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const file = fileFromHandle(session, file_handle) orelse return -c.EINVAL;
    return sftpWrite(env, session, file, data, offset, length);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpRead(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, file_handle: c.jlong, buffer: c.jbyteArray) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const file = fileFromHandle(session, file_handle) orelse return -c.EINVAL;
    const length = env.*.*.GetArrayLength.?(env, buffer);
    if (length <= 0) return 0;
    const bytes = env.*.*.GetByteArrayElements.?(env, buffer, null) orelse return -c.ENOMEM;
    defer env.*.*.ReleaseByteArrayElements.?(env, buffer, bytes, 0);
    const result = c.libssh2_sftp_read(file.file, @ptrCast(bytes), @intCast(length));
    return recordResult(session, "SFTP read failed", @intCast(result));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpCloseHandle(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, file_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const file = fileFromHandle(session, file_handle) orelse return -c.EINVAL;
    const result = recordResult(session, "SFTP file close failed", c.libssh2_sftp_close_handle(file.file));
    if (result != 0) return result;
    const file_id: u64 = @bitCast(file_handle);
    const removed = session.files.fetchRemove(file_id) orelse return 0;
    if (session.sftps.get(removed.value.sftp_id)) |sftp| _ = sftp.file_ids.fetchRemove(file_id);
    allocator.destroy(removed.value);
    return 0;
}

fn sftpPathOperation(env: *c.JNIEnv, session: *NativeSession, sftp: *SftpEntry, path: c.jstring, context: []const u8, operation: *const fn (*c.LIBSSH2_SFTP, [*:0]const u8, usize) callconv(.c) c_int) c.jint {
    const path_chars = env.*.*.GetStringUTFChars.?(env, path, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, path, path_chars);
    return recordResult(session, context, operation(sftp.sftp, path_chars, std.mem.span(path_chars).len));
}

fn unlinkOperation(sftp: *c.LIBSSH2_SFTP, path: [*:0]const u8, length: usize) callconv(.c) c_int {
    return c.libssh2_sftp_unlink_ex(sftp, path, @intCast(length));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpRename(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, sftp_handle: c.jlong, source: c.jstring, destination: c.jstring) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const sftp = sftpFromHandle(session, sftp_handle) orelse return -c.EINVAL;
    const source_chars = env.*.*.GetStringUTFChars.?(env, source, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, source, source_chars);
    const destination_chars = env.*.*.GetStringUTFChars.?(env, destination, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, destination, destination_chars);
    return recordResult(session, "SFTP rename failed", c.libssh2_sftp_posix_rename_ex(
        sftp.sftp,
        source_chars,
        @intCast(std.mem.span(source_chars).len),
        destination_chars,
        @intCast(std.mem.span(destination_chars).len),
    ));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpUnlink(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, sftp_handle: c.jlong, path: c.jstring) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const sftp = sftpFromHandle(session, sftp_handle) orelse return -c.EINVAL;
    return sftpPathOperation(env, session, sftp, path, "SFTP unlink failed", unlinkOperation);
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpMkdir(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, sftp_handle: c.jlong, path: c.jstring, mode: c.jint) callconv(.c) c.jint {
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const sftp = sftpFromHandle(session, sftp_handle) orelse return -c.EINVAL;
    const path_chars = env.*.*.GetStringUTFChars.?(env, path, null) orelse return -c.EINVAL;
    defer env.*.*.ReleaseStringUTFChars.?(env, path, path_chars);
    return recordResult(session, "SFTP mkdir failed", c.libssh2_sftp_mkdir_ex(sftp.sftp, path_chars, @intCast(std.mem.span(path_chars).len), @intCast(mode)));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpLastError(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, sftp_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return 0;
    const sftp = sftpFromHandle(session, sftp_handle) orelse return 0;
    return @intCast(c.libssh2_sftp_last_error(sftp.sftp));
}

export fn Java_dev_bybee_heeler_core_ssh_NativeSsh_sftpShutdown(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, sftp_handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    const session = sessionFromHandle(handle) orelse return -c.EINVAL;
    const sftp = sftpFromHandle(session, sftp_handle) orelse return -c.EINVAL;
    const result = recordResult(session, "SFTP shutdown failed", c.libssh2_sftp_shutdown(sftp.sftp));
    if (result != 0) return result;

    const sftp_id: u64 = @bitCast(sftp_handle);
    const removed = session.sftps.fetchRemove(sftp_id) orelse return 0;
    var file_iterator = removed.value.file_ids.keyIterator();
    while (file_iterator.next()) |file_id| {
        if (session.files.fetchRemove(file_id.*)) |file_entry| allocator.destroy(file_entry.value);
    }
    removed.value.file_ids.deinit(allocator);
    allocator.destroy(removed.value);
    return 0;
}
