// Adapted from chuchu (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.
package dev.bybee.heeler.terminal

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalSnapshotTest {
    @Test
    fun decodesTheNativeLittleEndianHeaderCellsAndGraphemeExtras() {
        val cols = 3
        val rows = 1
        val headerBytes = 14 * Int.SIZE_BYTES
        val gridBytes = cols * rows * 11
        val extrasOffset = headerBytes + gridBytes
        val buffer = ByteBuffer.allocate(extrasOffset + 16).order(ByteOrder.LITTLE_ENDIAN)

        // The order is the native serializer contract, not a Kotlin-owned format.
        buffer.putInt(cols)
        buffer.putInt(rows)
        buffer.putInt(1)
        buffer.putInt(0)
        buffer.putInt(1)
        buffer.putInt(0x12)
        buffer.putInt(0x34)
        buffer.putInt(0x56)
        buffer.putInt(0xAB)
        buffer.putInt(0xCD)
        buffer.putInt(0xEF)
        buffer.putInt(extrasOffset)
        buffer.putInt(42)
        buffer.putInt(1)

        fun putCell(codepoint: Int, fg: Int, bg: Int, flags: Int) {
            buffer.putInt(codepoint)
            buffer.put((fg shr 16).toByte())
            buffer.put((fg shr 8).toByte())
            buffer.put(fg.toByte())
            buffer.put((bg shr 16).toByte())
            buffer.put((bg shr 8).toByte())
            buffer.put(bg.toByte())
            buffer.put(flags.toByte())
        }
        putCell('A'.code, 0x010203, 0x040506, TerminalSnapshot.CELL_FLAG_BOLD)
        putCell(0x1F9D1, 0x111213, 0x141516, TerminalSnapshot.CELL_FLAG_HAS_GRAPHEME)
        putCell(32, 0x212223, 0x242526, TerminalSnapshot.CELL_FLAG_SPACER)

        buffer.putInt(1)
        buffer.putInt(1)
        buffer.putInt(1)
        buffer.putInt(0x200D)
        buffer.position(0)

        val snapshot = TerminalSnapshot.fromByteBuffer(buffer)

        assertEquals(3, snapshot.cols)
        assertEquals(1, snapshot.rows)
        assertEquals(1, snapshot.cursorX)
        assertTrue(snapshot.cursorVisible)
        assertEquals(0xFF123456.toInt(), snapshot.defaultBgArgb)
        assertEquals(0xFFABCDEF.toInt(), snapshot.defaultFgArgb)
        assertEquals(42, snapshot.viewportScrollY)
        assertTrue(snapshot.appHandlesSelectionDrag)
        assertArrayEquals(intArrayOf('A'.code, 0x1F9D1, 32), snapshot.codepoints)
        assertEquals(0xFF010203.toInt(), snapshot.fgArgb[0])
        assertEquals(0xFF242526.toInt(), snapshot.bgArgb[2])
        assertTrue((snapshot.flags[0].toInt() and TerminalSnapshot.CELL_FLAG_BOLD) != 0)
        assertArrayEquals(intArrayOf(0x200D), snapshot.graphemeExtras[1])
        assertTrue(snapshot.isSpacerContinuation(2))
    }

    @Test
    fun treatsMalformedExtrasAsAbsentWithoutDiscardingTheGrid() {
        val headerBytes = 14 * Int.SIZE_BYTES
        val buffer = ByteBuffer.allocate(headerBytes + 11 + 12).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(1)
        buffer.putInt(1)
        buffer.putInt(-1)
        buffer.putInt(-1)
        buffer.putInt(0)
        repeat(6) { buffer.putInt(0) }
        buffer.putInt(headerBytes + 11)
        buffer.putInt(0)
        buffer.putInt(0)
        buffer.putInt('x'.code)
        repeat(6) { buffer.put(0) }
        buffer.put(TerminalSnapshot.CELL_FLAG_HAS_GRAPHEME.toByte())
        buffer.putInt(1)
        buffer.putInt(99)
        buffer.putInt(1)
        buffer.position(0)

        val snapshot = TerminalSnapshot.fromByteBuffer(buffer)

        assertEquals('x'.code, snapshot.codepoints.single())
        assertTrue(snapshot.graphemeExtras.isEmpty())
        assertFalse(snapshot.cursorVisible)
    }
}
