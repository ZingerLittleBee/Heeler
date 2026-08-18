package dev.bybee.heeler.staging

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.OpenableColumns
import dev.bybee.heeler.core.transport.PreparedFile
import dev.bybee.heeler.core.transport.PreparedImage
import dev.bybee.heeler.core.transport.PreparedImageFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** Bounded, metadata-free photo normalizer for Photo Picker results. */
class AndroidImagePreparer(private val context: Context) {
    suspend fun prepare(uri: Uri): PreparedImage = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val bounds = decodeBounds(resolver, uri)
        validateBounds(bounds.first, bounds.second)
        val orientation = readOrientation(resolver, uri)
        val sampled = decodeBitmap(resolver, uri, sampleSizeFor(bounds.first, bounds.second))
            ?: throw ImagePreparationError.InvalidImage
        val oriented = applyOrientation(sampled, orientation)
        val bounded = scaleLongEdge(oriented, MAXIMUM_LONG_EDGE)
        val format = if (hasVisibleAlpha(bounded)) PreparedImageFormat.PNG else PreparedImageFormat.JPEG
        val encoded = try {
            encodeBounded(bounded, format)
        } finally {
            if (!bounded.isRecycled) bounded.recycle()
        }
        val directory = File(context.cacheDir, "attachments/images")
        if (!directory.exists() && !directory.mkdirs()) throw ImagePreparationError.LocalStorageFailed
        val extension = format.fileExtension
        val temporary = File(directory, ".${UUID.randomUUID()}.$extension.part")
        val output = File(directory, "${UUID.randomUUID()}.$extension")
        try {
            FileOutputStream(temporary).use { it.write(encoded.bytes) }
            if (!temporary.renameTo(output)) throw IOException("Could not atomically finish prepared image")
            PreparedImage(output, format, encoded.width, encoded.height, output.length())
        } catch (_: IOException) {
            temporary.delete()
            output.delete()
            throw ImagePreparationError.LocalStorageFailed
        }
    }

    private fun decodeBounds(resolver: android.content.ContentResolver, uri: Uri): Pair<Int, Int> {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            BitmapFactory.decodeFileDescriptor(descriptor.fileDescriptor, null, options)
        } ?: throw ImagePreparationError.SelectionUnavailable
        if (options.outWidth <= 0 || options.outHeight <= 0) throw ImagePreparationError.InvalidImage
        return options.outWidth to options.outHeight
    }

    private fun decodeBitmap(
        resolver: android.content.ContentResolver,
        uri: Uri,
        sampleSize: Int,
    ): Bitmap? {
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            BitmapFactory.decodeFileDescriptor(descriptor.fileDescriptor, null, options)
        }
    }

    private fun readOrientation(resolver: android.content.ContentResolver, uri: Uri): Int = try {
        resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            ExifInterface(descriptor.fileDescriptor).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } ?: ExifInterface.ORIENTATION_NORMAL
    } catch (_: IOException) {
        ExifInterface.ORIENTATION_NORMAL
    }

    private fun validateBounds(width: Int, height: Int) {
        val pixelCount = width.toLong() * height.toLong()
        if (width > 65_535 || height > 65_535 || pixelCount > MAXIMUM_SOURCE_PIXELS) {
            throw ImagePreparationError.SourceTooLarge
        }
    }

    private fun sampleSizeFor(width: Int, height: Int): Int {
        var sample = 1
        while (max(width / sample, height / sample) > MAXIMUM_LONG_EDGE * 2) sample *= 2
        return sample
    }

    private fun applyOrientation(source: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return source
        }
        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true).also {
            if (it !== source) source.recycle()
        }
    }

    private fun scaleLongEdge(source: Bitmap, maximumLongEdge: Int): Bitmap {
        val longEdge = max(source.width, source.height)
        if (longEdge <= maximumLongEdge) return source
        val scale = maximumLongEdge.toFloat() / longEdge
        val width = max(1, (source.width * scale).toInt())
        val height = max(1, (source.height * scale).toInt())
        return Bitmap.createScaledBitmap(source, width, height, true).also { source.recycle() }
    }

    private fun hasVisibleAlpha(bitmap: Bitmap): Boolean {
        if (!bitmap.hasAlpha()) return false
        val row = IntArray(bitmap.width)
        for (y in 0 until bitmap.height) {
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            if (row.any { (it ushr 24) != 0xFF }) return true
        }
        return false
    }

    private data class Encoded(val bytes: ByteArray, val width: Int, val height: Int)

    private fun encodeBounded(initial: Bitmap, format: PreparedImageFormat): Encoded {
        var candidate = initial
        try {
            while (candidate.width >= MINIMUM_DIMENSION && candidate.height >= MINIMUM_DIMENSION) {
                val bytes = when (format) {
                    PreparedImageFormat.JPEG -> encodeJpeg(candidate)
                    PreparedImageFormat.PNG -> encode(candidate, Bitmap.CompressFormat.PNG, 100)
                }
                if (bytes != null) return Encoded(bytes, candidate.width, candidate.height)
                val scaled = scaleForFurtherEncoding(candidate)
                candidate.recycle()
                candidate = scaled
            }
            throw ImagePreparationError.UnableToProduceBoundedOutput
        } finally {
            if (!candidate.isRecycled) candidate.recycle()
        }
    }

    private fun encode(bitmap: Bitmap, format: Bitmap.CompressFormat, quality: Int): ByteArray? {
        val output = CappedByteArrayOutputStream(MAXIMUM_ENCODED_BYTES)
        if (!bitmap.compress(format, quality, output) || output.overflowed) return null
        return output.toByteArray()
    }

    private fun encodeJpeg(bitmap: Bitmap): ByteArray? {
        for (quality in JPEG_QUALITIES) {
            encode(bitmap, Bitmap.CompressFormat.JPEG, quality)?.let { return it }
        }
        return null
    }

    private fun scaleForFurtherEncoding(source: Bitmap): Bitmap {
        val width = max(MINIMUM_DIMENSION, (source.width * 0.70f).toInt())
        val height = max(MINIMUM_DIMENSION, (source.height * 0.70f).toInt())
        if (width == source.width && height == source.height) throw ImagePreparationError.UnableToProduceBoundedOutput
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    private companion object {
        const val MAXIMUM_LONG_EDGE = 4_096
        const val MAXIMUM_SOURCE_PIXELS = 200_000_000L
        const val MAXIMUM_ENCODED_BYTES = PreparedImage.MAXIMUM_ENCODED_BYTE_COUNT
        const val MINIMUM_DIMENSION = 16
        val JPEG_QUALITIES = intArrayOf(90, 82, 74, 66, 58, 50, 42, 35)
    }
}

/** Copies a SAF document into app-private cache storage while enforcing the 64 MiB cap. */
class AndroidFilePreparer(private val context: Context) {
    suspend fun prepare(uri: Uri): PreparedFile = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val metadata = queryDocumentMetadata(resolver, uri)
        if (metadata.size != null && metadata.size > PreparedFile.MAXIMUM_BYTE_COUNT) {
            throw FilePreparationError.SourceTooLarge
        }
        val directory = File(context.cacheDir, "attachments/files")
        if (!directory.exists() && !directory.mkdirs()) throw FilePreparationError.LocalStorageFailed
        val extension = PreparedFile.safeExtension(metadata.displayName.substringAfterLast('.', ""))
        val filename = UUID.randomUUID().toString() + if (extension.isEmpty()) "" else ".${extension}"
        val output = File(directory, filename)
        try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(output).use { destination ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > PreparedFile.MAXIMUM_BYTE_COUNT) throw FilePreparationError.SourceTooLarge
                        destination.write(buffer, 0, count)
                    }
                    if (total == 0L) throw FilePreparationError.SelectionUnavailable
                }
            } ?: throw FilePreparationError.SelectionUnavailable
            PreparedFile(output, extension, output.length())
        } catch (error: FilePreparationError) {
            output.delete()
            throw error
        } catch (_: IOException) {
            output.delete()
            throw FilePreparationError.LocalStorageFailed
        }
    }

    private data class DocumentMetadata(val displayName: String, val size: Long?)

    private fun queryDocumentMetadata(
        resolver: android.content.ContentResolver,
        uri: Uri,
    ): DocumentMetadata {
        return try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use DocumentMetadata("file", null)
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    DocumentMetadata(
                        if (nameIndex >= 0) cursor.getString(nameIndex).orEmpty().ifBlank { "file" } else "file",
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null,
                    )
                } ?: DocumentMetadata("file", null)
        } catch (_: SecurityException) {
            throw FilePreparationError.SelectionUnavailable
        }
    }
}

/** Bounds memory retained by image encoders to the transport's 16 MiB contract. */
private class CappedByteArrayOutputStream(private val cap: Int) : ByteArrayOutputStream(min(cap, 32 * 1024)) {
    var overflowed = false
        private set

    override fun write(oneByte: Int) {
        if (count >= cap) {
            overflowed = true
            return
        }
        super.write(oneByte)
    }

    override fun write(bytes: ByteArray, offset: Int, length: Int) {
        if (length <= 0) return
        val available = cap - count
        if (length > available) overflowed = true
        if (available > 0) super.write(bytes, offset, min(length, available))
    }
}
