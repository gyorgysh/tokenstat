// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.annotation.SuppressLint
import android.content.Context
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import kotlin.math.abs
import kotlin.math.hypot

class ScreenInputActions(
    val move: (Float, Float) -> Unit,
    val nudge: (Float, Float, Float, Float) -> Unit,
    val click: (Int, Int) -> Unit,
    val press: (Boolean) -> Unit,
    val scroll: (Float, Float) -> Unit,
    val panView: (Float, Float, Float, Float) -> Unit,
    val text: (String, Long) -> Unit,
    val key: (Int, Boolean, Long) -> Unit,
    val magnify: (Float, Float, Float) -> Unit,
    val modifiersSpent: () -> Unit,
    val tapWhileWatching: () -> Unit,
)

@SuppressLint("ViewConstructor")
class ScreenTouchView(context: Context) : View(context) {
    var actions: ScreenInputActions? = null
    var inputEnabled: Boolean = false
    var mode: ScreenPointerMode = ScreenPointerMode.Trackpad
    var zoomed: Boolean = false

    var modifiers: Long = 0

    private val density = context.resources.displayMetrics.density
    private val slop = 8f * density

    private var dragging = false
    private var panning = false
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f

    private var twoFingers = false
    private var twoFingerDownAt = 0L
    private var twoFingerTravel = 0f
    private var pinched = false
    private var lastFocusX = 0f
    private var lastFocusY = 0f

    private val taps = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent) = true

        override fun onSingleTapConfirmed(event: MotionEvent): Boolean {
            if (!inputEnabled) {
                actions?.tapWhileWatching?.invoke()
                return true
            }
            positionForTap(event.x, event.y)
            actions?.click(0, 1)
            spendModifiers()
            return true
        }

        override fun onDoubleTap(event: MotionEvent): Boolean {
            if (!inputEnabled) return false
            positionForTap(event.x, event.y)
            actions?.click(0, 2)
            spendModifiers()
            return true
        }

        override fun onLongPress(event: MotionEvent) {
            if (!inputEnabled || twoFingers) return
            positionForTap(event.x, event.y)
            dragging = true
            actions?.press(true)
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        }
    })

    private val pinches = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                pinched = true
                actions?.magnify(detector.scaleFactor, width.toFloat(), height.toFloat())
                return true
            }
        },
    )

    init {
        isFocusableInTouchMode = true
        isClickable = true
        setWillNotDraw(true)
    }

    private fun positionForTap(x: Float, y: Float) {
        if (mode != ScreenPointerMode.Direct) return
        val (nx, ny) = normalized(x, y)
        actions?.move(nx, ny)
    }

    private fun normalized(x: Float, y: Float): Pair<Float, Float> =
        (x / width.coerceAtLeast(1)).coerceIn(0f, 1f) to
            (y / height.coerceAtLeast(1)).coerceIn(0f, 1f)

    private fun spendModifiers() {
        if (modifiers == 0L) return
        modifiers = 0
        actions?.modifiersSpent?.invoke()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        pinches.onTouchEvent(event)
        if (!twoFingers && event.pointerCount < 2) taps.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                lastX = event.x
                lastY = event.y
                panning = false
            }
            MotionEvent.ACTION_POINTER_DOWN -> if (event.pointerCount == 2) {
                twoFingers = true
                twoFingerDownAt = event.eventTime
                twoFingerTravel = 0f
                pinched = false
                val cancel = MotionEvent.obtain(event)
                cancel.action = MotionEvent.ACTION_CANCEL
                taps.onTouchEvent(cancel)
                cancel.recycle()
                lastFocusX = focusX(event)
                lastFocusY = focusY(event)
                panning = false
            }
            MotionEvent.ACTION_MOVE -> if (twoFingers) twoFingerMove(event) else oneFingerMove(event)
            MotionEvent.ACTION_POINTER_UP -> if (twoFingers && event.pointerCount == 2) {
                val quick = event.eventTime - twoFingerDownAt < TWO_FINGER_TAP_MS
                if (inputEnabled && quick && !pinched && twoFingerTravel < slop) {
                    positionForTap(focusX(event), focusY(event))
                    actions?.click(1, 1)
                    spendModifiers()
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragging) {
                    dragging = false
                    actions?.press(false)
                    spendModifiers()
                }
                twoFingers = false
                panning = false
            }
        }
        return true
    }

    private fun focusX(event: MotionEvent): Float {
        var total = 0f
        for (index in 0 until event.pointerCount) total += event.getX(index)
        return total / event.pointerCount
    }

    private fun focusY(event: MotionEvent): Float {
        var total = 0f
        for (index in 0 until event.pointerCount) total += event.getY(index)
        return total / event.pointerCount
    }

    private fun twoFingerMove(event: MotionEvent) {
        val x = focusX(event)
        val y = focusY(event)
        val dx = x - lastFocusX
        val dy = y - lastFocusY
        lastFocusX = x
        lastFocusY = y
        twoFingerTravel += hypot(dx, dy)
        if (pinches.isInProgress) return
        if (!inputEnabled) return
        actions?.scroll(dx / density, dy / density)
    }

    private fun oneFingerMove(event: MotionEvent) {
        val dx = event.x - lastX
        val dy = event.y - lastY
        lastX = event.x
        lastY = event.y
        if (!panning && !dragging &&
            abs(event.x - downX) + abs(event.y - downY) < slop
        ) return
        panning = true
        val handlers = actions ?: return
        if (!inputEnabled) {
            if (zoomed) handlers.panView(dx, dy, width.toFloat(), height.toFloat())
            return
        }
        when (mode) {
            ScreenPointerMode.Trackpad ->
                handlers.nudge(dx, dy, width.toFloat(), height.toFloat())
            ScreenPointerMode.Direct -> {
                val (nx, ny) = normalized(event.x, event.y)
                handlers.move(nx, ny)
            }
        }
    }


    override fun onCheckIsTextEditor(): Boolean = inputEnabled

    override fun onCreateInputConnection(info: EditorInfo): InputConnection {
        info.inputType = EditorInfo.TYPE_CLASS_TEXT or
            EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
            EditorInfo.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        info.imeOptions = EditorInfo.IME_ACTION_NONE or
            EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                typed(text?.toString() ?: return false)
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                typed(text?.toString() ?: return false)
                return true
            }

            override fun deleteSurroundingText(before: Int, after: Int): Boolean {
                repeat(before.coerceAtLeast(0)) { tap(ScreenKey.DELETE) }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent?): Boolean {
                if (event == null || event.action != KeyEvent.ACTION_DOWN) return true
                return handleKey(event)
            }

            override fun performEditorAction(action: Int): Boolean {
                tap(ScreenKey.RETURN)
                return true
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        if (handleKey(event)) true else super.onKeyDown(keyCode, event)

    private fun typed(text: String, held: Long = modifiers) {
        if (!inputEnabled || text.isEmpty()) return
        if (text == "\n") {
            tap(ScreenKey.RETURN)
            return
        }
        if (held and (ScreenFlag.COMMAND or ScreenFlag.CONTROL) != 0L && text.length == 1) {
            val code = ScreenKey.code(text[0])
            if (code != null) {
                tap(code)
                return
            }
        }
        actions?.text(text, held)
        spendModifiers()
    }

    private fun handleKey(event: KeyEvent): Boolean {
        if (!inputEnabled) return false
        val flags = modifiers or metaFlags(event.metaState)
        val code = screenShortcutCode(event.keyCode, flags) ?: keyCode(event.keyCode)
        if (code != null) {
            tap(code, flags)
            return true
        }
        val character = event.unicodeChar
        if (character != 0 && Character.isValidCodePoint(character)) {
            typed(String(Character.toChars(character)), flags)
            return true
        }
        return false
    }

    /// The IME connection can outlive control being handed back.
    fun tap(code: Int, flags: Long = modifiers) {
        if (!inputEnabled) return
        val handlers = actions ?: return
        handlers.key(code, true, flags)
        handlers.key(code, false, flags)
        spendModifiers()
    }

    private companion object {
        const val TWO_FINGER_TAP_MS = 300L

        fun keyCode(androidCode: Int): Int? = when (androidCode) {
            KeyEvent.KEYCODE_ESCAPE -> ScreenKey.ESCAPE
            KeyEvent.KEYCODE_TAB -> ScreenKey.TAB
            KeyEvent.KEYCODE_DEL -> ScreenKey.DELETE
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> ScreenKey.RETURN
            KeyEvent.KEYCODE_DPAD_LEFT -> ScreenKey.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> ScreenKey.RIGHT
            KeyEvent.KEYCODE_DPAD_UP -> ScreenKey.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> ScreenKey.DOWN
            else -> null
        }

        fun metaFlags(meta: Int): Long {
            var value = 0L
            if (meta and KeyEvent.META_SHIFT_ON != 0) value = value or ScreenFlag.SHIFT
            if (meta and KeyEvent.META_CTRL_ON != 0) value = value or ScreenFlag.CONTROL
            if (meta and KeyEvent.META_ALT_ON != 0) value = value or ScreenFlag.OPTION
            if (meta and KeyEvent.META_META_ON != 0) value = value or ScreenFlag.COMMAND
            return value
        }
    }
}

internal fun screenShortcutCode(androidCode: Int, flags: Long): Int? {
    if (flags and (ScreenFlag.COMMAND or ScreenFlag.CONTROL) == 0L) return null
    val character = when (androidCode) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> 'a' + (androidCode - KeyEvent.KEYCODE_A)
        else -> return null
    }
    return ScreenKey.code(character)
}
