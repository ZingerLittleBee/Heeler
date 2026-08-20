// Adapted from chuchu (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.
package dev.bybee.heeler.terminal

import android.content.Context
import android.graphics.Color
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.view.KeyEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedText
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import dev.bybee.heeler.core.terminal.NativeTerminal

/**
 * Transparent IME endpoint for a terminal surface.
 *
 * The view never maps Android keys to terminal bytes or writes to a channel. Its
 * callbacks are the sole input-routing policy: return `true` after routing an
 * event and `false` to veto it. A registered callback always consumes the
 * Android event, so a veto cannot leak text into the invisible editor.
 */
class TerminalInputView(context: Context) : EditText(context) {
    companion object {
        private const val SUPPRESSION_CLEANUP_WINDOW_MS = 120L
        private const val MAX_IME_BUFFER_CHARS = 1024
    }

    /** Receives committed or composing terminal text; newlines are reported as `\r`. */
    var onTextInput: ((String) -> Boolean)? = null

    /** Receives raw Android hardware key events; the caller maps them for [NativeTerminal]. */
    var onKeyEvent: ((KeyEvent) -> Boolean)? = null

    /**
     * Suppresses the IME cleanup transaction caused by a caller-routed virtual
     * key. Call [armInputSuppression] immediately before the caller sends such
     * a key through its own terminal policy.
     */
    @Volatile
    var suppressInput: Boolean = false
        private set

    @Volatile
    private var suppressionSnapshot: String = ""

    @Volatile
    private var suppressionDeadlineUptimeMs: Long = 0L

    private var activeInputConnection: TerminalInputConnection? = null
    private var inputMethodManager: InputMethodManager? = null

    init {
        setBackgroundColor(Color.TRANSPARENT)
        setTextColor(Color.TRANSPARENT)
        isCursorVisible = false
        isFocusable = true
        isFocusableInTouchMode = true
        setSingleLine(false)
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val callback = onKeyEvent ?: return super.onKeyDown(keyCode, event)
        callback(event)
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        val callback = onKeyEvent ?: return super.onKeyUp(keyCode, event)
        callback(event)
        return true
    }

    /** Makes this transparent endpoint the active IME target. */
    fun showKeyboard(inputMethodManager: InputMethodManager?) {
        val imm = inputMethodManager ?: return
        this.inputMethodManager = imm
        if (!hasFocus()) {
            requestFocus()
            requestFocusFromTouch()
        }
        post {
            imm.restartInput(this)
            imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    /**
     * Drops the IME mirror and ignores its following cleanup mutation. The
     * caller owns the corresponding terminal-key decision and delivery.
     */
    fun armInputSuppression() {
        suppressInput = true
        suppressionSnapshot = editableText.toString()
        suppressionDeadlineUptimeMs = SystemClock.uptimeMillis() + SUPPRESSION_CLEANUP_WINDOW_MS
        activeInputConnection?.clearImeBuffer(restart = false)
        inputMethodManager?.let { imm -> post { imm.restartInput(this) } }
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_ACTION_NONE
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.initialSelStart = selectionStart
        outAttrs.initialSelEnd = selectionEnd
        return TerminalInputConnection(this).also { activeInputConnection = it }
    }

    private fun reportText(text: String): Boolean = onTextInput?.invoke(text) ?: false

    private fun clearSuppression() {
        suppressInput = false
        suppressionSnapshot = ""
        suppressionDeadlineUptimeMs = 0L
    }

    private fun suppressionCleanup(before: String, after: String): Boolean {
        if (!suppressInput || SystemClock.uptimeMillis() > suppressionDeadlineUptimeMs) return false
        val cleanup = before == after || after.isEmpty() || after == suppressionSnapshot ||
            (suppressionSnapshot.startsWith(after) && after.length <= suppressionSnapshot.length)
        if (cleanup) clearSuppression()
        return cleanup
    }

    private class TerminalInputConnection(
        private val view: TerminalInputView,
    ) : BaseInputConnection(view, true) {
        private var batchDepth = 0
        private var batchBefore: String? = null
        private var emittedDuringBatch = false
        private var directMutationDepth = 0

        override fun getEditable(): Editable = view.editableText

        fun clearImeBuffer(restart: Boolean) {
            val editable = getEditable()
            BaseInputConnection.removeComposingSpans(editable)
            editable.clear()
            Selection.setSelection(editable, 0)
            if (restart) view.inputMethodManager?.restartInput(view)
        }

        private fun reportTextWithNewlineMapping(text: String) {
            var segmentStart = 0
            for (index in text.indices) {
                if (text[index] == '\n') {
                    if (index > segmentStart) view.reportText(text.substring(segmentStart, index))
                    view.reportText("\r")
                    segmentStart = index + 1
                }
            }
            if (segmentStart < text.length) view.reportText(text.substring(segmentStart))
        }

        private fun emitDiff(before: String, after: String) {
            if (view.suppressionCleanup(before, after)) {
                clearImeBuffer(restart = false)
                return
            }
            if (view.suppressInput) view.clearSuppression()

            var common = 0
            val shared = minOf(before.length, after.length)
            while (common < shared && before[common] == after[common]) common++
            repeat(before.length - common) { view.reportText("\u007f") }
            if (common < after.length) reportTextWithNewlineMapping(after.substring(common))
        }

        /**
         * Mirrors the mutation into the invisible editor, reports the diff to
         * the terminal, and then *retains* the committed text. The retained
         * mirror is what lets glide/swipe keyboards behave: Gboard decides
         * whether a swiped word needs a leading space by reading the text
         * before the cursor, so a mirror cleared after every commit reads as
         * an empty field and words run together (the terminal never echoes
         * back into this editor). Newlines still reset the mirror — the
         * terminal moved to a fresh line, so retained context would be a lie —
         * as does [armInputSuppression] for caller-routed virtual keys.
         */
        private fun mutateAndReport(composing: Boolean, mutation: () -> Boolean): Boolean {
            val before = getEditable().toString()
            directMutationDepth++
            val result = try {
                mutation()
            } finally {
                directMutationDepth--
            }
            val after = getEditable().toString()
            if (before != after) {
                emittedDuringBatch = true
                emitDiff(before, after)
            }
            if (!composing && after.contains('\n')) {
                clearImeBuffer(restart = false)
            } else if (after.length > MAX_IME_BUFFER_CHARS) {
                clearImeBuffer(restart = true)
            }
            return result
        }

        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean =
            mutateAndReport(composing = false) {
                super.commitText(text ?: "", newCursorPosition)
            }

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean =
            mutateAndReport(composing = !text.isNullOrEmpty()) {
                super.setComposingText(text ?: "", newCursorPosition)
            }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            val before = getEditable().toString()
            directMutationDepth++
            val result = try {
                super.deleteSurroundingText(beforeLength, afterLength)
            } finally {
                directMutationDepth--
            }
            val after = getEditable().toString()
            if (view.suppressionCleanup(before, after)) {
                clearImeBuffer(restart = false)
                return result
            }
            if (view.suppressInput) view.clearSuppression()
            if (before != after) {
                emittedDuringBatch = true
                emitDiff(before, after)
            } else {
                repeat(beforeLength) { view.reportText("\u007f") }
                repeat(afterLength) { view.reportText("\u001b[3~") }
            }
            return result
        }

        override fun beginBatchEdit(): Boolean {
            if (batchDepth == 0) {
                batchBefore = getEditable().toString()
                emittedDuringBatch = false
            }
            batchDepth++
            return super.beginBatchEdit()
        }

        override fun endBatchEdit(): Boolean {
            val result = super.endBatchEdit()
            if (batchDepth > 0) batchDepth--
            if (batchDepth == 0) {
                val before = batchBefore
                batchBefore = null
                val after = getEditable().toString()
                if (before != null && before != after && !emittedDuringBatch && directMutationDepth == 0) {
                    emitDiff(before, after)
                }
            }
            return result
        }

        override fun getExtractedText(request: ExtractedTextRequest?, flags: Int): ExtractedText {
            val editable = getEditable()
            return ExtractedText().apply {
                text = editable.toString()
                startOffset = 0
                partialStartOffset = -1
                partialEndOffset = -1
                selectionStart = Selection.getSelectionStart(editable).coerceAtLeast(0)
                selectionEnd = Selection.getSelectionEnd(editable).coerceAtLeast(0)
            }
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            val callback = view.onKeyEvent ?: return super.sendKeyEvent(event)
            callback(event)
            return true
        }
    }
}
