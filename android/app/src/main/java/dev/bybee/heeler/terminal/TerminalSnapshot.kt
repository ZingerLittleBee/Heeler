// Adapted from chuchu (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.
package dev.bybee.heeler.terminal

import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.nio.ByteOrder

data class ImagePlacement(
    val cellCol: Int,
    val cellRow: Int,
    val cellXOffset: Int,
    val cellYOffset: Int,
    val destW: Int,
    val destH: Int,
    val srcX: Int,
    val srcY: Int,
    val srcW: Int,
    val srcH: Int,
    val imgW: Int,
    val imgH: Int,
    val bitmap: Bitmap,
)

data class TerminalSnapshot(
    val cols: Int,
    val rows: Int,
    val cursorX: Int,
    val cursorY: Int,
    val cursorVisible: Boolean,
    val defaultBgArgb: Int,
    val defaultFgArgb: Int,
    val codepoints: IntArray,
    val fgArgb: IntArray,
    val bgArgb: IntArray,
    val flags: ByteArray,
    /**
     * Sparse map: cell index -> extra grapheme codepoints (appended after the
     * base codepoint stored in [codepoints]). Present when the corresponding
     * cell has [CELL_FLAG_HAS_GRAPHEME] set.
     */
    val graphemeExtras: Map<Int, IntArray> = emptyMap(),
    val images: List<ImagePlacement> = emptyList(),
    /**
     * Stable screen.y of the content currently at viewport row 0. Changes
     * monotonically as the viewport scrolls, so the host can subtract it
     * across snapshots to remap a content-tracking selection anchor.
     */
    val viewportScrollY: Int = 0,
    /**
     * True when the running app has enabled a drag-reporting mouse mode
     * (DECSET 1002/1003). When set, the host forwards long-press drag
     * gestures to the app so a multiplexer (tmux/zellij/...) can perform
     * its own pane-scoped selection in copy mode instead of the host
     * building a grid-wide client-side selection that crosses pane borders.
     */
    val appHandlesSelectionDrag: Boolean = false,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TerminalSnapshot) return false
        return cols == other.cols && rows == other.rows &&
            cursorX == other.cursorX && cursorY == other.cursorY &&
            cursorVisible == other.cursorVisible &&
            defaultBgArgb == other.defaultBgArgb &&
            defaultFgArgb == other.defaultFgArgb &&
            codepoints.contentEquals(other.codepoints) &&
            fgArgb.contentEquals(other.fgArgb) &&
            bgArgb.contentEquals(other.bgArgb) &&
            flags.contentEquals(other.flags) &&
            graphemeExtrasEquals(graphemeExtras, other.graphemeExtras) &&
            images == other.images &&
            viewportScrollY == other.viewportScrollY &&
            appHandlesSelectionDrag == other.appHandlesSelectionDrag
    }

    override fun hashCode(): Int {
        var result = cols
        result = 31 * result + rows
        result = 31 * result + cursorX
        result = 31 * result + cursorY
        result = 31 * result + cursorVisible.hashCode()
        result = 31 * result + defaultBgArgb
        result = 31 * result + defaultFgArgb
        result = 31 * result + codepoints.contentHashCode()
        result = 31 * result + fgArgb.contentHashCode()
        result = 31 * result + bgArgb.contentHashCode()
        result = 31 * result + flags.contentHashCode()
        result = 31 * result + graphemeExtras.entries.fold(0) { acc, (key, arr) ->
            acc + key + arr.contentHashCode()
        }
        result = 31 * result + images.hashCode()
        result = 31 * result + viewportScrollY
        result = 31 * result + appHandlesSelectionDrag.hashCode()
        return result
    }

    companion object {
        const val CELL_FLAG_HAS_GRAPHEME: Int = 0x40
        const val CELL_FLAG_SPACER: Int = 0x80
        const val CELL_FLAG_BOLD: Int = 0x01
        const val CELL_FLAG_ITALIC: Int = 0x02
        const val CELL_FLAG_UNDERLINE: Int = 0x04
        const val CELL_FLAG_INVERSE: Int = 0x08
        const val CELL_FLAG_BLINK: Int = 0x10
        const val CELL_FLAG_FAINT: Int = 0x20
        private const val HEADER_I32_COUNT = 14
        private const val CELL_SIZE_BYTES = 11
        private const val IMAGE_HEADER_BYTES = 52
        private const val HEADER_BYTES = HEADER_I32_COUNT * Int.SIZE_BYTES

        private fun graphemeExtrasEquals(
            a: Map<Int, IntArray>,
            b: Map<Int, IntArray>,
        ): Boolean {
            if (a.size != b.size) return false
            for ((k, v) in a) {
                val o = b[k] ?: return false
                if (!v.contentEquals(o)) return false
            }
            return true
        }

        private fun packArgb(r: Int, g: Int, b: Int): Int =
            (0xFF shl 24) or (r shl 16) or (g shl 8) or b

        fun fromByteBuffer(
            buffer: ByteBuffer,
            images: List<ImagePlacement> = emptyList(),
        ): TerminalSnapshot {
            require(buffer.capacity() >= HEADER_BYTES) {
                "Snapshot buffer too small for header: cap=${buffer.capacity()} expected=$HEADER_BYTES"
            }
            val wrapped = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            wrapped.position(0)

            val cols = wrapped.int
            val rows = wrapped.int
            val cursorX = wrapped.int
            val cursorY = wrapped.int
            val cursorVisible = wrapped.int == 1
            val defaultBgR = wrapped.int
            val defaultBgG = wrapped.int
            val defaultBgB = wrapped.int
            val defaultFgR = wrapped.int
            val defaultFgG = wrapped.int
            val defaultFgB = wrapped.int
            val extrasOffset = wrapped.int
            val viewportScrollY = wrapped.int
            val appHandlesSelectionDrag = wrapped.int == 1

            require(cols >= 0 && rows >= 0) {
                "Snapshot grid dimensions must be non-negative: ${cols}x$rows"
            }
            val cellCountLong = cols.toLong() * rows.toLong()
            require(cellCountLong <= Int.MAX_VALUE) {
                "Snapshot grid too large: ${cols}x$rows"
            }
            val cellCount = cellCountLong.toInt()
            val expectedSizeLong = HEADER_BYTES.toLong() + (cellCountLong * CELL_SIZE_BYTES)
            require(expectedSizeLong <= Int.MAX_VALUE && buffer.capacity().toLong() >= expectedSizeLong) {
                "Snapshot buffer too small: cap=${buffer.capacity()} expected=$expectedSizeLong"
            }
            val expectedSize = expectedSizeLong.toInt()

            // Bulk-read all cell bytes in one operation, then parse from the
            // byte array to avoid thousands of virtual-dispatch ByteBuffer
            // calls that dominate the parse cost on Android.
            // Allocate fresh arrays each frame — the old arrays are held by the
            // previous TerminalSnapshot visible to the UI thread, so reusing
            // them would cause a data race.
            val cellDataLen = cellCount * CELL_SIZE_BYTES
            val cellBytes = ByteArray(cellDataLen)
            wrapped.get(cellBytes, 0, cellDataLen)

            val codepoints = IntArray(cellCount)
            val fgArgb = IntArray(cellCount)
            val bgArgb = IntArray(cellCount)
            val flags = ByteArray(cellCount)

            var off = 0
            for (i in 0 until cellCount) {
                // codepoint: little-endian i32 from 4 bytes
                codepoints[i] = (cellBytes[off].toInt() and 0xFF) or
                    ((cellBytes[off + 1].toInt() and 0xFF) shl 8) or
                    ((cellBytes[off + 2].toInt() and 0xFF) shl 16) or
                    ((cellBytes[off + 3].toInt() and 0xFF) shl 24)
                off += 4
                val fgR = cellBytes[off].toInt() and 0xFF; off++
                val fgG = cellBytes[off].toInt() and 0xFF; off++
                val fgB = cellBytes[off].toInt() and 0xFF; off++
                val bgR = cellBytes[off].toInt() and 0xFF; off++
                val bgG = cellBytes[off].toInt() and 0xFF; off++
                val bgB = cellBytes[off].toInt() and 0xFF; off++
                fgArgb[i] = packArgb(fgR, fgG, fgB)
                bgArgb[i] = packArgb(bgR, bgG, bgB)
                flags[i] = cellBytes[off]; off++
            }

            val graphemeExtras: Map<Int, IntArray> =
                if (extrasOffset >= expectedSize && extrasOffset < wrapped.capacity()) {
                    val extras = wrapped.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                    extras.position(extrasOffset)
                    if (extras.remaining() < 4) {
                        emptyMap()
                    } else {
                        val recordCount = extras.int
                        if (recordCount !in 0..cellCount) {
                            emptyMap()
                        } else {
                            val parsed = HashMap<Int, IntArray>(recordCount)
                            var valid = true
                            for (record in 0 until recordCount) {
                                if (extras.remaining() < 8) {
                                    valid = false
                                    break
                                }
                                val cellIndex = extras.int
                                val count = extras.int
                                if (cellIndex !in 0 until cellCount || count < 0 || count > extras.remaining() / Int.SIZE_BYTES) {
                                    valid = false
                                    break
                                }
                                val cps = IntArray(count)
                                for (j in 0 until count) cps[j] = extras.int
                                parsed[cellIndex] = cps
                            }
                            if (valid) parsed else emptyMap()
                        }
                    }
                } else {
                    emptyMap()
                }

            val snapshot = TerminalSnapshot(
                cols = cols,
                rows = rows,
                cursorX = cursorX,
                cursorY = cursorY,
                cursorVisible = cursorVisible,
                defaultBgArgb = packArgb(defaultBgR, defaultBgG, defaultBgB),
                defaultFgArgb = packArgb(defaultFgR, defaultFgG, defaultFgB),
                codepoints = codepoints,
                fgArgb = fgArgb,
                bgArgb = bgArgb,
                flags = flags,
                graphemeExtras = graphemeExtras,
                images = images,
                viewportScrollY = viewportScrollY,
                appHandlesSelectionDrag = appHandlesSelectionDrag,
            )

            return snapshot
        }

        fun parseImages(buffer: ByteBuffer?): List<ImagePlacement> {
            if (buffer == null || buffer.capacity() < 4) return emptyList()
            val wrapped = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            wrapped.position(0)
            val count = wrapped.int
            if (count !in 1..64) return emptyList()

            val images = ArrayList<ImagePlacement>(count)
            for (i in 0 until count) {
                if (wrapped.remaining() < IMAGE_HEADER_BYTES) break
                val cellCol = wrapped.int
                val cellRow = wrapped.int
                val cellXOffset = wrapped.int
                val cellYOffset = wrapped.int
                val destW = wrapped.int
                val destH = wrapped.int
                val srcX = wrapped.int
                val srcY = wrapped.int
                val srcW = wrapped.int
                val srcH = wrapped.int
                val imgW = wrapped.int
                val imgH = wrapped.int
                val dataLen = wrapped.int

                val expectedLen = imgW.toLong() * imgH.toLong() * 4L
                if (imgW <= 0 || imgH <= 0 || dataLen <= 0 ||
                    expectedLen > Int.MAX_VALUE ||
                    dataLen != expectedLen.toInt() ||
                    wrapped.remaining() < dataLen
                ) {
                    break
                }

                val pixelBytes = wrapped.slice().order(ByteOrder.nativeOrder())
                pixelBytes.limit(dataLen)

                val bitmap = Bitmap.createBitmap(imgW, imgH, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(pixelBytes)
                wrapped.position(wrapped.position() + dataLen)

                images += ImagePlacement(
                    cellCol = cellCol,
                    cellRow = cellRow,
                    cellXOffset = cellXOffset,
                    cellYOffset = cellYOffset,
                    destW = destW,
                    destH = destH,
                    srcX = srcX,
                    srcY = srcY,
                    srcW = srcW,
                    srcH = srcH,
                    imgW = imgW,
                    imgH = imgH,
                    bitmap = bitmap,
                )
            }
            return images
        }
    }
}
