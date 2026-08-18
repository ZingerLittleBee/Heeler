package dev.bybee.heeler.detail

import java.net.URI

/** One ordinary HTTP(S) target observed during the current Attach session. */
data class AttachLink(val target: String) {
    val host: String = runCatching { URI(target).host.orEmpty() }.getOrDefault("")
}

/**
 * Bounded, memory-only index of links observed in an Attach PTY stream.
 *
 * The scanner keeps its state across arbitrary network chunks, strips terminal
 * control sequences, and explicitly records OSC 8 targets. The store owns this
 * index for one detail session and clears it when that detail is left.
 */
class AttachLinkIndex {
    private val scanner = AttachLinkScanner(::recordStreamTarget)
    private val streamTargets = mutableSetOf<String>()
    private val viewportOnlyTargets = mutableSetOf<String>()
    private val indexed = ArrayList<AttachLink>(MAXIMUM_LINK_COUNT)

    val links: List<AttachLink>
        get() = indexed.toList()

    fun receive(data: ByteArray) = scanner.receive(data)

    /**
     * Supplements stream discovery from a visible-terminal snapshot. Each
     * snapshot has hard line boundaries because soft wraps are unknowable here.
     */
    fun receiveViewportText(text: String) {
        val viewportScanner = AttachLinkScanner(::recordViewportTarget)
        viewportScanner.receive(text.encodeToByteArray())
        viewportScanner.finishOutput()
    }

    fun finishOutput() = scanner.finishOutput()

    fun clear() {
        scanner.reset()
        streamTargets.clear()
        viewportOnlyTargets.clear()
        indexed.clear()
    }

    private fun recordStreamTarget(target: String) {
        if (!isWebUrl(target)) return
        removeViewportOnlyPrefixes(target)
        if (!record(target, moveExistingToFront = true)) return
        streamTargets += target
        viewportOnlyTargets -= target
    }

    private fun recordViewportTarget(target: String) {
        if (!isWebUrl(target)) return
        if (indexed.any { it.target != target && it.target.startsWith(target) }) return
        removeViewportOnlyPrefixes(target)
        if (!record(target, moveExistingToFront = false)) return
        if (target !in streamTargets) viewportOnlyTargets += target
    }

    private fun removeViewportOnlyPrefixes(target: String) {
        val prefixes = viewportOnlyTargets.filter { it != target && target.startsWith(it) }.toSet()
        if (prefixes.isEmpty()) return
        indexed.removeAll { it.target in prefixes }
        viewportOnlyTargets.removeAll(prefixes)
    }

    private fun record(target: String, moveExistingToFront: Boolean): Boolean {
        if (!isWebUrl(target)) return false
        val existingIndex = indexed.indexOfFirst { it.target == target }
        if (!moveExistingToFront && existingIndex >= 0) return true
        if (existingIndex >= 0) indexed.removeAt(existingIndex)
        indexed.add(0, AttachLink(target))
        while (indexed.size > MAXIMUM_LINK_COUNT) indexed.removeAt(indexed.lastIndex)
        val retained = indexed.asSequence().map(AttachLink::target).toSet()
        streamTargets.retainAll(retained)
        viewportOnlyTargets.retainAll(retained)
        return true
    }

    private fun isWebUrl(target: String): Boolean =
        target.length <= MAXIMUM_TARGET_BYTES && runCatching {
            val uri = URI(target)
            val scheme = uri.scheme
            (scheme.equals("http", ignoreCase = true) || scheme.equals("https", ignoreCase = true)) &&
                !uri.host.isNullOrEmpty()
        }.getOrDefault(false)

    private class AttachLinkScanner(private val record: (String) -> Unit) {
        private enum class State { TEXT, ESCAPE, ESCAPE_SEQUENCE, CSI, OSC, OSC_ESCAPE, STRING_CONTROL, STRING_CONTROL_ESCAPE }

        private var state = State.TEXT
        private val plain = PlainAttachLinkScanner()
        private val osc8 = Osc8Accumulator()
        private var osc8LabelActive = false

        fun receive(data: ByteArray) {
            data.forEach(::receive)
        }

        fun finishOutput() {
            if (state != State.TEXT) {
                finishPlainCandidate()
            } else if (!osc8LabelActive) {
                plain.finishOutput()?.let(record)
            }
            reset()
        }

        fun reset() {
            state = State.TEXT
            plain.reset()
            osc8.reset()
            osc8LabelActive = false
        }

        private fun receive(byte: Byte) {
            val value = byte.toInt() and 0xFF
            when (state) {
                State.TEXT -> receiveText(value)
                State.ESCAPE -> receiveAfterEscape(value)
                State.ESCAPE_SEQUENCE -> when {
                    value in 0x30..0x7E -> state = State.TEXT
                    value == ESC -> state = State.ESCAPE
                }
                State.CSI -> when {
                    value in 0x40..0x7E -> {
                        if (value != 'm'.code) finishPlainCandidate()
                        state = State.TEXT
                    }
                    value == ESC -> {
                        finishPlainCandidate()
                        state = State.ESCAPE
                    }
                }
                State.OSC -> when (value) {
                    BEL, ST -> finishOsc()
                    ESC -> state = State.OSC_ESCAPE
                    else -> osc8.receive(value)
                }
                State.OSC_ESCAPE -> if (value == '\\'.code) {
                    finishOsc()
                } else {
                    osc8.invalidate()
                    state = if (value == ESC) State.OSC_ESCAPE else State.OSC
                }
                State.STRING_CONTROL -> when (value) {
                    ST -> state = State.TEXT
                    ESC -> state = State.STRING_CONTROL_ESCAPE
                }
                State.STRING_CONTROL_ESCAPE -> state = if (value == '\\'.code) State.TEXT else State.STRING_CONTROL
            }
        }

        private fun receiveText(value: Int) {
            when (value) {
                ESC -> state = State.ESCAPE
                CSI -> state = State.CSI
                OSC -> {
                    osc8.reset()
                    state = State.OSC
                }
                DCS, SOS, PM, APC -> {
                    finishPlainCandidate()
                    state = State.STRING_CONTROL
                }
                in 0x80..0x9F -> finishPlainCandidate()
                else -> if (!osc8LabelActive) plain.receive(value)?.let(record)
            }
        }

        private fun receiveAfterEscape(value: Int) {
            when (value) {
                '['.code -> state = State.CSI
                ']'.code -> {
                    osc8.reset()
                    state = State.OSC
                }
                'P'.code, 'X'.code, '^'.code, '_'.code -> {
                    finishPlainCandidate()
                    state = State.STRING_CONTROL
                }
                in 0x20..0x2F -> {
                    finishPlainCandidate()
                    state = State.ESCAPE_SEQUENCE
                }
                else -> {
                    finishPlainCandidate()
                    state = State.TEXT
                }
            }
        }

        private fun finishOsc() {
            val hyperlink = osc8.hyperlink()
            osc8.reset()
            state = State.TEXT
            if (hyperlink == null) {
                finishPlainCandidate()
                return
            }
            finishPlainCandidate()
            when (hyperlink) {
                is Osc8Accumulator.Hyperlink.Close -> osc8LabelActive = false
                is Osc8Accumulator.Hyperlink.Open -> {
                    osc8LabelActive = true
                    hyperlink.target?.let(record)
                }
            }
        }

        private fun finishPlainCandidate() {
            if (!osc8LabelActive) plain.finishOutput()?.let(record)
        }

        private companion object {
            const val ESC = 0x1B
            const val BEL = 0x07
            const val ST = 0x9C
            const val CSI = 0x9B
            const val OSC = 0x9D
            const val DCS = 0x90
            const val SOS = 0x98
            const val PM = 0x9E
            const val APC = 0x9F
        }
    }

    private class Osc8Accumulator {
        sealed interface Hyperlink {
            data class Open(val target: String?) : Hyperlink
            data object Close : Hyperlink
        }

        private enum class Field { COMMAND, PARAMETERS, TARGET, IGNORED }

        private var field = Field.COMMAND
        private val command = ArrayList<Byte>(MAXIMUM_COMMAND_BYTES)
        private var target = ByteArray(0)
        private var targetSize = 0
        private var targetOversized = false

        fun receive(value: Int) {
            when (field) {
                Field.COMMAND -> when (value) {
                    ';'.code -> field = if (command.toByteArray().decodeToString() == "8") Field.PARAMETERS else Field.IGNORED
                    else -> if (command.size < MAXIMUM_COMMAND_BYTES) command += value.toByte() else field = Field.IGNORED
                }
                Field.PARAMETERS -> if (value == ';'.code) field = Field.TARGET
                Field.TARGET -> appendTarget(value.toByte())
                Field.IGNORED -> Unit
            }
        }

        fun hyperlink(): Hyperlink? {
            if (field != Field.TARGET) return null
            if (targetSize == 0) return Hyperlink.Close
            if (targetOversized) return Hyperlink.Open(null)
            return runCatching { Hyperlink.Open(target.copyOf(targetSize).decodeToString()) }
                .getOrElse { Hyperlink.Open(null) }
        }

        fun invalidate() {
            field = Field.IGNORED
            command.clear()
            target = ByteArray(0)
            targetSize = 0
            targetOversized = false
        }

        fun reset() {
            field = Field.COMMAND
            command.clear()
            target = ByteArray(0)
            targetSize = 0
            targetOversized = false
        }

        private fun appendTarget(value: Byte) {
            if (targetOversized) return
            if (targetSize >= MAXIMUM_TARGET_BYTES) {
                target = ByteArray(0)
                targetSize = 0
                targetOversized = true
                return
            }
            if (targetSize == target.size) target = target.copyOf((target.size * 2).coerceAtLeast(64))
            target[targetSize++] = value
        }
    }

    private class PlainAttachLinkScanner {
        private val recent = ArrayList<Byte>(LONGEST_SCHEME_BYTES)
        private var candidate = ByteArray(0)
        private var candidateSize = 0
        private var oversized = false

        fun receive(value: Int): String? {
            if (isBoundary(value)) {
                val found = finishCandidate()
                recent.clear()
                return found
            }
            if (candidateSize > 0 || oversized) {
                appendCandidate(value.toByte())
                return null
            }
            recent += value.toByte()
            while (recent.size > LONGEST_SCHEME_BYTES) recent.removeAt(0)
            val scheme = WEB_SCHEMES.firstOrNull { recentEndsWith(it) } ?: return null
            candidate = scheme.copyOf()
            candidateSize = scheme.size
            recent.clear()
            return null
        }

        fun finishOutput(): String? {
            recent.clear()
            return finishCandidate()
        }

        fun reset() {
            recent.clear()
            candidate = ByteArray(0)
            candidateSize = 0
            oversized = false
        }

        private fun appendCandidate(value: Byte) {
            if (oversized) return
            if (candidateSize >= MAXIMUM_TARGET_BYTES) {
                candidate = ByteArray(0)
                candidateSize = 0
                oversized = true
                return
            }
            if (candidateSize == candidate.size) candidate = candidate.copyOf((candidate.size * 2).coerceAtLeast(64))
            candidate[candidateSize++] = value
        }

        private fun finishCandidate(): String? {
            if (oversized) {
                candidate = ByteArray(0)
                candidateSize = 0
                oversized = false
                return null
            }
            val result = runCatching { candidate.copyOf(candidateSize).decodeToString() }.getOrNull()
            candidate = ByteArray(0)
            candidateSize = 0
            return result?.let(::removeSurroundingPunctuation)?.takeIf(String::isNotEmpty)
        }

        private fun recentEndsWith(suffix: ByteArray): Boolean {
            if (recent.size < suffix.size) return false
            val offset = recent.size - suffix.size
            return suffix.indices.all {
                lowerAscii(recent[offset + it].toInt() and 0xFF) == (suffix[it].toInt() and 0xFF)
            }
        }

        private fun removeSurroundingPunctuation(text: String): String {
            var result = text
            while (result.isNotEmpty()) {
                when (result.last()) {
                    '.', ',', ';', ':', '!' -> result = result.dropLast(1)
                    ')' -> if (result.count { it == ')' } > result.count { it == '(' }) result = result.dropLast(1) else return result
                    ']' -> if (result.count { it == ']' } > result.count { it == '[' }) result = result.dropLast(1) else return result
                    '}' -> if (result.count { it == '}' } > result.count { it == '{' }) result = result.dropLast(1) else return result
                    else -> return result
                }
            }
            return result
        }

        private fun isBoundary(value: Int): Boolean =
            value <= 0x20 || value == 0x7F || value == '"'.code || value == '\''.code || value == '<'.code || value == '>'.code

        private fun lowerAscii(value: Int): Int = if (value in 'A'.code..'Z'.code) value + 0x20 else value

        private companion object {
            const val LONGEST_SCHEME_BYTES = 8
            val WEB_SCHEMES = arrayOf("http://".encodeToByteArray(), "https://".encodeToByteArray())
        }
    }

    private companion object {
        const val MAXIMUM_LINK_COUNT = 20
        const val MAXIMUM_TARGET_BYTES = 32 * 1024
        const val MAXIMUM_COMMAND_BYTES = 16
    }
}
