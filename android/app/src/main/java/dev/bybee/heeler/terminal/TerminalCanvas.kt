// Adapted from chuchu (MIT, jossephus, commit 73dfe07); see android/native/NOTICE.md.
package dev.bybee.heeler.terminal


import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface

import android.view.ViewConfiguration
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.round
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull

@Composable
fun TerminalCanvas(
    snapshot: TerminalSnapshot,
    modifier: Modifier = Modifier,
    fontSizeSp: Float = 14f,
    fitSnapshotToCanvas: Boolean = false,
    enableGestures: Boolean = true,
    cursorColor: Color = Color.White.copy(alpha = 0.28f),
    cursorTextColor: Color? = null,
    selectionBackgroundColor: Color = Color(0x663B82F6),
    selectionForegroundColor: Color? = null,
    // Hoisted: the host owns selection state so it can render drag handles
    // and mutate either endpoint independently.
    selection: TerminalSelection? = null,
    onSelectionChange: (TerminalSelection?) -> Unit = {},
    terminalHandle: Long = 0,
    onResize: (cols: Int, rows: Int, cellWidth: Int, cellHeight: Int, widthPx: Int, heightPx: Int) -> Unit =
        { _, _, _, _, _, _ -> },
    onTap: () -> Unit = {},
    onPrimaryClick: (x: Float, y: Float) -> Unit = { _, _ -> },
    onAppSelectionDrag: (action: Int, x: Float, y: Float) -> Unit = { _, _, _ -> },
    onScroll: (delta: Int, x: Float, y: Float) -> Unit = { _, _, _ -> },
    minFontSizeSp: Float = 1f,
    maxFontSizeSp: Float = Float.MAX_VALUE,
    onFontSizeChange: (sizeSp: Float) -> Unit = {},
    onSelectionChanged: (TerminalSelectionState?) -> Unit = {},
) {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val fontSizePx = with(density) { fontSizeSp.sp.toPx() }
    var canvasSize by remember { mutableStateOf(IntSize.Zero) }
    var lastResizedGrid by remember { mutableStateOf(Pair(0, 0)) }
    val doubleTapState = remember { DoubleTapState() }
    val androidViewConfiguration = remember(context) { ViewConfiguration.get(context) }
    val touchSlopPx = remember(androidViewConfiguration) { androidViewConfiguration.scaledTouchSlop.toFloat() }
    val longPressSlopPx = remember(touchSlopPx) { touchSlopPx * 1.5f }
    val longPressTimeoutMillis = remember { ViewConfiguration.getLongPressTimeout().toLong() }
    val autoScrollEdgeZonePx = with(density) { 48.dp.toPx() }
    val autoScrollIntervalMs = 55L
    val doubleTapTimeoutMillis = remember { ViewConfiguration.getDoubleTapTimeout().toLong() }
    val doubleTapSlopPx = remember(androidViewConfiguration) { androidViewConfiguration.scaledDoubleTapSlop.toFloat() }
    val primaryTypeface = remember(context) {
        runCatching {
            Typeface.createFromAsset(context.assets, "fonts/JetBrainsMono-Regular.ttf")
        }.getOrDefault(Typeface.MONOSPACE)
    }
    val boldPrimaryTypeface = remember(context) {
        runCatching {
            Typeface.createFromAsset(context.assets, "fonts/JetBrainsMono-Bold.ttf")
        }.getOrDefault(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD))
    }
    // Android's system typeface supplies the fallback chain for emoji and glyphs
    // not covered by the bundled JetBrains Mono face.
    val symbolsTypeface = primaryTypeface
    val fallbackTypeface = Typeface.DEFAULT
    val primaryTextPaint = remember(primaryTypeface, fontSizePx) {
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.LEFT
            textSize = fontSizePx
            typeface = primaryTypeface
        }
    }
    val boldPrimaryTextPaint = remember(boldPrimaryTypeface, fontSizePx) {
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.LEFT
            textSize = fontSizePx
            typeface = boldPrimaryTypeface
        }
    }
    val symbolsTextPaint = remember(symbolsTypeface, fontSizePx) {
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.LEFT
            textSize = fontSizePx
            typeface = symbolsTypeface
        }
    }
    val fallbackTextPaint = remember(fallbackTypeface, fontSizePx) {
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.LEFT
            textSize = fontSizePx
            typeface = fallbackTypeface
        }
    }
    // System typeface paint used for color emoji + ZWJ/VS16 shaping. The
    // "symbols" Nerd Font has no color emoji or ZWJ shaping, so emoji clusters
    // (families, flags, ❤️‍🔥, 🧑‍💻, …) must go through this paint to hit
    // Android's NotoColorEmoji fallback.
    val emojiTextPaint = remember(fontSizePx) {
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.LEFT
            textSize = fontSizePx
            typeface = Typeface.DEFAULT
        }
    }
    val bgPaint = remember {
        Paint().apply {
            isAntiAlias = false
            style = Paint.Style.FILL
        }
    }
    val cursorPaint = remember {
        Paint().apply {
            isAntiAlias = false
            style = Paint.Style.FILL
        }
    }
    val drawBuffer = remember { StringBuilder(256) }
    val singleGlyphCache = remember {
        HashMap<Int, String>(256).apply {
            for (cp in 33..126) this[cp] = cp.toChar().toString()
        }
    }
    // Paint-choice caches depend on every typeface in the fallback chain.
    val singlePaintChoiceCache = remember(primaryTypeface, symbolsTypeface, fallbackTypeface) {
        HashMap<Int, Int>(256)
    }
    // Multi-codepoint grapheme cluster paint choice cache.
    val clusterPaintChoiceCache = remember(primaryTypeface, symbolsTypeface, fallbackTypeface) {
        HashMap<String, Int>(64)
    }
    val fontMetrics = primaryTextPaint.fontMetrics
    val measuredHeight = fontMetrics.descent - fontMetrics.ascent
    val cellHeightPx = if (measuredHeight > 1f) measuredHeight else 16f
    val measuredWidth = primaryTextPaint.measureText("M")
    val cellWidthPx = if (measuredWidth > 1f) measuredWidth else 8f
    val baselineOffset = -fontMetrics.ascent
    val cellWidthInt = max(1, ceil(cellWidthPx).toInt())
    val cellHeightInt = max(1, ceil(cellHeightPx).toInt())
    // Snap cell dimensions to integers so the renderer agrees with Ghostty's
    // internal grid.  This eliminates sub-pixel drift that accumulates across
    // rows/columns and misaligns Kitty images.
    val cellWidth = cellWidthInt.toFloat()
    val cellHeight = cellHeightInt.toFloat()
    val selectionBackgroundArgb = selectionBackgroundColor.toArgb()
    val selectionForegroundArgb = selectionForegroundColor?.toArgb()
    val hasSelectionFg = selectionForegroundArgb != null
    val cursorColorArgb = cursorColor.toArgb()
    val cursorTextColorArgb = cursorTextColor?.toArgb()

    val currentOnSelectionChanged = rememberUpdatedState(onSelectionChanged)
    val currentSnapshot = rememberUpdatedState(snapshot)
    val currentSelectionState = rememberUpdatedState(selection)
    val currentOnSelectionChange = rememberUpdatedState(onSelectionChange)
    val currentOnTap = rememberUpdatedState(onTap)
    val currentOnPrimaryClick = rememberUpdatedState(onPrimaryClick)
    val currentOnAppSelectionDrag = rememberUpdatedState(onAppSelectionDrag)
    val currentOnScroll = rememberUpdatedState(onScroll)
    val currentOnFontSizeChange = rememberUpdatedState(onFontSizeChange)
    val currentFontSizeSp = rememberUpdatedState(fontSizeSp)
    val currentMinFontSizeSp = rememberUpdatedState(minFontSizeSp)
    val currentMaxFontSizeSp = rememberUpdatedState(maxFontSizeSp)
    val currentCellWidth = rememberUpdatedState(cellWidth)
    val currentCellHeight = rememberUpdatedState(cellHeight)
    val currentFitSnapshotToCanvas = rememberUpdatedState(fitSnapshotToCanvas)
    val currentHaptics = rememberUpdatedState(haptics)
    val currentTouchSlopPx = rememberUpdatedState(touchSlopPx)
    val currentLongPressSlopPx = rememberUpdatedState(longPressSlopPx)
    val currentLongPressTimeoutMillis = rememberUpdatedState(longPressTimeoutMillis)
    val currentAutoScrollEdgeZonePx = rememberUpdatedState(autoScrollEdgeZonePx)
    val currentDoubleTapTimeoutMillis = rememberUpdatedState(doubleTapTimeoutMillis)
    val currentDoubleTapSlopPx = rememberUpdatedState(doubleTapSlopPx)

    var selectionViewportBaseline by remember { mutableStateOf<Int?>(null) }
    var autoScrollingSelection by remember { mutableStateOf(false) }

    val scrollDeltaChannel = remember { Channel<TerminalScrollDelta>(capacity = Channel.UNLIMITED) }
    LaunchedEffect(scrollDeltaChannel) {
        while (isActive) {
            val first = scrollDeltaChannel.receive()
            var accumulated = first.delta
            var latest = first
            while (true) {
                val next = scrollDeltaChannel.tryReceive().getOrNull() ?: break
                accumulated += next.delta
                latest = next
            }
            if (accumulated != 0) {
                currentOnScroll.value(accumulated, latest.x, latest.y)
            }
            withFrameNanos { }
        }
    }

    val currentSelection = selection
    if (currentSelection != null) {
        LaunchedEffect(snapshot, currentSelection, cellWidth, cellHeight, canvasSize, terminalHandle) {
            currentOnSelectionChanged.value(
                buildSelectionState(
                    snapshot = snapshot,
                    selection = currentSelection,
                    cellWidth = cellWidth,
                    cellHeight = cellHeight,
                    canvasWidthPx = canvasSize.width,
                    canvasHeightPx = canvasSize.height,
                    terminalHandle = terminalHandle,
                ),
            )
        }
    } else {
        LaunchedEffect(currentSelection) {
            currentOnSelectionChanged.value(null)
        }
    }
    val hasSelection = selection != null
    LaunchedEffect(hasSelection) {
        selectionViewportBaseline = if (hasSelection) currentSnapshot.value.viewportScrollY else null
    }

    LaunchedEffect(snapshot) {
        remapSelectionForViewportScroll(
            snapshot = snapshot,
            selection = currentSelectionState.value,
            baseline = selectionViewportBaseline,
            autoScrollingSelection = autoScrollingSelection,
            onBaselineChange = { selectionViewportBaseline = it },
            onSelectionChange = currentOnSelectionChange.value,
        )
    }

    LaunchedEffect(canvasSize, cellWidth, cellHeight) {
        if (canvasSize.width <= 0 || canvasSize.height <= 0) return@LaunchedEffect
        val cols = max(1, floor(canvasSize.width / cellWidth).toInt())
        val rows = max(1, floor(canvasSize.height / cellHeight).toInt())
        val grid = Pair(cols, rows)
        if (grid != lastResizedGrid) {
            lastResizedGrid = grid
            onResize(cols, rows, cellWidthInt, cellHeightInt, canvasSize.width, canvasSize.height)
        }
    }

    val canvasModifier = modifier
        .fillMaxSize()
        .onSizeChanged { size ->
            canvasSize = size
        }
        .let { baseModifier ->
            if (!enableGestures) {
                baseModifier
            } else {
                baseModifier.pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        fun toSnapshotSpace(position: Offset, s: TerminalSnapshot): Offset {
                            if (!currentFitSnapshotToCanvas.value) return position
                            val cols = max(s.cols, 1)
                            val rows = max(s.rows, 1)
                            val contentWidth = cols * currentCellWidth.value
                            val contentHeight = rows * currentCellHeight.value
                            if (contentWidth <= 0f || contentHeight <= 0f) return position
                            val scale = minOf(canvasSize.width / contentWidth, canvasSize.height / contentHeight)
                            if (scale <= 0f) return position
                            val offsetX = ((canvasSize.width - (contentWidth * scale)) * 0.5f).coerceAtLeast(0f)
                            val offsetY = ((canvasSize.height - (contentHeight * scale)) * 0.5f).coerceAtLeast(0f)
                            return Offset((position.x - offsetX) / scale, (position.y - offsetY) / scale)
                        }
                        var dragRemainder = 0f
                        var startPinchDistance: Float? = null
                        var anchorFontSp = 0f
                        var lastSentSp = 0f
                        var didScroll = false
                        var didPinch = false
                        var didDragGesture = false
                        var selectionCleared = false
                        var lastSinglePointerId = down.id
                        var dragMode = DragMode.None
                        var lastEventUptime = down.uptimeMillis
                        val longPressDeadline = down.uptimeMillis + currentLongPressTimeoutMillis.value
                        var lastPointerPos = down.position
                        var autoScrollDir = 0

                        try {
                            while (true) {
                                val timeoutMs = (longPressDeadline - lastEventUptime).coerceAtLeast(1L)
                                val inAutoScrollZone = dragMode == DragMode.ClientSelectionDrag && autoScrollDir != 0
                                val event = when {
                                    dragMode == DragMode.None && !didScroll && !didPinch && !didDragGesture ->
                                        withTimeoutOrNull(timeoutMs) { awaitPointerEvent() }
                                    inAutoScrollZone ->
                                        withTimeoutOrNull(autoScrollIntervalMs) { awaitPointerEvent() }
                                    else -> awaitPointerEvent()
                                }

                                if (event == null) {
                                    if (dragMode == DragMode.None) {
                                        val s = currentSnapshot.value
                                        val downPos = toSnapshotSpace(down.position, s)
                                        if (s.appHandlesSelectionDrag) {
                                            currentOnAppSelectionDrag.value(TerminalMouseAction.Press, downPos.x, downPos.y)
                                            currentHaptics.value.performHapticFeedback(
                                                HapticFeedbackType.LongPress,
                                            )
                                            didDragGesture = true
                                            dragMode = DragMode.AppMouseDrag
                                        } else if (startSelection(
                                                s,
                                                downPos,
                                                currentCellWidth.value,
                                                currentCellHeight.value,
                                                currentOnSelectionChange.value,
                                            )
                                        ) {
                                            currentHaptics.value.performHapticFeedback(
                                                HapticFeedbackType.LongPress,
                                            )
                                            dragMode = DragMode.ClientSelectionDrag
                                        }
                                        continue
                                    }
                                    val pos = lastPointerPos
                                    val depth = if (autoScrollDir > 0) {
                                        pos.y - (canvasSize.height - currentAutoScrollEdgeZonePx.value)
                                    } else {
                                        currentAutoScrollEdgeZonePx.value - pos.y
                                    }.coerceAtLeast(0f)
                                    val rows = (depth / currentCellHeight.value).toInt().coerceIn(1, 8)
                                    scrollDeltaChannel.trySend(
                                        TerminalScrollDelta(autoScrollDir * rows, pos.x, pos.y),
                                    )
                                    continue
                                }

                                lastEventUptime = event.changes.maxOfOrNull { it.uptimeMillis } ?: lastEventUptime
                                val pressed = event.changes.filter { it.pressed }
                                if (pressed.isEmpty()) {
                                    autoScrollDir = 0
                                    autoScrollingSelection = false
                                    val releasedDragMode = dragMode
                                    dragMode = DragMode.None
                                    if (releasedDragMode == DragMode.AppMouseDrag) {
                                        val s = currentSnapshot.value
                                        val releasePos = toSnapshotSpace(lastPointerPos, s)
                                        currentOnAppSelectionDrag.value(TerminalMouseAction.Release, releasePos.x, releasePos.y)
                                    }
                                    if (releasedDragMode != DragMode.None) {
                                        break
                                    }
                                    if (!didScroll && !didPinch && !didDragGesture) {
                                        val tapTime = event.changes.maxOfOrNull { it.uptimeMillis } ?: lastEventUptime
                                        val s = currentSnapshot.value
                                        val tapPos = toSnapshotSpace(down.position, s)
                                        val timeSinceLastTap = tapTime - doubleTapState.lastTime
                                        val distSinceLastTap = hypot(
                                            (tapPos.x - doubleTapState.lastPos.x).toDouble(),
                                            (tapPos.y - doubleTapState.lastPos.y).toDouble(),
                                        ).toFloat()
                                        doubleTapState.lastTime = tapTime
                                        doubleTapState.lastPos = tapPos

                                        if (timeSinceLastTap < currentDoubleTapTimeoutMillis.value &&
                                            distSinceLastTap < currentDoubleTapSlopPx.value
                                        ) {
                                            val cellIdx = s.cellAt(
                                                tapPos.x,
                                                tapPos.y,
                                                currentCellWidth.value,
                                                currentCellHeight.value,
                                            )
                                            if (cellIdx != null) {
                                                val wordRange = s.wordAt(cellIdx)
                                                if (wordRange != null) {
                                                    currentOnSelectionChange.value(TerminalSelection(wordRange.first, wordRange.last))
                                                    currentHaptics.value.performHapticFeedback(
                                                        HapticFeedbackType.LongPress,
                                                    )
                                                }
                                            }
                                        } else {
                                            if (currentSelectionState.value != null) {
                                                currentOnSelectionChange.value(null)
                                            } else {
                                                currentOnPrimaryClick.value(tapPos.x, tapPos.y)
                                                currentOnTap.value()
                                            }
                                        }
                                    }
                                    break
                                }

                                if (pressed.size >= 2) {
                                    didPinch = true
                                    val first = pressed[0].position
                                    val second = pressed[1].position
                                    val distance = hypot(
                                        (first.x - second.x).toDouble(),
                                        (first.y - second.y).toDouble(),
                                    ).toFloat()
                                    if (startPinchDistance == null && distance > 0f) {
                                        startPinchDistance = distance
                                        anchorFontSp = currentFontSizeSp.value
                                        lastSentSp = round(anchorFontSp)
                                    }
                                    val startDistance = startPinchDistance
                                    if (startDistance != null && distance > 0f) {
                                        val steppedSp = round(anchorFontSp * (distance / startDistance))
                                            .coerceIn(currentMinFontSizeSp.value, currentMaxFontSizeSp.value)
                                        if (steppedSp != lastSentSp) {
                                            currentOnFontSizeChange.value(steppedSp)
                                            currentHaptics.value.performHapticFeedback(
                                                HapticFeedbackType.TextHandleMove,
                                            )
                                            lastSentSp = steppedSp
                                        }
                                    }
                                    pressed.forEach { change ->
                                        if (change.position != change.previousPosition) change.consume()
                                    }
                                    continue
                                }

                                startPinchDistance = null
                                val change = pressed.firstOrNull { it.id == lastSinglePointerId } ?: pressed.first().also {
                                    lastSinglePointerId = it.id
                                }

                                // Selection drag takes priority once activated
                                val s = currentSnapshot.value
                                val changePos = toSnapshotSpace(change.position, s)
                                val changePrevPos = toSnapshotSpace(change.previousPosition, s)
                                val downPos = toSnapshotSpace(down.position, s)
                                val selectedCell = s.cellAt(
                                    changePos.x,
                                    changePos.y,
                                    currentCellWidth.value,
                                    currentCellHeight.value,
                                )
                                if (dragMode == DragMode.AppMouseDrag) {
                                    lastPointerPos = change.position
                                    autoScrollDir = 0
                                    autoScrollingSelection = false
                                    if (change.position != change.previousPosition) {
                                        currentOnAppSelectionDrag.value(TerminalMouseAction.Motion, changePos.x, changePos.y)
                                        change.consume()
                                    }
                                    continue
                                }
                                if (dragMode == DragMode.ClientSelectionDrag && selectedCell != null) {
                                    lastPointerPos = change.position
                                    updateSelectionDrag(
                                        existing = currentSelectionState.value,
                                        selectedCell = selectedCell,
                                        onSelectionChange = currentOnSelectionChange.value,
                                    )
                                    autoScrollDir = when {
                                        change.position.y < currentAutoScrollEdgeZonePx.value -> -1
                                        change.position.y > canvasSize.height - currentAutoScrollEdgeZonePx.value -> 1
                                        else -> 0
                                    }
                                    autoScrollingSelection = autoScrollDir != 0
                                    if (change.position != change.previousPosition) {
                                        change.consume()
                                    }
                                    continue
                                }

                                val dragX = changePos.x - changePrevPos.x
                                val dragY = changePos.y - changePrevPos.y
                                val movedDistance = hypot(
                                    (changePos.x - downPos.x).toDouble(),
                                    (changePos.y - downPos.y).toDouble(),
                                ).toFloat()
                                val abortSlopPx = if (dragMode != DragMode.None) {
                                    currentTouchSlopPx.value
                                } else {
                                    currentLongPressSlopPx.value
                                }
                                if (movedDistance > abortSlopPx) {
                                    didDragGesture = true
                                    if (currentSelectionState.value != null && !selectionCleared) {
                                        currentOnSelectionChange.value(null)
                                        selectionCleared = true
                                    }
                                }
                                autoScrollDir = 0
                                autoScrollingSelection = false
                                val verticalIntent = abs(dragY) > abs(dragX) * 1.2f
                                if (verticalIntent) {
                                    dragRemainder += dragY / currentCellHeight.value
                                }

                                if (didDragGesture && abs(dragRemainder) >= 1f) {
                                    val delta = dragRemainder.toInt()
                                    dragRemainder -= delta
                                    if (delta != 0) {
                                        didScroll = true
                                        scrollDeltaChannel.trySend(TerminalScrollDelta(-delta, changePos.x, changePos.y))
                                    }
                                }

                                if (change.position != change.previousPosition) {
                                    change.consume()
                                }
                            }
                        } finally {
                            autoScrollingSelection = false
                            if (dragMode == DragMode.AppMouseDrag) {
                                val s = currentSnapshot.value
                                val releasePos = toSnapshotSpace(lastPointerPos, s)
                                currentOnAppSelectionDrag.value(
                                    TerminalMouseAction.Release,
                                    releasePos.x,
                                    releasePos.y,
                                )
                            }
                        }
                    }
                }
            }
        }

    Canvas(modifier = canvasModifier) {
        val cols = max(snapshot.cols, 1)
        val rows = max(snapshot.rows, 1)
        val contentWidth = cols * cellWidth
        val contentHeight = rows * cellHeight
        val previewScale = if (fitSnapshotToCanvas && contentWidth > 0f && contentHeight > 0f) {
            minOf(size.width / contentWidth, size.height / contentHeight)
        } else {
            1f
        }
        val contentOffsetX = if (fitSnapshotToCanvas) {
            ((size.width - (contentWidth * previewScale)) * 0.5f).coerceAtLeast(0f)
        } else {
            0f
        }
        val contentOffsetY = if (fitSnapshotToCanvas) {
            ((size.height - (contentHeight * previewScale)) * 0.5f).coerceAtLeast(0f)
        } else {
            0f
        }
        val sel = selection?.normalized(snapshot.codepoints.size)
        val selStart = sel?.first ?: -1
        val selEnd = sel?.last ?: -1
        val hasSel = sel != null

        drawRect(color = Color(snapshot.defaultBgArgb))

        drawIntoCanvas { canvas ->
            val nCanvas = canvas.nativeCanvas
            nCanvas.save()
            nCanvas.translate(contentOffsetX, contentOffsetY)
            if (previewScale != 1f) {
                nCanvas.scale(previewScale, previewScale)
            }
            val sb = drawBuffer
            val defaultBg = snapshot.defaultBgArgb

            for (row in 0 until rows) {
                val rowStart = row * cols
                val y = row * cellHeight
                val baseline = y + baselineOffset

                // Background runs
                var i = rowStart
                val rowEnd = rowStart + cols
                while (i < rowEnd) {
                    val iSelected = hasSel && i in selStart..selEnd
                    val iInverse = !iSelected &&
                        (snapshot.flags[i].toInt() and TerminalSnapshot.CELL_FLAG_INVERSE) != 0
                    val bg = when {
                        iSelected -> selectionBackgroundArgb
                        iInverse -> snapshot.fgArgb[i]
                        else -> snapshot.bgArgb[i]
                    }
                    var j = i + 1
                    while (j < rowEnd) {
                        val jSelected = hasSel && j in selStart..selEnd
                        val jInverse = !jSelected &&
                            (snapshot.flags[j].toInt() and TerminalSnapshot.CELL_FLAG_INVERSE) != 0
                        val nextBg = when {
                            jSelected -> selectionBackgroundArgb
                            jInverse -> snapshot.fgArgb[j]
                            else -> snapshot.bgArgb[j]
                        }
                        if (nextBg != bg || jInverse != iInverse) break
                        j++
                    }
                    if (iSelected || bg != defaultBg || iInverse) {
                        bgPaint.color = bg
                        nCanvas.drawRect(
                            (i - rowStart) * cellWidth,
                            y,
                            (j - rowStart) * cellWidth,
                            y + cellHeight,
                            bgPaint,
                        )
                    }
                    i = j
                }

                // Text runs
                i = rowStart
                while (i < rowEnd) {
                    val cp = snapshot.codepoints[i]
                    if (cp == 0 || cp == 32) {
                        i++
                        continue
                    }

                    val firstFlags = snapshot.flags[i].toInt()
                    val firstSelected = hasSel && i in selStart..selEnd
                    val firstInverse = !firstSelected &&
                        (firstFlags and TerminalSnapshot.CELL_FLAG_INVERSE) != 0
                    val fg = when {
                        firstSelected && hasSelectionFg -> selectionForegroundArgb
                        firstInverse -> snapshot.bgArgb[i]
                        else -> snapshot.fgArgb[i]
                    }
                    val styleBits = firstFlags and TEXT_STYLE_MASK
                    val firstExtras = snapshot.graphemeExtras[i]
                    val firstGlyph = if (firstExtras == null || firstExtras.isEmpty()) null else snapshot.glyphAt(i)
                    val firstPaintChoice = if (firstGlyph == null) {
                        pickPaintChoice(
                            codepoint = cp,
                            glyphCache = singleGlyphCache,
                            cache = singlePaintChoiceCache,
                            primaryPaint = primaryTextPaint,
                            symbolsPaint = symbolsTextPaint,
                            fallbackPaint = fallbackTextPaint,
                            emojiPaint = emojiTextPaint,
                        )
                    } else {
                        pickPaintChoice(
                            glyph = firstGlyph,
                            cache = clusterPaintChoiceCache,
                            primaryPaint = primaryTextPaint,
                            symbolsPaint = symbolsTextPaint,
                            fallbackPaint = fallbackTextPaint,
                            emojiPaint = emojiTextPaint,
                        )
                    }
                    sb.setLength(0)
                    if (firstGlyph == null) sb.appendCodePoint(cp) else sb.append(firstGlyph)
                    val startCol = i - rowStart
                    val firstIsWide = i + 1 < rowEnd && snapshot.isSpacerContinuation(i + 1)
                    var j = if (firstIsWide) i + 2 else i + 1

                    while (j < rowEnd) {
                        val c = snapshot.codepoints[j]
                        if (c == 0) break
                        if (c == 32 && !snapshot.isSpacerContinuation(j)) break
                        if (j + 1 < rowEnd && snapshot.isSpacerContinuation(j + 1)) break

                        val jFlags = snapshot.flags[j].toInt()
                        val jSelected = hasSel && j in selStart..selEnd
                        val jInverse = !jSelected &&
                            (jFlags and TerminalSnapshot.CELL_FLAG_INVERSE) != 0
                        val nextFg = when {
                            jSelected && hasSelectionFg -> selectionForegroundArgb
                            jInverse -> snapshot.bgArgb[j]
                            else -> snapshot.fgArgb[j]
                        }
                        if (nextFg != fg) break
                        if ((jFlags and TEXT_STYLE_MASK) != styleBits) break

                        if (c == 32) {
                            j++
                            continue
                        }

                        val extras = snapshot.graphemeExtras[j]
                        val glyph = if (extras == null || extras.isEmpty()) null else snapshot.glyphAt(j)
                        val nextPaintChoice = if (glyph == null) {
                            pickPaintChoice(
                                codepoint = c,
                                glyphCache = singleGlyphCache,
                                cache = singlePaintChoiceCache,
                                primaryPaint = primaryTextPaint,
                                symbolsPaint = symbolsTextPaint,
                                fallbackPaint = fallbackTextPaint,
                                emojiPaint = emojiTextPaint,
                            )
                        } else {
                            pickPaintChoice(
                                glyph = glyph,
                                cache = clusterPaintChoiceCache,
                                primaryPaint = primaryTextPaint,
                                symbolsPaint = symbolsTextPaint,
                                fallbackPaint = fallbackTextPaint,
                                emojiPaint = emojiTextPaint,
                            )
                        }
                        if (nextPaintChoice != firstPaintChoice) break

                        if (glyph == null) sb.appendCodePoint(c) else sb.append(glyph)
                        j++
                    }

                    val isBold = (styleBits and TerminalSnapshot.CELL_FLAG_BOLD) != 0
                    val paint = if (isBold && firstPaintChoice == PAINT_PRIMARY) {
                        boldPrimaryTextPaint
                    } else {
                        paintForChoice(
                            choice = firstPaintChoice,
                            primaryPaint = primaryTextPaint,
                            symbolsPaint = symbolsTextPaint,
                            fallbackPaint = fallbackTextPaint,
                            emojiPaint = emojiTextPaint,
                        )
                    }
                    paint.color = fg
                    paint.isFakeBoldText = isBold && firstPaintChoice != PAINT_PRIMARY
                    paint.isUnderlineText = (styleBits and TerminalSnapshot.CELL_FLAG_UNDERLINE) != 0
                    paint.textSkewX = if ((styleBits and TerminalSnapshot.CELL_FLAG_ITALIC) != 0) -0.25f else 0f
                    paint.alpha = if ((styleBits and TerminalSnapshot.CELL_FLAG_FAINT) != 0) FAINT_TEXT_ALPHA else 255
                    nCanvas.drawText(sb.toString(), startCol * cellWidth, baseline, paint)
                    i = j
                }
            }

            // Images: origin from cell coords (same cell size as text, so it lands
            // on the grid); size is libghostty's scaled dest_w/dest_h, already
            // centered by cell_*_offset. Don't recompute size as grid*cell.
            for (img in snapshot.images) {
                val srcRect = Rect(img.srcX, img.srcY, img.srcX + img.srcW, img.srcY + img.srcH)
                val imgDestX = (img.cellCol * cellWidth + img.cellXOffset.toFloat()).toInt()
                val imgDestY = (img.cellRow * cellHeight + img.cellYOffset.toFloat()).toInt()
                val imgDestW = img.destW
                val imgDestH = img.destH
                val dstRect = RectF(
                    imgDestX.toFloat(),
                    imgDestY.toFloat(),
                    (imgDestX + imgDestW).toFloat(),
                    (imgDestY + imgDestH).toFloat(),
                )
                nCanvas.drawBitmap(img.bitmap, srcRect, dstRect, null)
            }

            if (snapshot.cursorVisible && snapshot.cursorX in 0 until cols && snapshot.cursorY in 0 until rows) {
                val cursorLeft = snapshot.cursorX * cellWidth
                val cursorTop = snapshot.cursorY * cellHeight
                cursorPaint.color = cursorColorArgb
                nCanvas.drawRect(
                    cursorLeft,
                    cursorTop,
                    cursorLeft + cellWidth,
                    cursorTop + cellHeight,
                    cursorPaint,
                )

                val cursorIndex = snapshot.cursorY * cols + snapshot.cursorX
                if (cursorTextColorArgb != null && cursorIndex in snapshot.codepoints.indices) {
                    val codepoint = snapshot.codepoints[cursorIndex]
                    if (codepoint != 0 && codepoint != 32) {
                        val extras = snapshot.graphemeExtras[cursorIndex]
                        val glyph = if (extras == null || extras.isEmpty()) {
                            singleGlyphCache.getOrPut(codepoint) { String(Character.toChars(codepoint)) }
                        } else {
                            snapshot.glyphAt(cursorIndex)
                        }
                        val cursorPaintChoice = if (extras == null || extras.isEmpty()) {
                            pickPaintChoice(
                                codepoint = codepoint,
                                glyphCache = singleGlyphCache,
                                cache = singlePaintChoiceCache,
                                primaryPaint = primaryTextPaint,
                                symbolsPaint = symbolsTextPaint,
                                fallbackPaint = fallbackTextPaint,
                                emojiPaint = emojiTextPaint,
                            )
                        } else {
                            pickPaintChoice(
                                glyph = glyph,
                                cache = clusterPaintChoiceCache,
                                primaryPaint = primaryTextPaint,
                                symbolsPaint = symbolsTextPaint,
                                fallbackPaint = fallbackTextPaint,
                                emojiPaint = emojiTextPaint,
                            )
                        }
                        val paint = paintForChoice(
                            choice = cursorPaintChoice,
                            primaryPaint = primaryTextPaint,
                            symbolsPaint = symbolsTextPaint,
                            fallbackPaint = fallbackTextPaint,
                            emojiPaint = emojiTextPaint,
                        )
                        paint.isFakeBoldText = false
                        paint.isUnderlineText = false
                        paint.textSkewX = 0f
                        paint.alpha = 255
                        paint.color = cursorTextColorArgb
                        nCanvas.drawText(
                            glyph,
                            cursorLeft,
                            cursorTop + baselineOffset,
                            paint,
                        )
                    }
                }
            }
            nCanvas.restore()
        }
    }
}

private data class TerminalScrollDelta(
    val delta: Int,
    val x: Float,
    val y: Float,
)

private fun startSelection(
    snapshot: TerminalSnapshot,
    downPos: Offset,
    cellWidth: Float,
    cellHeight: Float,
    onSelectionChange: (TerminalSelection?) -> Unit,
): Boolean {
    val selectedCell = snapshot.cellAt(downPos.x, downPos.y, cellWidth, cellHeight)
    onSelectionChange(selectedCell?.let { TerminalSelection(it, it) })
    return selectedCell != null
}

private fun updateSelectionDrag(
    existing: TerminalSelection?,
    selectedCell: Int,
    onSelectionChange: (TerminalSelection?) -> Unit,
) {
    if (existing == null || existing.focusIndex != selectedCell) {
        onSelectionChange(
            (existing ?: TerminalSelection(selectedCell, selectedCell)).copy(focusIndex = selectedCell),
        )
    }
}

private fun remapSelectionForViewportScroll(
    snapshot: TerminalSnapshot,
    selection: TerminalSelection?,
    baseline: Int?,
    autoScrollingSelection: Boolean,
    onBaselineChange: (Int) -> Unit,
    onSelectionChange: (TerminalSelection?) -> Unit,
) {
    val sel = selection ?: return
    val startBaseline = baseline ?: return
    val cur = snapshot.viewportScrollY
    if (startBaseline == cur) return
    val deltaCells = (startBaseline - cur) * max(snapshot.cols, 1)
    onBaselineChange(cur)
    onSelectionChange(
        if (autoScrollingSelection) sel.copy(anchorIndex = sel.anchorIndex + deltaCells)
        else sel.copy(anchorIndex = sel.anchorIndex + deltaCells, focusIndex = sel.focusIndex + deltaCells),
    )
}

private fun TerminalSnapshot.cellAt(x: Float, y: Float, cellWidth: Float, cellHeight: Float): Int? {
    if (cols <= 0 || rows <= 0 || cellWidth <= 0f || cellHeight <= 0f) return null
    val col = floor(x / cellWidth).toInt().coerceIn(0, cols - 1)
    val row = floor(y / cellHeight).toInt().coerceIn(0, rows - 1)
    return row * cols + col
}

internal fun TerminalSnapshot.isSpacerContinuation(cellIndex: Int): Boolean {
    return ((flags[cellIndex].toInt() and 0xFF) and TerminalSnapshot.CELL_FLAG_SPACER) != 0
}

internal fun TerminalSnapshot.glyphAt(cellIndex: Int): String {
    val codepoint = codepoints[cellIndex]
    val extras = graphemeExtras[cellIndex]
    if (extras == null || extras.isEmpty()) return String(Character.toChars(codepoint))
    val builder = StringBuilder(1 + extras.size)
    builder.appendCodePoint(codepoint)
    for (cp in extras) builder.appendCodePoint(cp)
    return builder.toString()
}

private const val FAINT_TEXT_ALPHA: Int = 96

private const val TEXT_STYLE_MASK: Int =
    TerminalSnapshot.CELL_FLAG_BOLD or
        TerminalSnapshot.CELL_FLAG_ITALIC or
        TerminalSnapshot.CELL_FLAG_UNDERLINE or
        TerminalSnapshot.CELL_FLAG_FAINT

private const val PAINT_PRIMARY: Int = 0
private const val PAINT_SYMBOLS: Int = 1
private const val PAINT_FALLBACK: Int = 2
private const val PAINT_EMOJI: Int = 3

/**
 * Decide which paint should render a grapheme cluster.
 *
 * Order of preference:
 *  1. If the primary text font can render the cluster, use it (keeps code
 *     glyph metrics intact).
 *  2. Else, if the first codepoint lives in a Nerd Font private-use range
 *     and the symbols paint has the glyph, use the symbols (Nerd Font) paint.
 *  3. Else, use Android's system fallback when it covers the complete glyph.
 *  4. Else, use bundled Noto Sans Symbols 2 as a deterministic symbol fallback.
 *  5. Finally, use the system paint to render its missing-glyph marker.
 *
 * The system emoji paint routes
 *     through Android's NotoColorEmoji + font fallback chain and is the only
 *     paint that can shape emoji ZWJ sequences, regional-indicator flag
 *     pairs, and VS16-promoted color emoji.
 */
private fun pickPaintChoice(
    glyph: String,
    cache: HashMap<String, Int>,
    primaryPaint: Paint,
    symbolsPaint: Paint,
    fallbackPaint: Paint,
    emojiPaint: Paint,
): Int {
    return cache.getOrPut(glyph) {
        if (primaryPaint.hasGlyph(glyph)) return@getOrPut PAINT_PRIMARY
        val firstCp = glyph.codePointAt(0)
        if (isNerdFontPrivateUse(firstCp) && symbolsPaint.hasGlyph(glyph)) {
            return@getOrPut PAINT_SYMBOLS
        }
        if (emojiPaint.hasGlyph(glyph)) return@getOrPut PAINT_EMOJI
        if (fallbackPaint.hasGlyph(glyph)) return@getOrPut PAINT_FALLBACK
        PAINT_EMOJI
    }
}

private fun pickPaintChoice(
    codepoint: Int,
    glyphCache: HashMap<Int, String>,
    cache: HashMap<Int, Int>,
    primaryPaint: Paint,
    symbolsPaint: Paint,
    fallbackPaint: Paint,
    emojiPaint: Paint,
): Int {
    // Fast path for the overwhelmingly common command-output ASCII glyphs.
    if (codepoint in 0x21..0x7E) return PAINT_PRIMARY

    return cache.getOrPut(codepoint) {
        val glyph = glyphCache.getOrPut(codepoint) { String(Character.toChars(codepoint)) }
        if (primaryPaint.hasGlyph(glyph)) return@getOrPut PAINT_PRIMARY
        if (isNerdFontPrivateUse(codepoint) && symbolsPaint.hasGlyph(glyph)) {
            return@getOrPut PAINT_SYMBOLS
        }
        if (emojiPaint.hasGlyph(glyph)) return@getOrPut PAINT_EMOJI
        if (fallbackPaint.hasGlyph(glyph)) return@getOrPut PAINT_FALLBACK
        PAINT_EMOJI
    }
}

private fun paintForChoice(
    choice: Int,
    primaryPaint: Paint,
    symbolsPaint: Paint,
    fallbackPaint: Paint,
    emojiPaint: Paint,
): Paint = when (choice) {
    PAINT_SYMBOLS -> symbolsPaint
    PAINT_FALLBACK -> fallbackPaint
    PAINT_EMOJI -> emojiPaint
    else -> primaryPaint
}

/**
 * Private Use Area ranges where Nerd Font glyphs live (devicons, powerline,
 * weather icons, file-type icons, etc.). Everything outside these ranges that
 * the primary font cannot render is treated as an emoji/symbol cluster.
 */
private fun isNerdFontPrivateUse(cp: Int): Boolean {
    return (cp in 0xE000..0xF8FF) ||
        (cp in 0xF0000..0xFFFFD) ||
        (cp in 0x100000..0x10FFFD)
}

private enum class DragMode {
    None,
    ClientSelectionDrag,
    AppMouseDrag,
}

/** Tracks double-tap timing/position without triggering Compose recomposition. */
private class DoubleTapState {
    var lastTime: Long = 0L
    var lastPos: Offset = Offset.Zero
}
