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

/// What a finger on the picture can do. A value rather than a pile of
/// callbacks on the view, so the composable keeps the state and the view
/// keeps the gestures. Port of Apple `ScreenInputActions`.
class ScreenInputActions(
    /// Put the pointer at this normalized point.
    val move: (Float, Float) -> Unit,
    /// Move the pointer by a distance measured on this surface. Trackpad
    /// mode: the finger is not where the pointer is.
    val nudge: (Float, Float, Float, Float) -> Unit,
    /// Press and release, with a button and a click count in one message.
    val click: (Int, Int) -> Unit,
    /// Hold or release the left button, for a drag that outlives one gesture.
    val press: (Boolean) -> Unit,
    /// Wheel movement in density-independent pixels.
    val scroll: (Float, Float) -> Unit,
    /// Move a locally zoomed picture without sending anything to the host.
    val panView: (Float, Float, Float, Float) -> Unit,
    /// Typed characters, with modifier flags already folded in.
    val text: (String, Long) -> Unit,
    /// A key that has no character: escape, tab, the arrows.
    val key: (Int, Boolean, Long) -> Unit,
    /// Pinch. The surface reports the factor, the composable decides.
    val magnify: (Float, Float, Float) -> Unit,
    /// A modifier was spent by a keystroke, so the key row can unlight it.
    val modifiersSpent: () -> Unit,
    /// A tap while merely watching, which means nothing on the far end and is
    /// how the chrome comes back over a full-screen picture.
    val tapWhileWatching: () -> Unit,
)

/// Mouse and keyboard over the shared screen.
///
/// A plain `View` rather than Compose pointer input because a remote desktop
/// needs what Compose does not offer in one place: a two-finger tap that is a
/// right click, a long press that holds the button down across a later drag,
/// a pinch that zooms the picture rather than the layout, and an input
/// connection so the soft keyboard has somewhere to type.
@SuppressLint("ViewConstructor")
class ScreenTouchView(context: Context) : View(context) {
    var actions: ScreenInputActions? = null
    /// Whether touches reach the far end. Not called `enabled`: that name
    /// belongs to the platform's own view flag, and taking it would turn the
    /// view off rather than hand control back.
    var inputEnabled: Boolean = false
    var mode: ScreenPointerMode = ScreenPointerMode.Trackpad
    var zoomed: Boolean = false

    /// Modifiers the key row is holding, folded into whatever is typed next.
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

        /// Long press, then move: the button stays down until the finger
        /// leaves. This is how a window gets dragged or a file gets selected.
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
                actions?.magnify(detector.scaleFactor, width.toFloat(), height.toFloat())
                return true
            }
        },
    )

    init {
        isFocusableInTouchMode = true
        isClickable = true
        // Pinch is local viewing, not remote control, so the surface stays in
        // the gesture chain in view mode and every input-sending path checks
        // `inputEnabled` itself.
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
                lastFocusX = focusX(event)
                lastFocusY = focusY(event)
                panning = false
            }
            MotionEvent.ACTION_MOVE -> if (twoFingers) twoFingerMove(event) else oneFingerMove(event)
            MotionEvent.ACTION_POINTER_UP -> if (twoFingers && event.pointerCount == 2) {
                // A two-finger tap is a right click, the way it is on a
                // trackpad. Anything that travelled or lingered was a scroll
                // or a pinch and has already done its job.
                val quick = event.eventTime - twoFingerDownAt < TWO_FINGER_TAP_MS
                if (inputEnabled && quick && twoFingerTravel < slop) {
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
        // A pinch is a zoom of the picture on this device, not a scroll of
        // the document on the far end. The focus still tracks above, so tap
        // detection keeps working through it.
        if (pinches.isInProgress) return
        if (!inputEnabled) return
        // Density-independent, so a finger's travel means the same distance
        // of scrolled content here as it does on a phone with a denser
        // display, and the same as it does on the Apple client.
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
            // Merely watching a magnified picture. The finger moves what is
            // on this device and nothing on the far end.
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

    // The keyboard.

    override fun onCheckIsTextEditor(): Boolean = inputEnabled

    override fun onCreateInputConnection(info: EditorInfo): InputConnection {
        info.inputType = EditorInfo.TYPE_CLASS_TEXT or
            EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
            EditorInfo.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        info.imeOptions = EditorInfo.IME_ACTION_NONE or
            EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        // No editor behind this, so nothing is composed and nothing is
        // predicted. Every keystroke goes straight down the wire.
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

    private fun typed(text: String) {
        if (!inputEnabled || text.isEmpty()) return
        if (text == "\n") {
            tap(ScreenKey.RETURN)
            return
        }
        // A character typed with command or control has to reach the host as a
        // key code, because the host synthesises a key event and not text.
        val held = modifiers
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
        val code = keyCode(event.keyCode)
        if (code != null) {
            tap(code, flags)
            return true
        }
        val character = event.unicodeChar.toChar()
        if (character.code != 0) {
            typed(character.toString())
            return true
        }
        return false
    }

    /// One key, down then up, spending whatever the key row was holding.
    /// Gated like every other input-sending path: the IME connection can
    /// outlive control being handed back.
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
