package dev.bybee.heeler.core.terminal

import java.nio.ByteBuffer

/**
 * JNI surface over the ghostty-vt snapshot bridge
 * (`android/native/src/bridge/heeler_terminal.zig`). Adapted from chuchu's
 * GhosttyBridge (MIT, see android/native/NOTICE.md); symbol names are
 * `Java_dev_bybee_heeler_core_terminal_NativeTerminal_<name>`.
 *
 * One handle = one ghostty Terminal + RenderState. Handles are not
 * thread-safe; confine each to a single thread or lock externally.
 * [snapshot] returns a direct ByteBuffer with the bridge's serialized cell
 * grid; the Kotlin snapshot parser owns the format's Kotlin side and must be
 * kept in lockstep with the Zig serializer.
 */
object NativeTerminal {
    init {
        System.loadLibrary("heeler_jni")
    }

    external fun version(): String
    external fun create(cols: Int, rows: Int, maxScrollback: Int): Long
    external fun destroy(handle: Long)

    /** Feeds remote PTY bytes into the VT parser. */
    external fun writeRemote(handle: Long, data: ByteArray)

    external fun resize(handle: Long, cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int)
    external fun scroll(handle: Long, delta: Int, x: Float, y: Float)
    external fun scrollToActive(handle: Long)
    external fun snapshot(handle: Long): ByteBuffer
    external fun pollTitle(handle: Long): String?
    external fun pollPwd(handle: Long): String?
    external fun pollClipboard(handle: Long): ByteArray?
    external fun drainBellCount(handle: Long): Int
    external fun setColorScheme(handle: Long, scheme: Int)
    external fun setDefaultColors(
        handle: Long,
        fgRgb: IntArray?,
        bgRgb: IntArray?,
        cursorRgb: IntArray?,
        paletteRgb: ByteArray?,
    )

    /** Encodes a key event per the terminal's current mode; null = nothing to send. */
    external fun encodeKey(handle: Long, key: Int, codepoint: Int, mods: Int, action: Int, utf8: String?): ByteArray?

    /** Bracketed-paste aware paste encoding. */
    external fun encodePaste(handle: Long, data: String): ByteArray?

    external fun setMouseEncodingSize(
        handle: Long,
        screenWidth: Int,
        screenHeight: Int,
        cellWidth: Int,
        cellHeight: Int,
        paddingTop: Int,
        paddingBottom: Int,
        paddingLeft: Int,
        paddingRight: Int,
    )
    external fun encodeMouse(
        handle: Long,
        action: Int,
        button: Int,
        mods: Int,
        x: Float,
        y: Float,
        anyButtonPressed: Boolean,
        trackLastCell: Boolean,
    ): ByteArray?
    external fun encodeFocus(handle: Long, focused: Boolean): ByteArray?

    /** Bytes the VT stream wants written back to the PTY (DA1 replies etc.). */
    external fun drainPtyWrites(handle: Long): ByteArray

    external fun snapshotImages(handle: Long): ByteBuffer
    external fun isImageLoading(handle: Long): Boolean
    external fun formatSelectionRange(handle: Long, startCell: Int, endCell: Int): String?
    external fun formatSelectionScreenRange(handle: Long, startScreenCell: Int, endScreenCell: Int): String?
    external fun selectWordAt(handle: Long, cellX: Int, cellY: Int): String?
    external fun selectLineAt(handle: Long, cellX: Int, cellY: Int): String?
    external fun selectAll(handle: Long): String?
}
