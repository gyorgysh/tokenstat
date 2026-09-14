// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.util.Base64
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// Legend screen viewer: H.264 pictures decoded on this device through
/// MediaCodec, touch driving the remote pointer, heartbeat keeping a quiet
/// watcher from looking idle to the relay.
///
/// Mirrors Apple `ScreenViewerModel`: capability in, `screen.viewer.open`
/// with view-only control, a read loop that tells "connected" from
/// "streaming", reconnects bounded at three with the old session closed
/// first (the relay allows one screen channel per account), and input as
/// ordered JSON batches through `screen.viewer.input`. Control flips in
/// place through `screen.control.set` and only reopens when the host is too
/// old to know that method.
@OptIn(ExperimentalMaterial3Api::class)
@SuppressLint("ClickableViewAccessibility")
@Composable
fun ScreenViewerScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    onClose: () -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val decoder = remember { ScreenDecoder() }
    val holder = remember { ViewerHolder() }
    val input = remember { Channel<String>(capacity = 64) }

    var status by remember { mutableStateOf("Connecting…") }
    var failed by remember { mutableStateOf(false) }
    var control by remember { mutableStateOf(false) }
    var aspect by remember { mutableFloatStateOf(16f / 9f) }
    var view by remember { mutableStateOf<SurfaceView?>(null) }
    holder.aspect = aspect

    DisposableEffect(Unit) {
        val window = (context as? Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        ScreenViewing.show(context, hostLabel)
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            ScreenViewing.hide(context)
            holder.closed = true
            input.close()
            decoder.release()
            val id = holder.viewerId
            if (id != null) {
                scope.launch {
                    runCatching { model.core("screen.viewer.close", buildJsonObject { put("id", id) }) }
                }
            }
        }
    }

    suspend fun sendInput(json: String) {
        val id = holder.viewerId ?: return
        val data = Base64.encodeToString(json.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        runCatching {
            model.core("screen.viewer.input", buildJsonObject { put("id", id); put("data", data) })
        }
    }

    // Every input event in the order it was made. Independent sends would
    // let a move overtake the release that should have ended its drag.
    LaunchedEffect(Unit) {
        for (json in input) {
            if (holder.closed) break
            if (holder.viewerId == null) continue
            sendInput(json)
        }
    }

    // The "still here" beat, ungated by control mode: a passive watcher is
    // the exact case the relay would otherwise cut off mid-session.
    LaunchedEffect(Unit) {
        while (!holder.closed) {
            delay(30_000)
            if (!holder.closed && holder.viewerId != null) {
                sendInput(ScreenFrames.heartbeat())
            }
        }
    }

    suspend fun issueCapability(control: Boolean): String {
        val identity = model.core("machine.identity") as JsonObject
        val peerId = identity["publicIdentity"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("This device has no identity yet.")
        val cap = model.workspaceSection(
            peer,
            "screen.capability.issue",
            buildJsonObject {
                put("peerId", peerId)
                put("control", control)
                put("tier", "legend")
            },
        ) as JsonObject
        return cap["token"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("The host did not issue a capability.")
    }

    suspend fun open(wantControl: Boolean): Boolean {
        val token = issueCapability(wantControl)
        val opened = model.core(
            "screen.viewer.open",
            buildJsonObject {
                put("peer", peer)
                put("capability", token)
                put("control", wantControl)
            },
        ) as JsonObject
        val id = opened["id"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("The viewer opened without an id.")
        holder.viewerId = id
        holder.hostSessionId = opened["sessionId"]?.jsonPrimitive?.contentOrNull
        holder.transport = opened["transport"]?.jsonPrimitive?.contentOrNull
        holder.control = opened["control"]?.jsonPrimitive?.content == "true"
        control = holder.control
        decoder.reset()
        return true
    }

    suspend fun closeViewer() {
        val id = holder.viewerId ?: return
        holder.viewerId = null
        // `screen.viewer.close` is local work that drops the registry entry,
        // so a fresh dial never overtakes the old channel's close.
        withContext(NonCancellable) {
            runCatching { model.core("screen.viewer.close", buildJsonObject { put("id", id) }) }
        }
    }

    suspend fun readLoop(): String? {
        val id = holder.viewerId ?: return "The viewer never opened."
        val connectedSince = System.currentTimeMillis()
        var streaming = false
        while (!holder.closed) {
            val chunk = try {
                model.core("screen.viewer.read", buildJsonObject { put("id", id); put("waitMs", 250) })
            } catch (e: Exception) {
                return e.message ?: "The screen session broke."
            } as JsonObject
            val err = chunk["error"]?.jsonPrimitive?.contentOrNull
            if (!err.isNullOrBlank()) return err
            chunk["frame"]?.jsonPrimitive?.contentOrNull?.let { encoded ->
                runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull()?.let { bytes ->
                    ScreenFrames.parse(bytes)?.let { frame ->
                        val ratio = frame.width.toFloat() / frame.height.coerceAtLeast(1).toFloat()
                        if (ratio.isFinite()) {
                            aspect = ratio
                            holder.aspect = ratio
                        }
                        if (decoder.decode(frame) && !streaming) {
                            // Connected is not the same as a picture. The
                            // overlay lifts on the first decoded frame, the
                            // way the Apple viewer moves to streaming.
                            streaming = true
                            status = ScreenFrames.transportLabel(holder.transport)
                        }
                    } ?: renderJpegStill(decoder, bytes)
                }
            }
            if (!streaming && System.currentTimeMillis() - connectedSince > 8_000) {
                closeViewer()
                return "Connected, but no picture has arrived yet. " +
                    "The host may not have Screen Recording, or tokenstat may not be open on that computer."
            }
            if (chunk["active"]?.jsonPrimitive?.content == "false") {
                return chunk["error"]?.jsonPrimitive?.contentOrNull ?: "The screen session ended."
            }
        }
        return null
    }

    suspend fun connect(control: Boolean, attempts: Int = 0): Boolean {
        status = if (attempts == 0) "Connecting…" else "Reconnecting, attempt $attempts of 3."
        failed = false
        try {
            open(control)
        } catch (e: Exception) {
            val reason = e.message ?: "The screen session failed."
            return if (isActionable(reason)) {
                status = reason
                failed = true
                false
            } else if (attempts < 3) {
                delay(attempts.coerceAtLeast(1) * 1_000L)
                connect(control, attempts + 1)
            } else {
                status = "Connection could not recover. $reason"
                failed = true
                false
            }
        }
        status = "Waiting for the first picture…"
        val end = readLoop()
        if (holder.closed) return false
        if (end == null) return true
        return if (isActionable(end)) {
            // A failed session leaves nothing running behind its overlay.
            closeViewer()
            status = end
            failed = true
            false
        } else if (attempts < 3) {
            closeViewer()
            delay(attempts.coerceAtLeast(1) * 1_000L)
            connect(control, attempts + 1)
        } else {
            status = "Connection could not recover. $end"
            failed = true
            false
        }
    }

    fun setControl(wanted: Boolean) {
        scope.launch {
            val live = holder.viewerId
            val hostSession = holder.hostSessionId
            // Flip in place when there is a live session the host can name.
            // A host too old to know the method keeps the picture it has,
            // which is a worse picture and not a broken one: reopen instead.
            if (live != null && !hostSession.isNullOrBlank()) {
                val flipped = runCatching {
                    val token = issueCapability(wanted)
                    CoreClient.remote(
                        peer,
                        "screen.control.set",
                        buildJsonObject {
                            put("sessionId", hostSession)
                            put("capability", token)
                            put("control", wanted)
                        },
                    )
                }.isSuccess
                if (flipped) {
                    holder.control = wanted
                    control = wanted
                    return@launch
                }
            }
            closeViewer()
            connect(wanted)
            control = holder.control
        }
    }

    LaunchedEffect(peer) {
        connect(false)
        control = holder.control
        status = when {
            failed -> status
            holder.viewerId != null -> ScreenFrames.transportLabel(holder.transport)
            else -> status
        }
    }

    Column(Modifier.fillMaxSize().background(colors.background)) {
        TopAppBar(
            title = { Text("$hostLabel · $status") },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
            actions = {
                TextButton(onClick = { setControl(!control) }) {
                    Text(if (control) "View only" else "Control")
                }
                TextButton(onClick = onClose) { Text("Done") }
            },
        )
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            AndroidView(
                modifier = Modifier.fillMaxSize().aspectRatio(aspect, matchHeightConstraintsFirst = true),
                factory = { ctx ->
                    SurfaceView(ctx).also { surface ->
                        view = surface
                        surface.holder.addCallback(object : SurfaceHolder.Callback {
                            override fun surfaceCreated(h: SurfaceHolder) {
                                decoder.surface = h.surface
                            }

                            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {
                                decoder.surface = h.surface
                            }

                            override fun surfaceDestroyed(h: SurfaceHolder) {
                                decoder.surface = null
                            }
                        })
                        surface.setOnTouchListener { touched, event ->
                            onTouch(holder, input, touched, event)
                            true
                        }
                    }
                },
                onRelease = { surface ->
                    surface.setOnTouchListener(null)
                    if (view == surface) view = null
                },
            )
            if (failed || holder.viewerId == null) {
                Text(status, color = colors.textSecondary, modifier = Modifier.padding(Space.l))
            }
        }
    }
}

/// Screen state that outlives recomposition but is not Compose state: the
/// loops read and write it from coroutines, the UI mirrors it.
private class ViewerHolder {
    @Volatile var viewerId: String? = null
    @Volatile var hostSessionId: String? = null
    @Volatile var transport: String? = null
    @Volatile var control: Boolean = false
    @Volatile var closed: Boolean = false
    @Volatile var aspect: Float = 16f / 9f

    // The active drag, so a move knows whether it starts one.
    @Volatile var pressing: Boolean = false
    @Volatile var downX: Float = 0f
    @Volatile var downY: Float = 0f
    @Volatile var lastTwoY: Float = 0f
}

/// A reason the checklist can act on, in which case the viewer stops and
/// says so rather than reconnecting forever. Mirrors Apple `actionable`.
private fun isActionable(reason: String): Boolean {
    val value = reason.lowercase()
    return value.contains("screen recording") || value.contains("accessibility") ||
        value.contains("permission") || value.contains("not been allowed") ||
        value.contains("does not have screen access") || value.contains("legend plan") ||
        value.contains("no display") || value.contains("videotoolbox")
}

/// A tap is a click where it landed, a drag holds the left button until the
/// finger lifts, and a two-finger slide scrolls. Coordinates are normalized
/// against the fitted picture, never the view, so letterbox bars cannot
/// throw the pointer off. View-only sessions ignore touches: input is a
/// side channel of a control session, not of the picture.
private fun onTouch(
    holder: ViewerHolder,
    input: Channel<String>,
    touched: android.view.View,
    event: MotionEvent,
): Boolean {
    if (!holder.control) return false
    val viewWidth = touched.width
    val viewHeight = touched.height
    if (viewWidth <= 0 || viewHeight <= 0) return false
    // The surface fits the picture by aspect, so the touch maps against the
    // fitted frame and letterbox bars cannot throw the pointer off.
    val (fitWidth, fitHeight) = fittedSize(viewWidth, viewHeight, holder.aspect)
    fun normalize(x: Float, y: Float): Pair<Double, Double> {
        val left = (viewWidth - fitWidth) / 2f
        val top = (viewHeight - fitHeight) / 2f
        val nx = ((x - left) / fitWidth.toFloat()).coerceIn(0f, 1f)
        val ny = ((y - top) / fitHeight.toFloat()).coerceIn(0f, 1f)
        return nx.toDouble() to ny.toDouble()
    }
    when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
            holder.downX = event.x
            holder.downY = event.y
            holder.pressing = false
        }
        MotionEvent.ACTION_POINTER_DOWN -> {
            if (event.pointerCount >= 2) holder.lastTwoY = event.getY(1)
        }
        MotionEvent.ACTION_MOVE -> {
            if (event.pointerCount >= 2) {
                val y = event.getY(1)
                val dy = (holder.lastTwoY - y) / fitHeight.toFloat()
                holder.lastTwoY = y
                val (x, yy) = normalize(event.x, event.y)
                if (dy != 0f) input.trySend(ScreenFrames.scroll(x, yy, 0.0, dy.toDouble()))
                return true
            }
            val (x, y) = normalize(event.x, event.y)
            val moved = kotlin.math.abs(event.x - holder.downX) +
                kotlin.math.abs(event.y - holder.downY)
            if (!holder.pressing && moved > TOUCH_SLOP_PX) {
                holder.pressing = true
                input.trySend(ScreenFrames.press(x, y, true))
            }
            if (holder.pressing) input.trySend(ScreenFrames.move(x, y))
        }
        MotionEvent.ACTION_UP -> {
            val (x, y) = normalize(event.x, event.y)
            if (holder.pressing) {
                holder.pressing = false
                input.trySend(ScreenFrames.press(x, y, false))
            } else {
                input.trySend(ScreenFrames.move(x, y))
                input.trySend(ScreenFrames.click(x, y, 0, 1))
            }
        }
        MotionEvent.ACTION_CANCEL -> {
            if (holder.pressing) {
                holder.pressing = false
                val (x, y) = normalize(event.x, event.y)
                input.trySend(ScreenFrames.press(x, y, false))
            }
        }
    }
    return true
}

private const val TOUCH_SLOP_PX = 12f

private fun fittedSize(viewWidth: Int, viewHeight: Int, aspect: Float): Pair<Int, Int> {
    if (viewWidth <= 0 || viewHeight <= 0 || !aspect.isFinite() || aspect <= 0f) {
        return viewWidth to viewHeight
    }
    val byWidth = (viewWidth / aspect).toInt()
    return if (byWidth <= viewHeight) viewWidth to byWidth else (viewHeight * aspect).toInt() to viewHeight
}

/// A JPEG still from an old host, drawn where the video goes. The current
/// host only sends TSCR-wrapped H.264, so this is a fallback, not a path.
private fun renderJpegStill(decoder: ScreenDecoder, bytes: ByteArray) {
    if (bytes.size < 2 || bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) return
    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
    val surface = decoder.surface ?: return
    if (!surface.isValid) return
    runCatching {
        val canvas = surface.lockCanvas(null) ?: return
        try {
            canvas.drawBitmap(bitmap, null, Rect(0, 0, canvas.width, canvas.height), null)
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
    }
}
