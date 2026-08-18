//! ghostty-vt JNI snapshot bridge for Heeler.
//! Adapted from chuchu (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const zigimg = @import("zigimg");

const c = @cImport({
    @cInclude("jni.h");
    @cInclude("android/log.h");
});

const allocator = std.heap.c_allocator;
const LOG_TAG = "HeelerTerminal";
const verbose_kitty_logs = false;
const verbose_snapshot_perf_logs = false;
// Header layout (LE i32 fields):
//   0  cols
//   1  rows
//   2  cursor_x
//   3  cursor_y
//   4  cursor_visible
//   5  default_bg_r
//   6  default_bg_g
//   7  default_bg_b
//   8  default_fg_r
//   9  default_fg_g
//  10  default_fg_b
//  11  extras_offset (byte offset to grapheme extras section, 0 if none)
//  12  viewport_scroll_y (screen.y of the content at viewport row 0; stable
//      content coordinate that changes as the viewport scrolls, so the host
//      can remap a content-tracking selection anchor across scrolls)
//  13  app_handles_selection_drag (1 when the running app has enabled a
//      drag-reporting mouse mode — DECSET 1002/1003 — so the host forwards
//      long-press drag gestures to the app instead of starting a client-side
//      grid selection. This is what lets tmux/zellij perform their own
//      pane-scoped selection.)
const SNAPSHOT_HEADER_I32_COUNT = 14;
const SNAPSHOT_CELL_SIZE_BYTES = 11;
// Flag bit set on a cell whose codepoint has additional grapheme codepoints
// in the extras section.
const CELL_FLAG_HAS_GRAPHEME: u8 = 1 << 6;
// Flag bit set on spacer cells that belong to a wide glyph cluster.
// These are serialized with codepoint=32 but should not force a shaping
// run break between neighboring glyph cells.
const CELL_FLAG_SPACER: u8 = 1 << 7;
const IMAGE_HEADER_BYTES = 52;
const MAX_KITTY_IMAGES = 64;
const MAX_OSC52_CLIPBOARD_BYTES = 1024 * 1024;
const MAX_OSC7_PWD_BYTES = 4096;
// Kitty Unicode graphics placeholder (U+10EEEE). These cells only mark where an
// image is composited; we blank them so the raw glyph never shows through a gap
// the image doesn't fully cover.
const KITTY_PLACEHOLDER_CP: u32 = 0x10EEEE;
fn decodePngRgba(data: [*]const u8, len: usize, out_w: *u32, out_h: *u32) ?[*]u8 {
    var read_stream = zigimg.io.ReadStream.initMemory(data[0..len]);
    var image = zigimg.formats.png.PNG.readImage(allocator, &read_stream) catch return null;
    defer image.deinit(allocator);
    image.convert(allocator, .rgba32) catch return null;
    if (image.width > std.math.maxInt(u32) or image.height > std.math.maxInt(u32)) return null;

    out_w.* = @intCast(image.width);
    out_h.* = @intCast(image.height);
    const pixels = allocator.dupe(u8, image.rawBytes()) catch return null;
    return pixels.ptr;
}

fn freeRgbaPixels(ptr: ?[*]u8, width: u32, height: u32) void {
    if (ptr) |pixels| {
        const len = @as(usize, width) * @as(usize, height) * 4;
        allocator.free(pixels[0..len]);
    }
}


const DeviceAttributes = blk: {
    const device_attributes_opt = @FieldType(ghostty.TerminalStream.Handler.Effects, "device_attributes");
    const device_attributes_fn = @typeInfo(device_attributes_opt).optional.child;
    break :blk @typeInfo(@typeInfo(device_attributes_fn).pointer.child).@"fn".return_type.?;
};

const ImageFreeMode = enum(c_int) {
    none = 0,
    malloc_buf = 1,
};

const PlacementInfo = struct {
    // Cell-grid position; Kotlin derives the pixel origin as cell*cellSize +
    // cell_*_offset. dest_w/dest_h are libghostty's *scaled* image size that
    // cell_*_offset centers — use them straight (rendered.dest_width for virtual,
    // grid*cell for direct); recomputing as grid_cols*cell shifts it ~1px.
    cell_col: i32,
    cell_row: i32,
    cell_x_offset: u32,
    cell_y_offset: u32,
    dest_w: u32,
    dest_h: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    img_w: u32,
    img_h: u32,
    data_ptr: [*c]const u8,
    data_len: usize,
    free_mode: ImageFreeMode,
};

const PreparedImageData = struct {
    data_ptr: [*c]const u8,
    data_len: usize,
    img_w: u32,
    img_h: u32,
    free_mode: ImageFreeMode,
};

const MouseEncodingSize = struct {
    screen_width: u32 = 1,
    screen_height: u32 = 1,
    cell_width: u32 = 1,
    cell_height: u32 = 1,
    padding_top: u32 = 0,
    padding_bottom: u32 = 0,
    padding_left: u32 = 0,
    padding_right: u32 = 0,
};

fn appHandlesSelectionDrag(event: anytype) bool {
    return switch (event) {
        .button, .any => true,
        else => false,
    };
}

const HeelerTerminal = struct {
    terminal: ghostty.Terminal,
    render_state: ghostty.RenderState = .empty,
    stream_handler: HeelerStreamHandler = undefined,
    stream: HeelerTerminalStream,
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    mouse_size: MouseEncodingSize = .{},
    mouse_size_set: bool = false,
    last_mouse_cell: ?ghostty.point.Coordinate = null,
    color_scheme: ghostty.device_status.ColorScheme = .dark,
    color_scheme_set: bool = false,
    title: ?[]u8 = null,
    title_len: usize = 0,
    title_dirty: bool = false,
    pwd: ?[]u8 = null,
    pwd_len: usize = 0,
    pwd_dirty: bool = false,
    clipboard: ?[]u8 = null,
    clipboard_len: usize = 0,
    clipboard_dirty: bool = false,
    bell_count: u32 = 0,
    snapshot_buffer: std.ArrayListUnmanaged(u8) = .empty,
    snapshot_extras_scratch: std.ArrayListUnmanaged(u32) = .empty,
    image_snapshot_buffer: std.ArrayListUnmanaged(u8) = .empty,
    pty_write_buffer: std.ArrayListUnmanaged(u8) = .empty,
    pty_write_len: usize = 0,
    snapshot_perf_calls: u64 = 0,
    snapshot_perf_total_ns: u64 = 0,
    snapshot_perf_last_log_ns: i64 = 0,
};

const HeelerStreamHandler = struct {
    owner: *HeelerTerminal,
    inner: ghostty.TerminalStream.Handler,

    pub fn deinit(self: *HeelerStreamHandler) void {
        self.inner.deinit();
    }

    pub fn vt(
        self: *HeelerStreamHandler,
        comptime action: HeelerTerminalStream.Action.Tag,
        value: HeelerTerminalStream.Action.Value(action),
    ) void {
        if (action == .clipboard_contents) {
            self.clipboardContents(value.kind, value.data);
        }
        if (action == .report_pwd) {
            self.reportPwd(value.url);
        }
        self.inner.vt(action, value);
    }

    fn clipboardContents(self: *HeelerStreamHandler, _: u8, data: []const u8) void {
        if (std.mem.eql(u8, data, "?")) return;
        storeClipboardData(self.owner, data);
    }

    fn reportPwd(self: *HeelerStreamHandler, url: []const u8) void {
        var decoded: [MAX_OSC7_PWD_BYTES]u8 = undefined;
        const pwd = decodeOsc7FilePath(url, &decoded) orelse return;
        // Chuchu terminals are remote, so their reported path is useful even when the URL host is not local.
        self.owner.terminal.setPwd(pwd) catch return;
    }
};

const HeelerTerminalStream = ghostty.Stream(*HeelerStreamHandler);

fn decodeOsc7FilePath(url: []const u8, decoded: *[MAX_OSC7_PWD_BYTES]u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, url, prefix) or url.len > MAX_OSC7_PWD_BYTES) return null;

    const host_and_path = url[prefix.len..];
    const path_start = std.mem.indexOfScalar(u8, host_and_path, '/') orelse return null;
    const encoded_path = host_and_path[path_start..];
    if (encoded_path.len == 0) return null;

    var encoded_index: usize = 0;
    var decoded_len: usize = 0;
    while (encoded_index < encoded_path.len) {
        const byte = encoded_path[encoded_index];
        if (byte == '%' and encoded_index + 2 < encoded_path.len) {
            if (hexValue(encoded_path[encoded_index + 1])) |high| {
                if (hexValue(encoded_path[encoded_index + 2])) |low| {
                    decoded[decoded_len] = high * 16 + low;
                    decoded_len += 1;
                    encoded_index += 3;
                    continue;
                }
            }
        }
        decoded[decoded_len] = byte;
        decoded_len += 1;
        encoded_index += 1;
    }

    const path = decoded[0..decoded_len];
    if (!std.mem.startsWith(u8, path, "/")) return null;
    return path;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn heelerFromHandle(handle: c.jlong) ?*HeelerTerminal {
    if (handle == 0) return null;
    const raw_handle: u64 = @bitCast(handle);
    return @ptrFromInt(@as(usize, @truncate(raw_handle)));
}

fn heelerHandleFromPtr(ptr: *HeelerTerminal) c.jlong {
    const raw_ptr: u64 = @intCast(@intFromPtr(ptr));
    return @bitCast(raw_ptr);
}

fn clampI32(value: c.jint, minimum: i32, fallback: i32) i32 {
    if (value < minimum) return fallback;
    return @intCast(value);
}

fn rgbFromBytes(bytes: [*c]const u8) ghostty.color.RGB {
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2] };
}

fn terminalFromHandler(handler: *ghostty.TerminalStream.Handler) *HeelerTerminal {
    return @fieldParentPtr("terminal", handler.terminal);
}

fn logLine(prio: c_int, message: []const u8) void {
    _ = c.__android_log_print(prio, LOG_TAG, "%.*s", @as(c_int, @intCast(message.len)), message.ptr);
}

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    if (!verbose_kitty_logs) return;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    logLine(c.ANDROID_LOG_INFO, line);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    logLine(c.ANDROID_LOG_WARN, line);
}

fn maybeLogSnapshotPerf(
    terminal: *HeelerTerminal,
    cols: usize,
    rows: usize,
    extras_records: usize,
    non_blank_cells: usize,
    total_size: usize,
    update_ns: i128,
    build_ns: i128,
    total_ns: i128,
) void {
    if (!verbose_snapshot_perf_logs) return;
    if (total_ns <= 0) return;

    const total_u64: u64 = @intCast(total_ns);
    terminal.snapshot_perf_calls += 1;
    terminal.snapshot_perf_total_ns +%= total_u64;

    const now: i64 = @intCast(std.time.nanoTimestamp());
    const slow = total_ns >= 8 * std.time.ns_per_ms or update_ns >= 4 * std.time.ns_per_ms or build_ns >= 6 * std.time.ns_per_ms;
    const interval_elapsed = now - terminal.snapshot_perf_last_log_ns >= std.time.ns_per_s;
    if (!slow and !interval_elapsed) return;

    const avg_ns = if (terminal.snapshot_perf_calls > 0)
        terminal.snapshot_perf_total_ns / terminal.snapshot_perf_calls
    else
        0;

    const total_ms = @as(f64, @floatFromInt(total_u64)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    const update_ms = @as(f64, @floatFromInt(@as(u64, @intCast(update_ns)))) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    const build_ms = @as(f64, @floatFromInt(@as(u64, @intCast(build_ns)))) / @as(f64, @floatFromInt(std.time.ns_per_ms));

    logWarn(
        "snapshot_perf total={d:.2}ms avg={d:.2}ms update={d:.2}ms build={d:.2}ms grid={}x{} extras={} non_blank={} bytes={} calls={}",
        .{ total_ms, avg_ms, update_ms, build_ms, cols, rows, extras_records, non_blank_cells, total_size, terminal.snapshot_perf_calls },
    );
    terminal.snapshot_perf_last_log_ns = now;
}

fn logKittyState(stage: []const u8, terminal: *HeelerTerminal) void {
    const storage = &terminal.terminal.screens.active.kitty_images;
    const viewport_top = terminal.terminal.screens.active.pages.getTopLeft(.viewport);
    logInfo(
        "kitty_state stage={s} images={} placements={} loading={} total_bytes={} viewport=({}, {}) term={}x{} cell={}x{}",
        .{
            stage,
            storage.images.count(),
            storage.placements.count(),
            storage.loading != null,
            storage.total_bytes,
            viewport_top.x,
            viewport_top.y,
            terminal.cols,
            terminal.rows,
            terminal.cell_width,
            terminal.cell_height,
        },
    );
}

fn ensureListSize(list: *std.ArrayListUnmanaged(u8), size_needed: usize) ?[*]u8 {
    list.ensureTotalCapacityPrecise(allocator, size_needed) catch return null;
    list.items.len = size_needed;
    return list.items.ptr;
}

fn updateString(storage: *?[]u8, storage_len: *usize, dirty: *bool, value: ?[:0]const u8) bool {
    const slice: []const u8 = if (value) |v| v else "";

    if (storage.* != null and storage_len.* == slice.len) {
        if (slice.len == 0) return false;
        if (std.mem.eql(u8, storage.*.?[0..slice.len], slice)) return false;
    }

    const new_buf = allocator.alloc(u8, slice.len + 1) catch return false;
    if (slice.len > 0) @memcpy(new_buf[0..slice.len], slice);
    new_buf[slice.len] = 0;

    if (storage.*) |old| allocator.free(old);
    storage.* = new_buf;
    storage_len.* = slice.len;
    dirty.* = true;
    return true;
}

fn updateBytes(storage: *?[]u8, storage_len: *usize, dirty: *bool, bytes: []const u8) bool {
    if (storage.* != null and storage_len.* == bytes.len) {
        if (bytes.len == 0) return false;
    }

    const new_buf = allocator.alloc(u8, bytes.len) catch return false;
    if (bytes.len > 0) @memcpy(new_buf, bytes);

    if (storage.*) |old| allocator.free(old);
    storage.* = new_buf;
    storage_len.* = bytes.len;
    dirty.* = true;
    return true;
}

fn decodeBase64Clipboard(data: []const u8) ?[]u8 {
    const decoders = [_]std.base64.Base64Decoder{
        std.base64.standard.Decoder,
        std.base64.standard_no_pad.Decoder,
    };
    for (decoders) |decoder| {
        const decoded_len = decoder.calcSizeForSlice(data) catch continue;
        if (decoded_len > MAX_OSC52_CLIPBOARD_BYTES) return null;
        const decoded = allocator.alloc(u8, decoded_len) catch return null;
        decoder.decode(decoded, data) catch {
            allocator.free(decoded);
            continue;
        };
        return decoded;
    }
    return null;
}

fn storeClipboardData(terminal: *HeelerTerminal, encoded: []const u8) void {
    const decoded = decodeBase64Clipboard(encoded) orelse return;
    defer allocator.free(decoded);
    _ = updateBytes(&terminal.clipboard, &terminal.clipboard_len, &terminal.clipboard_dirty, decoded);
}

fn updateMetadata(terminal: *HeelerTerminal) void {
    _ = updateString(&terminal.title, &terminal.title_len, &terminal.title_dirty, terminal.terminal.getTitle());
    _ = updateString(&terminal.pwd, &terminal.pwd_len, &terminal.pwd_dirty, terminal.terminal.getPwd());
}

fn heelerWritePty(handler: *ghostty.TerminalStream.Handler, data: [:0]const u8) void {
    const terminal = terminalFromHandler(handler);
    appendPtyWrite(terminal, data);
}

fn heelerBell(handler: *ghostty.TerminalStream.Handler) void {
    const terminal = terminalFromHandler(handler);
    if (terminal.bell_count < std.math.maxInt(u32)) terminal.bell_count += 1;
}

fn heelerTitleChanged(handler: *ghostty.TerminalStream.Handler) void {
    updateMetadata(terminalFromHandler(handler));
}

fn heelerColorScheme(handler: *ghostty.TerminalStream.Handler) ?ghostty.device_status.ColorScheme {
    const terminal = terminalFromHandler(handler);
    if (!terminal.color_scheme_set) return null;
    return terminal.color_scheme;
}

fn heelerDeviceAttributes(_: *ghostty.TerminalStream.Handler) DeviceAttributes {
    // Use Ghostty's parsed DA handling so replies still work when escape
    // sequences are split across SSH read chunks.
    return .{};
}

fn heelerSize(handler: *ghostty.TerminalStream.Handler) ?ghostty.size_report.Size {
    const terminal = terminalFromHandler(handler);
    return .{
        .rows = terminal.rows,
        .columns = terminal.cols,
        .cell_width = if (terminal.cell_width > 0) terminal.cell_width else 1,
        .cell_height = if (terminal.cell_height > 0) terminal.cell_height else 1,
    };
}

fn heelerXtversion(_: *ghostty.TerminalStream.Handler) []const u8 {
    return "ghostty 1";
}

fn enableGraphemeClusterMode(terminal: *HeelerTerminal) void {
    // DEC private mode 2027 makes ghostty-vt collapse grapheme clusters by
    // terminal-cell width rather than summing each codepoint's wcwidth.
    terminal.stream.nextSlice("\x1b[?2027h");
}

fn appendPtyWrite(terminal: *HeelerTerminal, bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (std.math.maxInt(usize) - terminal.pty_write_len < bytes.len) return;
    const size_needed = terminal.pty_write_len + bytes.len;
    _ = ensureListSize(&terminal.pty_write_buffer, size_needed) orelse return;
    @memcpy(terminal.pty_write_buffer.items[terminal.pty_write_len .. terminal.pty_write_len + bytes.len], bytes);
    terminal.pty_write_len += bytes.len;
}

fn heelerDecodePng(alloc: std.mem.Allocator, data: []const u8) ghostty.sys.DecodeError!ghostty.sys.Image {
    var w: u32 = 0;
    var h: u32 = 0;
    const pixels = decodePngRgba(data.ptr, data.len, &w, &h) orelse return error.InvalidData;
    defer freeRgbaPixels(pixels, w, h);
    logInfo("decode_png ok bytes={} width={} height={}", .{ data.len, w, h });

    const pixel_len = @as(usize, w) * @as(usize, h) * 4;
    const out = try alloc.alloc(u8, pixel_len);
    @memcpy(out, pixels[0..pixel_len]);
    return .{ .width = w, .height = h, .data = out };
}

export fn update_render_state(terminal: ?*HeelerTerminal) callconv(.c) void {
    if (terminal == null) return;
    terminal.?.render_state.update(allocator, &terminal.?.terminal) catch return;
    updateMetadata(terminal.?);
}

export fn heeler_create_terminal(cols: c.jint, rows: c.jint, max_scrollback: c.jint) callconv(.c) c.jlong {
    ghostty.sys.decode_png = heelerDecodePng;

    const terminal = allocator.create(HeelerTerminal) catch return 0;
    errdefer allocator.destroy(terminal);

    const init_cols: u16 = @intCast(clampI32(cols, 1, 80));
    const init_rows: u16 = @intCast(clampI32(rows, 1, 24));
    var inner = ghostty.Terminal.init(allocator, .{
        .cols = init_cols,
        .rows = init_rows,
        .max_scrollback = @intCast(clampI32(max_scrollback, 0, 10000)),
        .kitty_image_storage_limit = 64 * 1024 * 1024,
        .kitty_image_loading_limits = .{
            .file = false,
            .temporary_file = true,
            .shared_memory = true,
        },
    }) catch return 0;
    errdefer inner.deinit(allocator);

    terminal.* = .{
        .terminal = inner,
        .stream_handler = undefined,
        .stream = undefined,
        .cols = init_cols,
        .rows = init_rows,
        .cell_width = 1,
        .cell_height = 1,
    };

    var handler = terminal.terminal.vtHandler();
    handler.effects = .{
        .write_pty = heelerWritePty,
        .bell = heelerBell,
        .color_scheme = heelerColorScheme,
        .device_attributes = heelerDeviceAttributes,
        .enquiry = null,
        .size = heelerSize,
        .title_changed = heelerTitleChanged,
        .xtversion = heelerXtversion,
    };
    terminal.stream_handler = .{
        .owner = terminal,
        .inner = handler,
    };
    terminal.stream = HeelerTerminalStream.initAlloc(allocator, &terminal.stream_handler);
    enableGraphemeClusterMode(terminal);

    update_render_state(terminal);
    return heelerHandleFromPtr(terminal);
}

export fn heeler_destroy_terminal(handle: c.jlong) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;
    terminal.snapshot_buffer.deinit(allocator);
    terminal.snapshot_extras_scratch.deinit(allocator);
    terminal.image_snapshot_buffer.deinit(allocator);
    terminal.pty_write_buffer.deinit(allocator);
    if (terminal.title) |buf| allocator.free(buf);
    if (terminal.pwd) |buf| allocator.free(buf);
    if (terminal.clipboard) |buf| allocator.free(buf);
    terminal.render_state.deinit(allocator);
    terminal.stream.deinit();
    terminal.terminal.deinit(allocator);
    allocator.destroy(terminal);
}

fn jniNewByteArray(env: *c.JNIEnv, len: c.jsize) c.jbyteArray {
    return env.*.*.NewByteArray.?(env, len);
}

fn jniEmptyByteArray(env: *c.JNIEnv) c.jbyteArray {
    return jniNewByteArray(env, 0);
}

fn jniNewDirectByteBuffer(env: *c.JNIEnv, ptr: ?*anyopaque, len: c.jlong) c.jobject {
    return env.*.*.NewDirectByteBuffer.?(env, ptr, len);
}

fn jniNewStringUTF(env: *c.JNIEnv, s: [*:0]const u8) c.jstring {
    return env.*.*.NewStringUTF.?(env, s);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_version(env: *c.JNIEnv, clazz: c.jclass) callconv(.c) c.jstring {
    _ = clazz;
    return jniNewStringUTF(env, "1");
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_create(env: *c.JNIEnv, thiz: c.jobject, cols: c.jint, rows: c.jint, max_scrollback: c.jint) callconv(.c) c.jlong {
    _ = env;
    _ = thiz;
    return heeler_create_terminal(cols, rows, max_scrollback);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_destroy(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) void {
    _ = env;
    _ = thiz;
    heeler_destroy_terminal(handle);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_writeRemote(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, data: c.jbyteArray) callconv(.c) void {
    _ = thiz;
    if (data == null) return;
    const len = env.*.*.GetArrayLength.?(env, data);
    if (len <= 0) return;
    var is_copy: c.jboolean = c.JNI_FALSE;
    const bytes = env.*.*.GetByteArrayElements.?(env, data, &is_copy);
    if (bytes == null) return;
    heeler_write_remote(handle, @ptrCast(bytes), @intCast(len));
    env.*.*.ReleaseByteArrayElements.?(env, data, bytes, c.JNI_ABORT);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_resize(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, cols: c.jint, rows: c.jint, cell_width: c.jint, cell_height: c.jint) callconv(.c) void {
    _ = env;
    _ = thiz;
    heeler_resize(handle, cols, rows, cell_width, cell_height);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_scroll(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, delta: c.jint, x: c.jfloat, y: c.jfloat) callconv(.c) void {
    _ = env;
    _ = thiz;
    heeler_scroll(handle, delta, x, y);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_scrollToActive(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) void {
    _ = env;
    _ = thiz;
    heeler_scroll_to_active(handle);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_snapshot(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jobject {
    _ = thiz;
    var size: usize = 0;
    const buffer = heeler_build_text_snapshot(handle, &size);
    if (buffer == null or size == 0) return jniNewDirectByteBuffer(env, null, 0);
    return jniNewDirectByteBuffer(env, @ptrCast(buffer), @intCast(size));
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_snapshotImages(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jobject {
    _ = thiz;
    var size: usize = 0;
    const buffer = heeler_build_image_snapshot(handle, &size);
    if (buffer == null or size == 0) return jniNewDirectByteBuffer(env, null, 0);
    return jniNewDirectByteBuffer(env, @ptrCast(buffer), @intCast(size));
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_isImageLoading(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jboolean {
    _ = env;
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return c.JNI_FALSE;
    return if (terminal.terminal.screens.active.kitty_images.loading != null) c.JNI_TRUE else c.JNI_FALSE;
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_pollTitle(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jstring {
    _ = thiz;
    const value = heeler_poll_title_ptr(handle) orelse return null;
    return jniNewStringUTF(env, value);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_pollPwd(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jstring {
    _ = thiz;
    const value = heeler_poll_pwd_ptr(handle) orelse return null;
    return jniNewStringUTF(env, value);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_pollClipboard(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jbyteArray {
    _ = thiz;
    const bytes = heeler_poll_clipboard(handle) orelse return null;
    return jniByteArrayFromBytes(env, bytes);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_drainBellCount(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jint {
    _ = env;
    _ = thiz;
    return heeler_drain_bell_count(handle);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_setColorScheme(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, scheme: c.jint) callconv(.c) void {
    _ = env;
    _ = thiz;
    heeler_set_color_scheme(handle, scheme);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_setMouseEncodingSize(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, screen_width: c.jint, screen_height: c.jint, cell_width: c.jint, cell_height: c.jint, padding_top: c.jint, padding_bottom: c.jint, padding_left: c.jint, padding_right: c.jint) callconv(.c) void {
    _ = env;
    _ = thiz;
    heeler_set_mouse_encoding_size(handle, screen_width, screen_height, cell_width, cell_height, padding_top, padding_bottom, padding_left, padding_right);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_encodeKey(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, key: c.jint, codepoint: c.jint, mods: c.jint, action: c.jint, utf8_jstring: c.jstring) callconv(.c) c.jbyteArray {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return jniEmptyByteArray(env);
    const action_value: ghostty.input.KeyAction = std.meta.intToEnum(ghostty.input.KeyAction, action) catch return jniEmptyByteArray(env);
    const key_value: ghostty.input.Key = std.meta.intToEnum(ghostty.input.Key, key) catch return jniEmptyByteArray(env);

    // Convert Java string to Zig slice for Ghostty's utf8 field.
    // For printable characters this allows the legacy encoding path to emit
    // raw text when the remote terminal doesn't support Kitty keyboard protocol.
    // Must outlive the encodeKey call because Ghostty references it.
    var utf8_buf: [256]u8 = undefined;
    const utf8_slice: []const u8 = blk: {
        if (utf8_jstring == null) break :blk "";
        const chars = env.*.*.GetStringUTFChars.?(env, utf8_jstring, null) orelse break :blk "";
        defer env.*.*.ReleaseStringUTFChars.?(env, utf8_jstring, chars);
        const len = std.mem.span(chars).len;
        if (len > utf8_buf.len) break :blk "";
        @memcpy(utf8_buf[0..len], chars[0..len]);
        break :blk utf8_buf[0..len];
    };

    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const event: ghostty.input.KeyEvent = .{
        .action = action_value,
        .key = key_value,
        .mods = @bitCast(@as(ghostty.input.KeyMods.Backing, @intCast(mods))),
        .unshifted_codepoint = if (codepoint > 0) @intCast(codepoint) else 0,
        .utf8 = utf8_slice,
    };
    ghostty.input.encodeKey(&writer, event, ghostty.input.KeyEncodeOptions.fromTerminal(&terminal.terminal)) catch return jniEmptyByteArray(env);
    return jniByteArrayFromBytes(env, writer.buffered());
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_encodePaste(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, data_jstring: c.jstring) callconv(.c) c.jbyteArray {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return jniEmptyByteArray(env);
    if (data_jstring == null) return jniEmptyByteArray(env);

    const chars = env.*.*.GetStringUTFChars.?(env, data_jstring, null) orelse return jniEmptyByteArray(env);
    defer env.*.*.ReleaseStringUTFChars.?(env, data_jstring, chars);
    const data_len = std.mem.span(chars).len;
    if (data_len == 0) return jniEmptyByteArray(env);

    // encodePaste may need to mutate the data in place (stripping unsafe
    // bytes and, for non-bracketed pastes, converting newlines to \r), so
    // copy the JNI string into a mutable buffer before encoding.
    const data_copy = allocator.alloc(u8, data_len) catch return jniEmptyByteArray(env);
    defer allocator.free(data_copy);
    @memcpy(data_copy, chars[0..data_len]);

    const segments = ghostty.input.encodePaste(data_copy, ghostty.input.PasteOptions.fromTerminal(&terminal.terminal));
    const total = segments[0].len + segments[1].len + segments[2].len;
    if (total == 0) return jniEmptyByteArray(env);

    const out = allocator.alloc(u8, total) catch return jniEmptyByteArray(env);
    defer allocator.free(out);
    var offset: usize = 0;
    for (segments) |segment| {
        @memcpy(out[offset..][0..segment.len], segment);
        offset += segment.len;
    }

    return jniByteArrayFromBytes(env, out);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_encodeMouse(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, action: c.jint, button: c.jint, mods: c.jint, x: c.jfloat, y: c.jfloat, any_button_pressed: c.jboolean, track_last_cell: c.jboolean) callconv(.c) c.jbyteArray {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return jniEmptyByteArray(env);
    if (!terminal.mouse_size_set) return jniEmptyByteArray(env);
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var last_cell = terminal.last_mouse_cell;
    const event: ghostty.input.MouseEncodeEvent = .{
        .action = @enumFromInt(action),
        .button = if (button <= 0) null else @enumFromInt(button),
        .mods = @bitCast(@as(ghostty.input.KeyMods.Backing, @intCast(mods))),
        .pos = .{ .x = x, .y = y },
    };
    const opts = ghosttyMouseEncodeOptions(terminal, any_button_pressed == c.JNI_TRUE, track_last_cell == c.JNI_TRUE, &last_cell);
    ghostty.input.encodeMouse(&writer, event, opts) catch return jniEmptyByteArray(env);
    if (track_last_cell == c.JNI_TRUE) terminal.last_mouse_cell = last_cell;
    return jniByteArrayFromBytes(env, writer.buffered());
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_encodeFocus(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, focused: c.jboolean) callconv(.c) c.jbyteArray {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return jniEmptyByteArray(env);
    if (!terminal.terminal.modes.get(.focus_event)) return jniEmptyByteArray(env);
    var buf: [ghostty.input.max_focus_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    ghostty.input.encodeFocus(&writer, if (focused == c.JNI_TRUE) .gained else .lost) catch return jniEmptyByteArray(env);
    return jniByteArrayFromBytes(env, writer.buffered());
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_drainPtyWrites(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong) callconv(.c) c.jbyteArray {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return jniEmptyByteArray(env);
    if (terminal.pty_write_len == 0) return jniEmptyByteArray(env);
    const out = jniByteArrayFromBytes(env, terminal.pty_write_buffer.items[0..terminal.pty_write_len]);
    terminal.pty_write_len = 0;
    return out;
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_setDefaultColors(env: *c.JNIEnv, thiz: c.jobject, handle: c.jlong, fg_rgb: c.jintArray, bg_rgb: c.jintArray, cursor_rgb: c.jintArray, palette_rgb: c.jbyteArray) callconv(.c) void {
    _ = thiz;
    var fg_vals: [3]u8 = .{ 0, 0, 0 };
    var bg_vals: [3]u8 = .{ 0, 0, 0 };
    var cursor_vals: [3]u8 = .{ 0, 0, 0 };
    var palette_vals: [256 * 3]u8 = [_]u8{0} ** (256 * 3);
    var has_fg = false;
    var has_bg = false;
    var has_cursor = false;
    var has_palette = false;

    if (fg_rgb != null and env.*.*.GetArrayLength.?(env, fg_rgb) >= 3) {
        var is_copy: c.jboolean = c.JNI_FALSE;
        const values = env.*.*.GetIntArrayElements.?(env, fg_rgb, &is_copy);
        if (values != null) {
            fg_vals = .{ @intCast(@max(0, @min(255, values[0]))), @intCast(@max(0, @min(255, values[1]))), @intCast(@max(0, @min(255, values[2]))) };
            has_fg = true;
            env.*.*.ReleaseIntArrayElements.?(env, fg_rgb, values, c.JNI_ABORT);
        }
    }
    if (bg_rgb != null and env.*.*.GetArrayLength.?(env, bg_rgb) >= 3) {
        var is_copy: c.jboolean = c.JNI_FALSE;
        const values = env.*.*.GetIntArrayElements.?(env, bg_rgb, &is_copy);
        if (values != null) {
            bg_vals = .{ @intCast(@max(0, @min(255, values[0]))), @intCast(@max(0, @min(255, values[1]))), @intCast(@max(0, @min(255, values[2]))) };
            has_bg = true;
            env.*.*.ReleaseIntArrayElements.?(env, bg_rgb, values, c.JNI_ABORT);
        }
    }
    if (cursor_rgb != null and env.*.*.GetArrayLength.?(env, cursor_rgb) >= 3) {
        var is_copy: c.jboolean = c.JNI_FALSE;
        const values = env.*.*.GetIntArrayElements.?(env, cursor_rgb, &is_copy);
        if (values != null) {
            cursor_vals = .{ @intCast(@max(0, @min(255, values[0]))), @intCast(@max(0, @min(255, values[1]))), @intCast(@max(0, @min(255, values[2]))) };
            has_cursor = true;
            env.*.*.ReleaseIntArrayElements.?(env, cursor_rgb, values, c.JNI_ABORT);
        }
    }
    if (palette_rgb != null and env.*.*.GetArrayLength.?(env, palette_rgb) >= 256 * 3) {
        var is_copy: c.jboolean = c.JNI_FALSE;
        const bytes = env.*.*.GetByteArrayElements.?(env, palette_rgb, &is_copy);
        if (bytes != null) {
            @memcpy(palette_vals[0 .. 256 * 3], @as([*]u8, @ptrCast(bytes))[0 .. 256 * 3]);
            has_palette = true;
            env.*.*.ReleaseByteArrayElements.?(env, palette_rgb, bytes, c.JNI_ABORT);
        }
    }

    heeler_apply_default_colors(handle, has_fg, &fg_vals[0], has_bg, &bg_vals[0], has_cursor, &cursor_vals[0], has_palette, &palette_vals[0]);
}

fn writeIntLe(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    const le_value = std.mem.nativeToLittle(T, value);
    @memcpy(buffer[offset .. offset + @sizeOf(T)], std.mem.asBytes(&le_value));
}

fn jniByteArrayFromBytes(env: *c.JNIEnv, bytes: []const u8) c.jbyteArray {
    const out = jniNewByteArray(env, @intCast(bytes.len));
    if (out != null and bytes.len > 0) {
        env.*.*.SetByteArrayRegion.?(env, out, 0, @intCast(bytes.len), @ptrCast(bytes.ptr));
    }
    return out;
}

export fn shm_open(name: [*:0]const u8, oflag: c_int, mode: c_uint) callconv(.c) c_int {
    _ = name;
    _ = oflag;
    _ = mode;
    return -1;
}

export fn shm_unlink(name: [*:0]const u8) callconv(.c) c_int {
    _ = name;
    return -1;
}

fn resolvedStyle(render_cell: ghostty.RenderState.Cell) ghostty.Style {
    return if (render_cell.raw.style_id != 0) render_cell.style else .{};
}

fn resolvedCodepoint(render_cell: ghostty.RenderState.Cell) u32 {
    if (render_cell.raw.wide == .spacer_tail or render_cell.raw.wide == .spacer_head) return 32;

    // page.Cell.codepoint() is always the base codepoint for this cell.
    // For .codepoint_grapheme cells, render_cell.grapheme stores only the
    // appended codepoints, so taking grapheme[0] would drop the base
    // character (e.g. keycaps would lose the digit and ZWJ chains could
    // degrade to U+200D as the visible codepoint).
    const cp = render_cell.raw.codepoint();
    if (cp == KITTY_PLACEHOLDER_CP) return 32;
    return if (cp == 0) 32 else cp;
}

fn cellHasExtras(render_cell: ghostty.RenderState.Cell) bool {
    if (render_cell.raw.wide == .spacer_tail or render_cell.raw.wide == .spacer_head) return false;
    // Placeholder cells carry row/column diacritics as grapheme extras; drop
    // them so the combining marks aren't painted (see KITTY_PLACEHOLDER_CP).
    if (render_cell.raw.codepoint() == KITTY_PLACEHOLDER_CP) return false;
    return render_cell.raw.content_tag == .codepoint_grapheme and render_cell.grapheme.len > 0;
}

export fn heeler_build_text_snapshot(handle: c.jlong, out_size: [*c]usize) callconv(.c) ?[*]u8 {
    const terminal = heelerFromHandle(handle) orelse return null;
    if (out_size == null) return null;

    const t_start = std.time.nanoTimestamp();
    update_render_state(terminal);
    const t_after_update = std.time.nanoTimestamp();

    const cols: usize = terminal.render_state.cols;
    const rows: usize = terminal.render_state.rows;
    const header_size = SNAPSHOT_HEADER_I32_COUNT * @sizeOf(i32);
    const grid_size = cols * rows * SNAPSHOT_CELL_SIZE_BYTES;
    const base_total_size = header_size + grid_size;

    var buffer = ensureListSize(&terminal.snapshot_buffer, base_total_size) orelse return null;

    writeIntLe(i32, buffer[0..base_total_size], 0, @intCast(cols));
    writeIntLe(i32, buffer[0..base_total_size], 4, @intCast(rows));
    writeIntLe(i32, buffer[0..base_total_size], 8, if (terminal.render_state.cursor.viewport) |cursor| cursor.x else -1);
    writeIntLe(i32, buffer[0..base_total_size], 12, if (terminal.render_state.cursor.viewport) |cursor| cursor.y else -1);
    writeIntLe(i32, buffer[0..base_total_size], 16, if (terminal.render_state.cursor.visible and terminal.render_state.cursor.viewport != null) 1 else 0);
    writeIntLe(i32, buffer[0..base_total_size], 20, terminal.render_state.colors.background.r);
    writeIntLe(i32, buffer[0..base_total_size], 24, terminal.render_state.colors.background.g);
    writeIntLe(i32, buffer[0..base_total_size], 28, terminal.render_state.colors.background.b);
    writeIntLe(i32, buffer[0..base_total_size], 32, terminal.render_state.colors.foreground.r);
    writeIntLe(i32, buffer[0..base_total_size], 36, terminal.render_state.colors.foreground.g);
    writeIntLe(i32, buffer[0..base_total_size], 40, terminal.render_state.colors.foreground.b);
    // extras_offset gets patched after we know whether extras exist.
    writeIntLe(i32, buffer[0..base_total_size], 44, 0);
    // viewport_scroll_y: stable screen.y of the content currently at
    // viewport row 0. The host subtracts this across snapshots to remap a
    // selection anchor that must track content, not screen position.
    const viewport_scroll_y: i32 = blk: {
        const pages = &terminal.terminal.screens.active.pages;
        const vp_top = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse break :blk 0;
        break :blk @intCast(vp_top.screen.y);
    };
    writeIntLe(i32, buffer[0..base_total_size], 48, viewport_scroll_y);
    // app_handles_selection_drag: 1 only for drag-reporting mouse modes
    // (DECSET 1002/1003). Click-only mouse modes still allow the host to keep
    // its own long-press selection behavior.
    const app_handles_selection_drag: i32 = if (appHandlesSelectionDrag(terminal.terminal.flags.mouse_event)) 1 else 0;
    writeIntLe(i32, buffer[0..base_total_size], 52, app_handles_selection_drag);

    terminal.snapshot_extras_scratch.clearRetainingCapacity();
    var extras_records: usize = 0;
    var non_blank_cells: usize = 0;

    const row_slice = terminal.render_state.row_data.slice();
    const row_cells = row_slice.items(.cells);
    var cell_index: usize = 0;
    for (row_cells[0..rows]) |cells| {
        const cell_slice = cells.slice();
        const render_cells = cell_slice.items(.raw);
        const graphemes = cell_slice.items(.grapheme);
        const styles = cell_slice.items(.style);
        var x: usize = 0;
        while (x < cols) : (x += 1) {
            const base = header_size + cell_index * SNAPSHOT_CELL_SIZE_BYTES;
            const this_index = cell_index;
            cell_index += 1;

            const render_cell: ghostty.RenderState.Cell = .{
                .raw = render_cells[x],
                .grapheme = graphemes[x],
                .style = styles[x],
            };
            const style = resolvedStyle(render_cell);
            const fg = style.fg(.{
                .default = terminal.render_state.colors.foreground,
                .palette = &terminal.render_state.colors.palette,
            });
            const bg = style.bg(&render_cell.raw, &terminal.render_state.colors.palette) orelse terminal.render_state.colors.background;

            var flags: u8 = 0;
            if (style.flags.bold) flags |= 1 << 0;
            if (style.flags.italic) flags |= 1 << 1;
            if (style.flags.underline != .none) flags |= 1 << 2;
            if (style.flags.inverse) flags |= 1 << 3;
            if (style.flags.blink) flags |= 1 << 4;
            if (style.flags.faint) flags |= 1 << 5;
            if (render_cell.raw.wide == .spacer_tail or render_cell.raw.wide == .spacer_head) {
                flags |= CELL_FLAG_SPACER;
            }

            if (cellHasExtras(render_cell)) {
                flags |= CELL_FLAG_HAS_GRAPHEME;
                std.debug.assert(this_index <= std.math.maxInt(u32));
                std.debug.assert(render_cell.grapheme.len <= std.math.maxInt(u32));
                terminal.snapshot_extras_scratch.append(allocator, @intCast(this_index)) catch return null;
                terminal.snapshot_extras_scratch.append(allocator, @intCast(render_cell.grapheme.len)) catch return null;
                for (render_cell.grapheme) |cp| {
                    terminal.snapshot_extras_scratch.append(allocator, @intCast(cp)) catch return null;
                }
                extras_records += 1;
            }

            const serialized_cp = resolvedCodepoint(render_cell);
            if (serialized_cp != 0 and serialized_cp != 32) non_blank_cells += 1;
            writeIntLe(i32, buffer[0..base_total_size], base, @intCast(serialized_cp));
            buffer[base + 4] = fg.r;
            buffer[base + 5] = fg.g;
            buffer[base + 6] = fg.b;
            buffer[base + 7] = bg.r;
            buffer[base + 8] = bg.g;
            buffer[base + 9] = bg.b;
            buffer[base + 10] = flags;
        }
    }

    if (extras_records == 0) {
        out_size.* = base_total_size;

        const t_end = std.time.nanoTimestamp();
        maybeLogSnapshotPerf(
            terminal,
            cols,
            rows,
            extras_records,
            non_blank_cells,
            base_total_size,
            t_after_update - t_start,
            t_end - t_after_update,
            t_end - t_start,
        );
        return buffer;
    }

    // Extras section layout:
    //   u32 record_count
    //   For each record:
    //     u32 cell_index
    //     u32 count
    //     u32[count] codepoints
    const extras_offset: usize = base_total_size;
    const extras_size: usize = @sizeOf(u32) + terminal.snapshot_extras_scratch.items.len * @sizeOf(u32);
    const total_size = base_total_size + extras_size;

    buffer = ensureListSize(&terminal.snapshot_buffer, total_size) orelse return null;
    writeIntLe(i32, buffer[0..total_size], 44, @intCast(extras_offset));

    var write_ptr: usize = extras_offset;
    writeIntLe(u32, buffer[0..total_size], write_ptr, @intCast(extras_records));
    write_ptr += @sizeOf(u32);

    for (terminal.snapshot_extras_scratch.items) |word| {
        writeIntLe(u32, buffer[0..total_size], write_ptr, word);
        write_ptr += @sizeOf(u32);
    }

    std.debug.assert(write_ptr == total_size);

    out_size.* = total_size;

    const t_end = std.time.nanoTimestamp();
    maybeLogSnapshotPerf(
        terminal,
        cols,
        rows,
        extras_records,
        non_blank_cells,
        total_size,
        t_after_update - t_start,
        t_end - t_after_update,
        t_end - t_start,
    );
    return buffer;
}

fn placementViewportPos(
    terminal: *HeelerTerminal,
    placement: ghostty.kitty.graphics.ImageStorage.Placement,
    image: ghostty.kitty.graphics.Image,
) ?struct { col: i32, row: i32 } {
    const pin = switch (placement.location) {
        .pin => |p| p,
        .virtual => return null,
    };

    const pages = &terminal.terminal.screens.active.pages;
    const pin_screen = pages.pointFromPin(.screen, pin.*) orelse return null;
    const viewport_top = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const vp_row: i32 = @as(i32, @intCast(pin_screen.screen.y)) - @as(i32, @intCast(viewport_top.screen.y));
    const vp_col: i32 = @as(i32, @intCast(pin_screen.screen.x)) - @as(i32, @intCast(viewport_top.screen.x));
    const grid_size = placement.gridSize(image, &terminal.terminal);
    if (vp_row + @as(i32, @intCast(grid_size.rows)) <= 0 or vp_row >= @as(i32, @intCast(terminal.terminal.rows))) {
        return null;
    }
    return .{ .col = vp_col, .row = vp_row };
}

fn placementSourceRect(
    placement: ghostty.kitty.graphics.ImageStorage.Placement,
    image_w: u32,
    image_h: u32,
) struct { x: u32, y: u32, width: u32, height: u32 } {
    const x = @min(placement.source_x, image_w);
    const y = @min(placement.source_y, image_h);
    const w = @min(if (placement.source_width > 0) placement.source_width else image_w, image_w - x);
    const h = @min(if (placement.source_height > 0) placement.source_height else image_h, image_h - y);
    return .{ .x = x, .y = y, .width = w, .height = h };
}

fn allocRgba(pixel_count: usize) ?[]u8 {
    return allocator.alloc(u8, pixel_count * 4) catch null;
}

fn prepareImageData(image_id: u32, image: ghostty.kitty.graphics.Image) ?PreparedImageData {
    var data_ptr: [*c]const u8 = if (image.data.len == 0) null else image.data.ptr;
    var data_len: usize = image.data.len;
    var img_w = image.width;
    var img_h = image.height;
    var free_mode: ImageFreeMode = .none;
    var expected_len: usize = @as(usize, img_w) * @as(usize, img_h) * 4;
    const pixel_count = @as(usize, img_w) * @as(usize, img_h);

    switch (image.format) {
        .rgb => {
            const rgb_len = @as(usize, img_w) * @as(usize, img_h) * 3;
            if (data_ptr == null or data_len < rgb_len) {
                logWarn("kitty placement skipped image_id={} reason=short_rgb data_len={} need={}", .{ image_id, data_len, rgb_len });
                return null;
            }
            const rgba = allocRgba(pixel_count) orelse return null;
            var i: usize = 0;
            var j: usize = 0;
            while (i < rgb_len) : ({
                i += 3;
                j += 4;
            }) {
                rgba[j + 0] = data_ptr[i + 0];
                rgba[j + 1] = data_ptr[i + 1];
                rgba[j + 2] = data_ptr[i + 2];
                rgba[j + 3] = 0xff;
            }
            data_ptr = rgba.ptr;
            data_len = expected_len;
            free_mode = .malloc_buf;
        },
        .gray => {
            const gray_len = @as(usize, img_w) * @as(usize, img_h);
            if (data_ptr == null or data_len < gray_len) {
                logWarn("kitty placement skipped image_id={} reason=short_gray data_len={} need={}", .{ image_id, data_len, gray_len });
                return null;
            }
            const rgba = allocRgba(pixel_count) orelse return null;
            var i: usize = 0;
            var j: usize = 0;
            while (i < gray_len) : ({
                i += 1;
                j += 4;
            }) {
                const g = data_ptr[i];
                rgba[j + 0] = g;
                rgba[j + 1] = g;
                rgba[j + 2] = g;
                rgba[j + 3] = 0xff;
            }
            data_ptr = rgba.ptr;
            data_len = expected_len;
            free_mode = .malloc_buf;
        },
        .gray_alpha => {
            const ga_len = @as(usize, img_w) * @as(usize, img_h) * 2;
            if (data_ptr == null or data_len < ga_len) {
                logWarn("kitty placement skipped image_id={} reason=short_gray_alpha data_len={} need={}", .{ image_id, data_len, ga_len });
                return null;
            }
            const rgba = allocRgba(pixel_count) orelse return null;
            var i: usize = 0;
            var j: usize = 0;
            while (i < ga_len) : ({
                i += 2;
                j += 4;
            }) {
                const g = data_ptr[i];
                rgba[j + 0] = g;
                rgba[j + 1] = g;
                rgba[j + 2] = g;
                rgba[j + 3] = data_ptr[i + 1];
            }
            data_ptr = rgba.ptr;
            data_len = expected_len;
            free_mode = .malloc_buf;
        },
        .png => {
            if (data_ptr == null or data_len == 0) {
                logWarn("kitty placement skipped image_id={} reason=empty_png", .{image_id});
                return null;
            }
            var png_w: u32 = 0;
            var png_h: u32 = 0;
            const rgba = decodePngRgba(data_ptr, data_len, &png_w, &png_h) orelse return null;
            if (png_w == 0 or png_h == 0) {
                freeRgbaPixels(rgba, png_w, png_h);
                logWarn("kitty placement skipped image_id={} reason=png_decode_zero", .{image_id});
                return null;
            }
            img_w = png_w;
            img_h = png_h;
            expected_len = @as(usize, img_w) * @as(usize, img_h) * 4;
            data_ptr = rgba;
            data_len = expected_len;
            free_mode = .malloc_buf;
        },
        .rgba => {
            if (data_ptr == null or data_len < expected_len) {
                logWarn("kitty placement skipped image_id={} reason=short_rgba data_len={} need={}", .{ image_id, data_len, expected_len });
                return null;
            }
        },
    }

    if (data_ptr == null or data_len < expected_len) {
        logWarn("kitty placement skipped image_id={} reason=short_final data_len={} need={}", .{ image_id, data_len, expected_len });
        return null;
    }

    return .{
        .data_ptr = data_ptr,
        .data_len = expected_len,
        .img_w = img_w,
        .img_h = img_h,
        .free_mode = free_mode,
    };
}

export fn heeler_build_image_snapshot(handle: c.jlong, out_size: [*c]usize) callconv(.c) ?[*]u8 {
    const terminal = heelerFromHandle(handle) orelse return null;
    if (out_size == null) return null;
    logKittyState("image_snapshot_begin", terminal);

    var placements: [MAX_KITTY_IMAGES]PlacementInfo = undefined;
    var count: usize = 0;
    var has_virtual = false;
    var it = terminal.terminal.screens.active.kitty_images.placements.iterator();
    while (it.next()) |entry| {
        if (count >= MAX_KITTY_IMAGES) break;

        const placement = entry.value_ptr.*;
        if (placement.location == .virtual) {
            has_virtual = true;
            continue;
        }

        const image = terminal.terminal.screens.active.kitty_images.imageById(entry.key_ptr.image_id) orelse continue;
        const viewport = placementViewportPos(terminal, placement, image) orelse {
            logWarn(
                "kitty placement skipped image_id={} reason=no_viewport location_virtual={}",
                .{ entry.key_ptr.image_id, placement.location == .virtual },
            );
            continue;
        };
        const prepared = prepareImageData(entry.key_ptr.image_id, image) orelse continue;
        const rect = placementSourceRect(placement, prepared.img_w, prepared.img_h);
        const orig_grid_size = placement.gridSize(image, &terminal.terminal);
        var grid_size = orig_grid_size;
        if (orig_grid_size.cols == 0 or orig_grid_size.rows == 0) {
            const cell_w: u32 = @max(terminal.cell_width, 1);
            const cell_h: u32 = @max(terminal.cell_height, 1);
            const width_with_offset: u32 = rect.width + placement.x_offset;
            const height_with_offset: u32 = rect.height + placement.y_offset;
            grid_size = .{
                .cols = @max(@as(u32, 1), (width_with_offset + cell_w - 1) / cell_w),
                .rows = @max(@as(u32, 1), (height_with_offset + cell_h - 1) / cell_h),
            };
        }
        placements[count] = .{
            .cell_col = viewport.col,
            .cell_row = viewport.row,
            .cell_x_offset = placement.x_offset,
            .cell_y_offset = placement.y_offset,
            // Direct placement: image fills its whole cell grid (no aspect-fit).
            .dest_w = grid_size.cols * terminal.cell_width,
            .dest_h = grid_size.rows * terminal.cell_height,
            .src_x = rect.x,
            .src_y = rect.y,
            .src_w = rect.width,
            .src_h = rect.height,
            .img_w = prepared.img_w,
            .img_h = prepared.img_h,
            .data_ptr = prepared.data_ptr,
            .data_len = prepared.data_len,
            .free_mode = prepared.free_mode,
        };
        count += 1;
    }

    if (has_virtual and count < MAX_KITTY_IMAGES) {
        const pages = &terminal.terminal.screens.active.pages;
        const top = pages.getTopLeft(.viewport);
        const bot = pages.getBottomRight(.viewport) orelse top;
        var virtual_it = ghostty.kitty.graphics.unicode.placementIterator(top, bot);
        while (count < MAX_KITTY_IMAGES) {
            const virtual_placement = virtual_it.next() orelse break;
            const image = terminal.terminal.screens.active.kitty_images.imageById(virtual_placement.image_id) orelse continue;
            const rendered = virtual_placement.renderPlacement(
                &terminal.terminal.screens.active.kitty_images,
                &image,
                terminal.cell_width,
                terminal.cell_height,
            ) catch |err| {
                logWarn("kitty virtual placement skipped image_id={} reason=render_failed err={}", .{ virtual_placement.image_id, err });
                continue;
            };
            if (rendered.dest_width == 0 or rendered.dest_height == 0) continue;

            const viewport = pages.pointFromPin(.viewport, rendered.top_left) orelse {
                logWarn("kitty virtual placement skipped image_id={} reason=no_viewport", .{virtual_placement.image_id});
                continue;
            };

            const prepared = prepareImageData(virtual_placement.image_id, image) orelse continue;
            placements[count] = .{
                .cell_col = @intCast(viewport.viewport.x),
                .cell_row = @intCast(viewport.viewport.y),
                // Virtual placement: libghostty aspect-fits the image into the
                // grid and centers it via offset_x/offset_y; dest_width/height is
                // the resulting scaled size the offsets are measured against.
                .cell_x_offset = rendered.offset_x,
                .cell_y_offset = rendered.offset_y,
                .dest_w = rendered.dest_width,
                .dest_h = rendered.dest_height,
                .src_x = rendered.source_x,
                .src_y = rendered.source_y,
                .src_w = rendered.source_width,
                .src_h = rendered.source_height,
                .img_w = prepared.img_w,
                .img_h = prepared.img_h,
                .data_ptr = prepared.data_ptr,
                .data_len = prepared.data_len,
                .free_mode = prepared.free_mode,
            };
            count += 1;
        }
    }

    if (count == 0) {
        out_size.* = 0;
        return null;
    }

    var total: usize = 4;
    for (placements[0..count]) |p| total += IMAGE_HEADER_BYTES + p.data_len;
    const buf = ensureListSize(&terminal.image_snapshot_buffer, total) orelse {
        for (placements[0..count]) |p| switch (p.free_mode) {
            .malloc_buf => allocator.free(@constCast(p.data_ptr[0..p.data_len])),
            .none => {},
        };
        return null;
    };

    writeIntLe(i32, buf[0..total], 0, @intCast(count));
    var offset: usize = 4;
    for (placements[0..count]) |p| {
        writeIntLe(i32, buf[0..total], offset + 0, p.cell_col);
        writeIntLe(i32, buf[0..total], offset + 4, p.cell_row);
        writeIntLe(u32, buf[0..total], offset + 8, p.cell_x_offset);
        writeIntLe(u32, buf[0..total], offset + 12, p.cell_y_offset);
        writeIntLe(u32, buf[0..total], offset + 16, p.dest_w);
        writeIntLe(u32, buf[0..total], offset + 20, p.dest_h);
        writeIntLe(u32, buf[0..total], offset + 24, p.src_x);
        writeIntLe(u32, buf[0..total], offset + 28, p.src_y);
        writeIntLe(u32, buf[0..total], offset + 32, p.src_w);
        writeIntLe(u32, buf[0..total], offset + 36, p.src_h);
        writeIntLe(u32, buf[0..total], offset + 40, p.img_w);
        writeIntLe(u32, buf[0..total], offset + 44, p.img_h);
        writeIntLe(u32, buf[0..total], offset + 48, @intCast(p.data_len));
        @memcpy(buf[offset + IMAGE_HEADER_BYTES .. offset + IMAGE_HEADER_BYTES + p.data_len], p.data_ptr[0..p.data_len]);
        offset += IMAGE_HEADER_BYTES + p.data_len;
        switch (p.free_mode) {
            .malloc_buf => allocator.free(@constCast(p.data_ptr[0..p.data_len])),
            .none => {},
        }
    }

    out_size.* = total;
    return buf;
}

fn ghosttyMouseEncodeOptions(terminal: *HeelerTerminal, any_button_pressed: bool, track_last_cell: bool, last_cell: *?ghostty.point.Coordinate) ghostty.input.MouseEncodeOptions {
    var opts = ghostty.input.MouseEncodeOptions{
        .event = terminal.terminal.flags.mouse_event,
        .format = terminal.terminal.flags.mouse_format,
        .size = .{
            .screen = .{
                .width = terminal.mouse_size.screen_width,
                .height = terminal.mouse_size.screen_height,
            },
            .cell = .{
                .width = @max(terminal.mouse_size.cell_width, 1),
                .height = @max(terminal.mouse_size.cell_height, 1),
            },
            .padding = .{
                .top = terminal.mouse_size.padding_top,
                .bottom = terminal.mouse_size.padding_bottom,
                .left = terminal.mouse_size.padding_left,
                .right = terminal.mouse_size.padding_right,
            },
        },
        .any_button_pressed = any_button_pressed,
    };
    if (track_last_cell) opts.last_cell = last_cell;
    return opts;
}

export fn heeler_poll_title_ptr(handle: c.jlong) callconv(.c) ?[*:0]const u8 {
    const terminal = heelerFromHandle(handle) orelse return null;
    if (!terminal.title_dirty) return null;
    terminal.title_dirty = false;
    return if (terminal.title) |title| @ptrCast(title) else "";
}

export fn heeler_poll_pwd_ptr(handle: c.jlong) callconv(.c) ?[*:0]const u8 {
    const terminal = heelerFromHandle(handle) orelse return null;
    if (!terminal.pwd_dirty) return null;
    terminal.pwd_dirty = false;
    return if (terminal.pwd) |pwd| @ptrCast(pwd) else "";
}

fn heeler_poll_clipboard(handle: c.jlong) ?[]const u8 {
    const terminal = heelerFromHandle(handle) orelse return null;
    if (!terminal.clipboard_dirty) return null;
    terminal.clipboard_dirty = false;
    return if (terminal.clipboard) |clipboard| clipboard[0..terminal.clipboard_len] else &.{};
}

export fn heeler_drain_bell_count(handle: c.jlong) callconv(.c) c.jint {
    const terminal = heelerFromHandle(handle) orelse return 0;
    const count = terminal.bell_count;
    terminal.bell_count = 0;
    return @intCast(count);
}

export fn heeler_apply_default_colors(handle: c.jlong, has_fg: bool, fg: [*c]const u8, has_bg: bool, bg: [*c]const u8, has_cursor: bool, cursor: [*c]const u8, has_palette: bool, palette: [*c]const u8) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;

    terminal.terminal.colors.foreground = if (has_fg) ghostty.color.DynamicRGB.init(rgbFromBytes(fg)) else .unset;
    terminal.terminal.colors.background = if (has_bg) ghostty.color.DynamicRGB.init(rgbFromBytes(bg)) else .unset;
    terminal.terminal.colors.cursor = if (has_cursor) ghostty.color.DynamicRGB.init(rgbFromBytes(cursor)) else .unset;
    if (has_palette) {
        var colors: ghostty.color.Palette = undefined;
        for (0..256) |i| {
            const off = i * 3;
            colors[i] = .{ .r = palette[off], .g = palette[off + 1], .b = palette[off + 2] };
        }
        terminal.terminal.colors.palette = .init(colors);
    } else {
        terminal.terminal.colors.palette = .default;
    }

    update_render_state(terminal);
}

export fn heeler_set_color_scheme(handle: c.jlong, scheme: c.jint) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;
    terminal.color_scheme = if (scheme == 0) .light else .dark;
    terminal.color_scheme_set = true;
}

export fn heeler_set_mouse_encoding_size(handle: c.jlong, screen_width: c.jint, screen_height: c.jint, cell_width: c.jint, cell_height: c.jint, padding_top: c.jint, padding_bottom: c.jint, padding_left: c.jint, padding_right: c.jint) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;
    terminal.mouse_size = .{
        .screen_width = @intCast(clampI32(screen_width, 1, 1)),
        .screen_height = @intCast(clampI32(screen_height, 1, 1)),
        .cell_width = @intCast(clampI32(cell_width, 1, 1)),
        .cell_height = @intCast(clampI32(cell_height, 1, 1)),
        .padding_top = @intCast(clampI32(padding_top, 0, 0)),
        .padding_bottom = @intCast(clampI32(padding_bottom, 0, 0)),
        .padding_left = @intCast(clampI32(padding_left, 0, 0)),
        .padding_right = @intCast(clampI32(padding_right, 0, 0)),
    };
    terminal.mouse_size_set = true;
}

export fn heeler_write_remote(handle: c.jlong, data_ptr: [*c]const u8, data_len: usize) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;
    if (data_ptr == null or data_len == 0) return;
    const data = data_ptr[0..data_len];
    terminal.stream.nextSlice(data);
    update_render_state(terminal);
}

export fn heeler_resize(handle: c.jlong, cols: c.jint, rows: c.jint, cell_width: c.jint, cell_height: c.jint) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;
    const new_cols: u16 = @intCast(clampI32(cols, 1, terminal.cols));
    const new_rows: u16 = @intCast(clampI32(rows, 1, terminal.rows));
    terminal.terminal.resize(allocator, new_cols, new_rows) catch return;
    terminal.cols = new_cols;
    terminal.rows = new_rows;
    terminal.cell_width = @intCast(clampI32(cell_width, 1, 1));
    terminal.cell_height = @intCast(clampI32(cell_height, 1, 1));
    terminal.terminal.width_px = @as(u32, new_cols) * terminal.cell_width;
    terminal.terminal.height_px = @as(u32, new_rows) * terminal.cell_height;

    terminal.terminal.modes.set(.synchronized_output, false);

    // Emit a DEC 2048 in-band size report on resize. TUIs like Textual disable
    // their SIGWINCH fallback once mode 2048 is on and rely on this report.
    // Report form: ESC [ 48 ; rows ; cols ; height_px ; width_px t
    if (terminal.terminal.modes.get(.in_band_size_reports)) {
        var report_buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&report_buf, "\x1b[48;{d};{d};{d};{d}t", .{
            new_rows,
            new_cols,
            @as(u32, new_rows) * terminal.cell_height,
            @as(u32, new_cols) * terminal.cell_width,
        })) |report| {
            appendPtyWrite(terminal, report);
        } else |_| {}
    }

    update_render_state(terminal);
}

export fn heeler_scroll(handle: c.jlong, delta: c.jint, x: c.jfloat, y: c.jfloat) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;

    // Check if we're in alternate screen mode (used by vim, tmux, less, etc.)
    const alt_screen = terminal.terminal.modes.get(.alt_screen);
    const alt_screen_legacy = terminal.terminal.modes.get(.alt_screen_legacy);
    const alt_screen_1049 = terminal.terminal.modes.get(.alt_screen_save_cursor_clear_enter);
    const in_alt_screen = alt_screen or alt_screen_legacy or alt_screen_1049;

    // Check if mouse reporting is enabled (any mode other than none)
    const mouse_reporting_enabled = terminal.terminal.flags.mouse_event != .none;

    if (in_alt_screen or mouse_reporting_enabled) {
        // Send mouse scroll events to the application.
        // Negative delta = scroll up (older content) → button 4.
        // Positive delta = scroll down (newer content) → button 5.
        const button: u8 = if (delta < 0) 4 else 5;
        const scroll_count: usize = @max(1, @abs(delta));

        // Use the gesture position so mouse-aware programs like tmux route the
        // wheel event to the pane under the user's finger.
        const max_x: f32 = @as(f32, @floatFromInt(@max(terminal.terminal.width_px, 1) - 1));
        const max_y: f32 = @as(f32, @floatFromInt(@max(terminal.terminal.height_px, 1) - 1));
        const scroll_x: f32 = @min(@max(@as(f32, x), 0), max_x);
        const scroll_y: f32 = @min(@max(@as(f32, y), 0), max_y);

        var buf: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var last_cell: ?ghostty.point.Coordinate = null;
        const opts = ghosttyMouseEncodeOptions(terminal, false, true, &last_cell);

        // Send scroll_count press/release pairs to match scroll magnitude.
        var i: usize = 0;
        while (i < scroll_count) : (i += 1) {
            const press_event: ghostty.input.MouseEncodeEvent = .{
                .action = .press,
                .button = @enumFromInt(button),
                .mods = .{},
                .pos = .{ .x = scroll_x, .y = scroll_y },
            };
            ghostty.input.encodeMouse(&writer, press_event, opts) catch {};

            const release_event: ghostty.input.MouseEncodeEvent = .{
                .action = .release,
                .button = @enumFromInt(button),
                .mods = .{},
                .pos = .{ .x = scroll_x, .y = scroll_y },
            };
            ghostty.input.encodeMouse(&writer, release_event, opts) catch {};
        }

        // Send encoded events to PTY
        const encoded = writer.buffered();
        if (encoded.len > 0) {
            appendPtyWrite(terminal, encoded);
        }
    } else {
        // Normal scrollback scrolling
        terminal.terminal.scrollViewport(.{ .delta = @intCast(delta) });
    }

    update_render_state(terminal);
}

export fn heeler_scroll_to_active(handle: c.jlong) callconv(.c) void {
    const terminal = heelerFromHandle(handle) orelse return;
    terminal.terminal.scrollViewport(.{ .bottom = {} });
    update_render_state(terminal);
}

const default_word_boundaries: [20]u21 = .{
    0,   ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',',
    '(', ')', '[',  ']',  '{', '}',   '<', '>', '$',
};

fn viewportCellToPin(terminal: *HeelerTerminal, vp_x: u32, vp_y: u32) ?ghostty.Pin {
    const pages = &terminal.terminal.screens.active.pages;
    const vp_top_point = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    return pages.pin(.{ .screen = .{
        .x = @as(u16, @intCast(vp_x)),
        .y = vp_top_point.screen.y + vp_y,
    } });
}

/// Resolve an absolute screen-space cell index (screen.y * cols + screen.x)
/// to a pin, without adding the viewport top offset. Used for content-tracking
/// selections that span off-screen scrollback.
fn screenCellToPin(terminal: *HeelerTerminal, screen_cell: i64) ?ghostty.Pin {
    if (screen_cell < 0) return null;
    const cols: i64 = @intCast(terminal.render_state.cols);
    if (cols <= 0) return null;
    const screen_x: u32 = @intCast(@rem(screen_cell, cols));
    const screen_y: u32 = @intCast(@divTrunc(screen_cell, cols));
    const pages = &terminal.terminal.screens.active.pages;
    return pages.pin(.{ .screen = .{
        .x = @as(u16, @intCast(screen_x)),
        .y = @intCast(screen_y),
    } });
}

fn selectionTextFromPins(
    terminal: *HeelerTerminal,
    start_pin: ghostty.Pin,
    end_pin: ghostty.Pin,
    alloc: std.mem.Allocator,
) ![:0]const u8 {
    const sel = ghostty.Selection.init(start_pin, end_pin, false);
    defer sel.deinit(terminal.terminal.screens.active);
    return terminal.terminal.screens.active.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_formatSelectionRange(
    env: *c.JNIEnv,
    thiz: c.jobject,
    handle: c.jlong,
    start_cell: c.jint,
    end_cell: c.jint,
) callconv(.c) c.jstring {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return null;
    const cols: c.jint = @intCast(terminal.render_state.cols);
    if (cols <= 0) return null;

    const start_x: u32 = @intCast(@max(0, @rem(start_cell, cols)));
    const start_y: u32 = @intCast(@max(0, @divTrunc(start_cell, cols)));
    const end_x: u32 = @intCast(@max(0, @rem(end_cell, cols)));
    const end_y: u32 = @intCast(@max(0, @divTrunc(end_cell, cols)));

    const start_pin = viewportCellToPin(terminal, start_x, start_y) orelse return null;
    const end_pin = viewportCellToPin(terminal, end_x, end_y) orelse return null;

    const text = selectionTextFromPins(terminal, start_pin, end_pin, allocator) catch return null;
    defer allocator.free(text);
    return jniNewStringUTF(env, text.ptr);
}

/// Like nativeFormatSelectionRange but takes absolute screen-space cell
/// indices (screen.y * cols + screen.x) instead of viewport-space ones.
/// Used for content-tracking selections that span off-screen scrollback —
/// the host converts viewport-space to screen-space via viewportScrollY so
/// the full selected range (including scrolled-away content) is extracted.
export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_formatSelectionScreenRange(
    env: *c.JNIEnv,
    thiz: c.jobject,
    handle: c.jlong,
    start_screen_cell: c.jint,
    end_screen_cell: c.jint,
) callconv(.c) c.jstring {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return null;
    if (terminal.render_state.cols <= 0) return null;

    const start_pin = screenCellToPin(terminal, start_screen_cell) orelse return null;
    const end_pin = screenCellToPin(terminal, end_screen_cell) orelse return null;

    const text = selectionTextFromPins(terminal, start_pin, end_pin, allocator) catch return null;
    defer allocator.free(text);
    return jniNewStringUTF(env, text.ptr);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_selectWordAt(
    env: *c.JNIEnv,
    thiz: c.jobject,
    handle: c.jlong,
    cell_x: c.jint,
    cell_y: c.jint,
) callconv(.c) c.jstring {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return null;

    const pin = viewportCellToPin(terminal, @intCast(@max(0, cell_x)), @intCast(@max(0, cell_y))) orelse return null;

    const sel = terminal.terminal.screens.active.selectWord(pin, &default_word_boundaries) orelse return null;
    defer sel.deinit(terminal.terminal.screens.active);

    const text = terminal.terminal.screens.active.selectionString(allocator, .{
        .sel = sel,
        .trim = true,
    }) catch return null;
    defer allocator.free(text);
    return jniNewStringUTF(env, text.ptr);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_selectLineAt(
    env: *c.JNIEnv,
    thiz: c.jobject,
    handle: c.jlong,
    cell_x: c.jint,
    cell_y: c.jint,
) callconv(.c) c.jstring {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return null;

    const pin = viewportCellToPin(terminal, @intCast(@max(0, cell_x)), @intCast(@max(0, cell_y))) orelse return null;

    const sel = terminal.terminal.screens.active.selectLine(.{
        .pin = pin,
        .semantic_prompt_boundary = true,
    }) orelse return null;
    defer sel.deinit(terminal.terminal.screens.active);

    const text = terminal.terminal.screens.active.selectionString(allocator, .{
        .sel = sel,
        .trim = true,
    }) catch return null;
    defer allocator.free(text);
    return jniNewStringUTF(env, text.ptr);
}

export fn Java_dev_bybee_heeler_core_terminal_NativeTerminal_selectAll(
    env: *c.JNIEnv,
    thiz: c.jobject,
    handle: c.jlong,
) callconv(.c) c.jstring {
    _ = thiz;
    const terminal = heelerFromHandle(handle) orelse return null;

    const sel = terminal.terminal.screens.active.selectAll() orelse return null;
    defer sel.deinit(terminal.terminal.screens.active);

    const text = terminal.terminal.screens.active.selectionString(allocator, .{
        .sel = sel,
        .trim = true,
    }) catch return null;
    defer allocator.free(text);
    return jniNewStringUTF(env, text.ptr);
}
