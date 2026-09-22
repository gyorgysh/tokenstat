// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.core.CoreClient
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/// One screen session, port of Apple `ScreenViewerModel`.
///
/// Owns everything the picture needs and nothing the picture looks like: the
/// capability, the viewer registration, the read loop that tells "connected"
/// from "streaming", the bounded reconnect, the ordered input channel, the
/// heartbeat, and the side channels (displays, quality, clipboard, audio,
/// file transfer). The composable reads its state and draws it.
class ScreenViewerModel(
    private val app: AppViewModel,
    private val scope: CoroutineScope,
    /// The clipboard on this device, when there is one to keep in step.
    private val clipboard: ScreenClipboard? = null,
    /// Where a session's viewer close runs. The composition scope is being
    /// cancelled when `release` runs from `onDispose`, which would drop the
    /// close and leak the viewer relay-side until timeout, so this outlives
    /// the screen. The call site passes the view model's own scope.
    private val closeScope: CoroutineScope = scope,
) {
    enum class State { Idle, Connecting, Streaming, Failed }

    var state by mutableStateOf(State.Idle)
        private set
    var message by mutableStateOf("Connecting…")
        private set
    var aspectRatio by mutableFloatStateOf(16f / 9f)
        private set
    var displays by mutableStateOf<List<ScreenFrames.Display>>(emptyList())
        private set
    var selectedDisplay by mutableStateOf<Long?>(null)
        private set
    var transport by mutableStateOf<String?>(null)
        private set
    var transferProgress by mutableStateOf<Float?>(null)
        private set
    var requestNotice by mutableStateOf<String?>(null)
        private set
    var isRequesting by mutableStateOf(false)
        private set
    var quality by mutableStateOf(ScreenQuality.Auto)
        private set

    /// Where the pointer is, normalized. This device owns it because trackpad
    /// mode has no other way to know, and because a phone has to draw it.
    var cursorX by mutableFloatStateOf(0.5f)
        private set
    var cursorY by mutableFloatStateOf(0.5f)
        private set

    val decoder = ScreenDecoder()
    val audio = ScreenAudio()

    /// Whether the live session is actually carrying input.
    var isControlling by mutableStateOf(false)
        private set

    /// One input event waiting for the pump. Moves coalesce: a finger emits
    /// them at touch rate while the pump sends at network round trips, so
    /// only the latest position matters. Scrolls merge the same way by
    /// distance. Clicks, presses and keys always keep their place, because a
    /// release dropped from a full queue would stick a button on the host.
    private sealed interface PendingInput {
        data class Control(val json: String) : PendingInput
        data class Move(val json: String) : PendingInput
        data class Scroll(val x: Double, val y: Double, val dx: Double, val dy: Double) : PendingInput
    }

    private var peer = ""
    private var tier: String? = null
    private var viewerId: String? = null
    private var hostSessionId: String? = null
    private var sessionJob: Job? = null
    private var heartbeatJob: Job? = null
    private var inputJob: Job? = null
    private var transferJob: Job? = null
    private val inputLock = Any()
    private val inputQueue = ArrayDeque<PendingInput>()
    private val inputSignal = Channel<Unit>(capacity = Channel.CONFLATED)
    /// Decode runs off the main thread, while resets arrive on it from the
    /// screen. One lock, so a display switch cannot tear the codec down
    /// under a frame being fed to it.
    private val mediaLock = Any()
    private var stopped = false
    private var generation = 0
    private var attempts = 0
    private var connectedSince = 0L
    private var streamingSince = 0L
    private var lastAutoRequest = 0L
    private var clipboardStamp = -1L
    private var clipboardWritten: String? = null

    /// The permission is missing, so the checklist offers to ask for it.
    val needsPermission: Boolean
        get() = message.lowercase().let {
            it.contains("permission") || it.contains("screen access") || it.contains("allowed")
        }

    /// The session never started because the plan does not include it.
    val needsLegend: Boolean
        get() = message.contains("legend plan", ignoreCase = true)

    fun start(peer: String, hostLabel: String, tier: String?, control: Boolean) {
        stop()
        stopped = false
        // The cancelled session is still unwinding past its own
        // non-cancellable closes. It carries the old number and stands down
        // wherever it checks it, instead of redialling into this session's
        // state.
        generation += 1
        val current = generation
        this.peer = peer
        this.label = hostLabel
        this.tier = tier
        isControlling = control
        requestNotice = null
        attempts = 0
        state = State.Connecting
        message = "Connecting…"
        startInputPump()
        startHeartbeat()
        sessionJob = scope.launch { runSession(current) }
    }

    private var label = ""

    /// Everything this session holds, put down. Safe to call twice.
    fun stop() {
        stopped = true
        heartbeatJob?.cancel()
        heartbeatJob = null
        inputJob?.cancel()
        inputJob = null
        transferJob?.cancel()
        transferJob = null
        sessionJob?.cancel()
        sessionJob = null
        // A new session starts with no input from the old one.
        synchronized(inputLock) { inputQueue.clear() }
        val id = viewerId
        viewerId = null
        hostSessionId = null
        if (id != null) {
            // Not discarded. The relay allows one screen channel per account,
            // so a fresh dial that overtakes the old channel's close is
            // refused, and the retry ladder that follows is a reconnect storm.
            closeScope.launch {
                withContext(NonCancellable) {
                    runCatching { app.core("screen.viewer.close", buildJsonObject { put("id", id) }) }
                }
            }
        }
        synchronized(mediaLock) {
            decoder.reset()
            audio.reset()
        }
        transferProgress = null
    }

    fun release() {
        stop()
        synchronized(mediaLock) { decoder.release() }
    }

    // The session.

    private suspend fun runSession(current: Int) {
        while (current == generation && !stopped) {
            val failure = openSession()
            if (current != generation || stopped) return
            if (failure != null) {
                if (!retry(current, failure, autoRequest = true)) return
                continue
            }
            val ended = readLoop(current) ?: return
            if (current != generation || stopped) return
            closeSession()
            if (current != generation || stopped) return
            if (!retry(current, ended, autoRequest = false)) return
        }
    }

    /// Whether the loop should dial again. Says why either way.
    private suspend fun retry(current: Int, reason: String, autoRequest: Boolean): Boolean {
        if (current != generation || stopped) return false
        if (actionable(reason)) {
            closeSession()
            state = State.Failed
            message = reason
            // Ask as soon as the connect fails, rather than waiting for
            // somebody to find the button under the overlay. Rate limited, or
            // every failed retry re-asks and spams the host.
            if (autoRequest && needsPermission &&
                System.currentTimeMillis() - lastAutoRequest > 60_000
            ) {
                lastAutoRequest = System.currentTimeMillis()
                requestAccessNow()
            }
            return false
        }
        attempts += 1
        if (attempts > 3) {
            state = State.Failed
            message = "Connection could not recover. $reason"
            return false
        }
        state = State.Connecting
        // Say why. Keeping the reason back until the third failure made the
        // whole visible story of a session that could not stay up
        // "Reconnecting…", which names nothing anybody can act on.
        message = "Reconnecting, attempt $attempts of 3. $reason"
        delay(attempts * 1_000L)
        return current == generation && !stopped
    }

    /// Null when the session opened. Otherwise the reason it did not.
    private suspend fun openSession(): String? {
        if (!tier.equals("legend", ignoreCase = true)) {
            return "Screen access requires the Legend plan."
        }
        return try {
            // Pair and serve before dialling, the way a workspace connect
            // does: a fresh process holds no tunnel session, and the
            // capability issue below would fail with "tunnel session is not
            // running" instead of opening.
            app.prepareHost(peer, label)
            val token = issueCapability(isControlling)
            val opened = app.core(
                "screen.viewer.open",
                buildJsonObject {
                    put("peer", peer)
                    put("capability", token)
                    put("control", isControlling)
                    quality.wire?.let { put("quality", it) }
                },
            ) as JsonObject
            viewerId = opened["id"]?.jsonPrimitive?.contentOrNull
                ?: return "The viewer opened without an id."
            hostSessionId = opened["sessionId"]?.jsonPrimitive?.contentOrNull
            transport = opened["transport"]?.jsonPrimitive?.contentOrNull
            connectedSince = System.currentTimeMillis()
            streamingSince = 0
            synchronized(mediaLock) { decoder.reset() }
            // Connected is not the same as a picture. Marking this streaming
            // would lift the overlay off a black rectangle that still accepts
            // mouse and keyboard, because input is a side channel.
            state = State.Connecting
            message = "Waiting for the first picture…"
            null
        } catch (e: Exception) {
            e.message ?: "The screen session failed."
        }
    }

    private suspend fun issueCapability(control: Boolean): String {
        val identity = app.core("machine.identity") as JsonObject
        // `machine.identity` answers `key`, the 64-hex machine public key,
        // never `publicIdentity`: that lookup missed on every device and the
        // viewer failed before dialling. The Apple viewer reads the same key.
        val peerId = identity["key"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("This device has no identity yet.")
        val cap = app.workspaceSection(
            peer,
            "screen.capability.issue",
            buildJsonObject {
                put("peerId", peerId)
                put("control", control)
                put("tier", tier ?: "")
            },
        ) as JsonObject
        return cap["token"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException("The host did not issue a capability.")
    }

    private suspend fun closeSession() {
        val id = viewerId ?: return
        // `screen.viewer.close` is local work that drops the registry entry,
        // so a fresh dial never overtakes the old channel's close.
        withContext(NonCancellable) {
            runCatching { app.core("screen.viewer.close", buildJsonObject { put("id", id) }) }
        }
        // Only this session's own id. A restart may have opened the next
        // session while this close was in flight, and that id is not ours
        // to clear.
        if (viewerId == id) {
            viewerId = null
            hostSessionId = null
        }
    }

    /// Null when this device ended the session. Otherwise why it ended.
    private suspend fun readLoop(current: Int): String? {
        val id = viewerId ?: return "The viewer never opened."
        while (current == generation && !stopped) {
            val chunk = try {
                app.core(
                    "screen.viewer.read",
                    buildJsonObject { put("id", id); put("waitMs", 250) },
                ) as JsonObject
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return e.message ?: "The screen session broke."
            }
            chunk["metadata"]?.jsonPrimitive?.contentOrNull?.let { applyMetadata(it) }
            chunk["frame"]?.jsonPrimitive?.contentOrNull?.let { applyFrame(it) }
            chunk["audio"]?.jsonPrimitive?.contentOrNull?.let { encoded ->
                val bytes = decode(encoded) ?: return@let
                withContext(Dispatchers.Default) {
                    synchronized(mediaLock) { ScreenFrames.audio(bytes)?.let(audio::play) }
                }
            }
            if (state != State.Streaming && connectedSince > 0 &&
                System.currentTimeMillis() - connectedSince > 8_000
            ) {
                if (current != generation || stopped) return null
                // The transport is alive but unusable. Do not leave its viewer
                // and the host's capture running behind a failed overlay while
                // waiting for somebody to press Try again.
                closeSession()
                connectedSince = 0
                state = State.Failed
                message = "Connected, but no picture has arrived yet. " +
                    "That computer may not have Screen Recording, or tokenstat may not be open on that computer."
                return null
            }
            if (chunk["active"]?.jsonPrimitive?.contentOrNull == "false") {
                return chunk["error"]?.jsonPrimitive?.contentOrNull ?: "The screen session ended."
            }
            val error = chunk["error"]?.jsonPrimitive?.contentOrNull
            if (!error.isNullOrBlank()) return error
            if (isControlling) syncClipboard()
        }
        return null
    }

    private fun applyMetadata(encoded: String) {
        val bytes = decode(encoded) ?: return
        val metadata = ScreenFrames.metadata(bytes) ?: return
        when (metadata.type) {
            "displays" -> {
                displays = metadata.displays
                selectedDisplay = metadata.selected
            }
            "clipboard" -> if (isControlling) {
                metadata.text?.let {
                    clipboard?.write(it)
                    clipboardStamp = clipboard?.stamp() ?: -1L
                    // The stamp can land after the write, so the text is
                    // remembered too. Without it the host's own copy comes
                    // straight back at it, and the two ends bounce one string
                    // between them for as long as the session lasts.
                    clipboardWritten = it
                }
            }
        }
    }

    private suspend fun applyFrame(encoded: String) {
        val bytes = decode(encoded) ?: return
        // Parsing and MediaCodec both work on the calling thread, up to tens
        // of milliseconds a frame. Off the main thread, so the picture never
        // stalls the chrome drawn over it.
        val frame = withContext(Dispatchers.Default) { ScreenFrames.parse(bytes) } ?: return
        val ratio = frame.width.toFloat() / frame.height.coerceAtLeast(1).toFloat()
        if (ratio.isFinite() && ratio > 0f) aspectRatio = ratio
        val rendered = withContext(Dispatchers.Default) {
            synchronized(mediaLock) { decoder.decode(frame) }
        }
        if (!rendered) return
        if (streamingSince == 0L) {
            // Stability starts with a picture, not with the transport. A slow
            // first keyframe must not spend almost all of the window by
            // itself.
            streamingSince = System.currentTimeMillis()
        } else if (System.currentTimeMillis() - streamingSince > STABLE_AFTER_MS) {
            // A session that died a second after its first frame used to reset
            // the budget every time and reconnect forever. A session has to
            // last before it counts as recovered.
            attempts = 0
        }
        if (state != State.Streaming) {
            state = State.Streaming
            message = ScreenFrames.transportLabel(transport)
        }
    }

    private fun decode(encoded: String): ByteArray? =
        runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull()

    /// A reason the checklist can act on, in which case the viewer stops and
    /// says so rather than reconnecting forever. Mirrors Apple `actionable`.
    private fun actionable(reason: String): Boolean {
        val value = reason.lowercase()
        return value.contains("screen recording") || value.contains("accessibility") ||
            value.contains("permission") || value.contains("not been allowed") ||
            value.contains("does not have screen access") || value.contains("legend plan") ||
            value.contains("no display") || value.contains("videotoolbox")
    }

    // Input.

    /// Every input event, in the order it was made. Independent sends would
    /// let a move overtake the release that should have ended its drag.
    private fun startInputPump() {
        inputJob = scope.launch {
            for (ignored in inputSignal) {
                while (true) {
                    if (stopped) break
                    val next: PendingInput = synchronized(inputLock) {
                        if (inputQueue.isEmpty()) null else inputQueue.removeFirst()
                    } ?: break
                    // A reconnect drops what it was carrying: the new session
                    // starts from this device's own pointer, not from a move
                    // meant for the dead one.
                    val id = viewerId ?: continue
                    val json = when (next) {
                        is PendingInput.Control -> next.json
                        is PendingInput.Move -> next.json
                        is PendingInput.Scroll -> ScreenFrames.scroll(next.x, next.y, next.dx, next.dy)
                    }
                    val data = Base64.encodeToString(json.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
                    runCatching {
                        app.core(
                            "screen.viewer.input",
                            buildJsonObject { put("id", id); put("data", data) },
                        )
                    }
                }
            }
        }
    }

    /// Say "still here" on a beat, so the relay can tell a session somebody is
    /// watching from one nobody is.
    ///
    /// The relay cannot see inside an encrypted stream and must not try. What
    /// it can see is which direction bytes are moving, and on a screen channel
    /// everything flows one way. Deliberately not tied to control mode: a
    /// passive watcher is the exact case that would otherwise be cut off.
    private fun startHeartbeat() {
        heartbeatJob = scope.launch {
            while (isActive && !stopped) {
                delay(30_000)
                if (!stopped && viewerId != null) send(ScreenFrames.heartbeat())
            }
        }
    }

    /// A control event, which always keeps its place in the queue.
    private fun send(json: String) {
        if (stopped || viewerId == null) return
        synchronized(inputLock) { inputQueue.addLast(PendingInput.Control(json)) }
        inputSignal.trySend(Unit)
    }

    /// A move, which supersedes a move still waiting behind nothing else.
    /// Every message carries absolute coordinates, so an overtaken move
    /// changes nothing about what the host ends up holding.
    private fun sendMove(json: String) {
        if (stopped || viewerId == null) return
        synchronized(inputLock) {
            if (inputQueue.lastOrNull() is PendingInput.Move) {
                inputQueue[inputQueue.lastIndex] = PendingInput.Move(json)
            } else {
                inputQueue.addLast(PendingInput.Move(json))
            }
        }
        inputSignal.trySend(Unit)
    }

    /// A scroll, merged into a scroll still waiting: the latest point, the
    /// whole travel. Wheel distance adds up, so merging drops no movement.
    private fun sendScroll(x: Double, y: Double, dx: Double, dy: Double) {
        if (stopped || viewerId == null) return
        synchronized(inputLock) {
            val last = inputQueue.lastOrNull()
            if (last is PendingInput.Scroll) {
                inputQueue[inputQueue.lastIndex] =
                    PendingInput.Scroll(x, y, last.dx + dx, last.dy + dy)
            } else {
                inputQueue.addLast(PendingInput.Scroll(x, y, dx, dy))
            }
        }
        inputSignal.trySend(Unit)
    }

    /// Put the pointer at a normalized point on the remote display.
    fun move(x: Float, y: Float) {
        cursorX = x.coerceIn(0f, 1f)
        cursorY = y.coerceIn(0f, 1f)
        if (!isControlling) return
        sendMove(ScreenFrames.move(cursorX.toDouble(), cursorY.toDouble()))
    }

    /// Move the pointer by a finger's worth of travel on this surface.
    ///
    /// Trackpad mode: the finger is not the pointer, so this device keeps the
    /// pointer position itself and sends an absolute point. The host stays a
    /// single "put it here", which is the only thing that survives two
    /// displays of different sizes.
    fun nudge(dx: Float, dy: Float, width: Float, height: Float, sensitivity: Float) {
        move(
            cursorX + dx * sensitivity / width.coerceAtLeast(1f),
            cursorY + dy * sensitivity / height.coerceAtLeast(1f),
        )
    }

    /// Press and release in one message, with the count macOS needs to read a
    /// double click as a double click.
    fun click(button: Int, count: Int, flags: Long = 0) {
        if (!isControlling) return
        send(ScreenFrames.click(cursorX.toDouble(), cursorY.toDouble(), button, count, flags))
    }

    /// Hold or release the left button, for a drag that outlives one gesture.
    fun press(down: Boolean) {
        if (!isControlling) return
        send(ScreenFrames.press(cursorX.toDouble(), cursorY.toDouble(), down))
    }

    fun scroll(dx: Float, dy: Float) {
        if (!isControlling) return
        sendScroll(cursorX.toDouble(), cursorY.toDouble(), dx.toDouble(), dy.toDouble())
    }

    fun sendKey(code: Int, down: Boolean, flags: Long) {
        if (!isControlling) return
        send(ScreenFrames.key(code, down, flags))
    }

    fun sendText(text: String, flags: Long) {
        if (!isControlling) return
        send(ScreenFrames.text(text, flags))
    }

    /// Which screen this device is watching is the viewer's own choice, so a
    /// view-only session may still make it. The host reads the display event
    /// without asking whether the session carries input.
    fun selectDisplay(id: Long) {
        if (displays.none { it.id == id }) return
        selectedDisplay = id
        synchronized(mediaLock) { decoder.reset() }
        if (stopped || viewerId == null) return
        send(ScreenFrames.display(id))
    }

    private fun syncClipboard() {
        val board = clipboard ?: return
        val stamp = board.stamp()
        if (stamp < 0 || stamp == clipboardStamp) return
        clipboardStamp = stamp
        val text = board.read() ?: return
        if (text == clipboardWritten) return
        if (text.toByteArray(Charsets.UTF_8).size > 4_096) return
        send(ScreenFrames.clipboard(text))
    }

    // Settings on a live session.

    /// Turn control on or off, without stopping the picture where the host
    /// knows how.
    ///
    /// Control is decided when the capability is issued, so an old host has to
    /// reopen the stream. The relay allows one screen channel per account, so
    /// reopening races its own teardown, which is why the flip is preferred.
    fun setControl(wanted: Boolean) {
        if (wanted == isControlling) return
        scope.launch {
            val hostSession = hostSessionId
            if (viewerId != null && !hostSession.isNullOrBlank()) {
                val flipped = runCatching {
                    // A fresh capability every time. The one this session
                    // opened with says what it was opened for, and control is
                    // exactly the field the host checks.
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
                    isControlling = wanted
                    return@launch
                }
            }
            // An old host has no such method. Reopening will meet any real
            // refusal again and report it where somebody can read it.
            val keepTier = tier
            val keepPeer = peer
            val keepLabel = label
            stop()
            start(keepPeer, keepLabel, keepTier, wanted)
            message = if (wanted) "Asking for control…" else "Switching to view only…"
        }
    }

    /// Move a live session to a different budget. Never by reopening, for the
    /// same reason control is flipped in place. A host too old to know the
    /// method keeps the picture it has, which is a worse picture and not a
    /// broken one.
    fun chooseQuality(wanted: ScreenQuality) {
        if (wanted == quality) return
        quality = wanted
        val hostSession = hostSessionId
        if (viewerId == null || hostSession.isNullOrBlank()) return
        scope.launch {
            // Not worth a failed state. The session is still running and still
            // showing a picture, just not the one that was asked for.
            runCatching {
                val token = issueCapability(isControlling)
                CoreClient.remote(
                    peer,
                    "screen.quality.set",
                    buildJsonObject {
                        put("sessionId", hostSession)
                        put("capability", token)
                        // Automatic on a live session has to be said out loud:
                        // there is no way to unsay a choice the host holds.
                        put("quality", wanted.wire ?: "auto")
                    },
                )
            }
        }
    }

    // Access.

    /// Ask the computer itself, then nudge the owner's other devices.
    ///
    /// The ask is the part that matters and the part that can fail usefully:
    /// it travels the tunnel, so the host learns which device is asking and
    /// can queue it for a person. The push afterwards is best effort and
    /// carries no device id at all, which is why it was never enough on its
    /// own. A host that is asleep cannot be asked, and says so.
    fun requestAccess() {
        if (isRequesting) return
        scope.launch { requestAccessNow() }
    }

    private suspend fun requestAccessNow() {
        isRequesting = true
        try {
            val asked = runCatching { ask(isControlling) }
            val answer = asked.getOrElse {
                requestNotice = it.message ?: "That computer could not be asked."
                return
            }
            // Already allowed to watch, and still not running: what is missing
            // is the mouse. Asking for exactly what the Control toggle happened
            // to say left somebody granted View only pressing a button that
            // answered "this device already has access" forever.
            val allowed = if (answer && !isControlling) {
                runCatching { ask(true) }.getOrDefault(true)
            } else {
                answer
            }
            if (allowed) {
                requestNotice = "This device already has access. Press Try again."
                return
            }
            requestNotice = "Asked. Approve this device on that computer."
            // Best effort, and never the reason the request failed. Somebody
            // with no other device registered has still asked the computer.
            runCatching {
                val sent = app.core("screen.access.request") as JsonObject
                val devices = sent["sent"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0
                val enabled = sent["enabled"]?.jsonPrimitive?.contentOrNull == "true"
                val signedIn = sent["signedIn"]?.jsonPrimitive?.contentOrNull == "true"
                if (signedIn && enabled && devices > 0) {
                    requestNotice = "Asked. A notification went to your other devices."
                }
            }
        } finally {
            isRequesting = false
        }
    }

    private suspend fun ask(control: Boolean): Boolean {
        val answer = app.workspaceSection(
            peer,
            "screen.access.ask",
            buildJsonObject { put("control", control) },
        ) as JsonObject
        return answer["granted"]?.jsonPrimitive?.contentOrNull == "true"
    }

    // File transfer.

    fun sendFile(file: ScreenFileSource) {
        if (transferJob != null || peer.isEmpty()) return
        transferJob = scope.launch {
            try {
                transfer(file)
            } finally {
                transferJob = null
            }
        }
    }

    fun cancelTransfer() {
        transferJob?.cancel()
        transferJob = null
        transferProgress = null
    }

    private suspend fun transfer(file: ScreenFileSource) {
        var id = ""
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            file.open().use { stream ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                    size += read
                }
            }
            val hash = hex(digest.digest())
            // The same resume key the Apple client computes, so a transfer
            // begun on one device carries on from where it stopped on the
            // other.
            id = hex(
                MessageDigest.getInstance("SHA-256").digest(
                    listOf(file.name, size.toString(), hash)
                        .joinToString(NUL)
                        .toByteArray(Charsets.UTF_8)
                )
            )
            val opened = CoreClient.remote(
                peer,
                "screen.transfer.open",
                buildJsonObject {
                    put("id", id); put("name", file.name)
                    put("size", size); put("digest", hash)
                },
            ) as JsonObject
            var offset = opened["offset"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L
            val chunkBytes = (
                opened["chunkBytes"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
                    ?: (256 * 1024)
                ).coerceIn(1, 256 * 1024)
            transferProgress = if (size == 0L) 1f else offset.toFloat() / size.toFloat()
            file.open().use { stream ->
                // Read and discard, never `skip`: a stream may stop short,
                // and uploading from the wrong offset under the claimed one
                // corrupts the file on the host. A short stream means the
                // file changed under us, which fails the transfer instead.
                var skipped = 0L
                val discard = ByteArray(8192)
                while (skipped < offset) {
                    val want = minOf(discard.size.toLong(), offset - skipped).toInt()
                    val read = stream.read(discard, 0, want)
                    if (read <= 0) throw IOException("The file changed during upload.")
                    skipped += read
                }
                val buffer = ByteArray(chunkBytes)
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    val payload = Base64.encodeToString(buffer.copyOf(read), Base64.NO_WRAP)
                    val sent = CoreClient.remote(
                        peer,
                        "screen.transfer.chunk",
                        buildJsonObject { put("id", id); put("offset", offset); put("data", payload) },
                    ) as JsonObject
                    offset = sent["offset"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                        ?: (offset + read)
                    transferProgress = if (size == 0L) 1f else offset.toFloat() / size.toFloat()
                }
            }
            CoreClient.remote(peer, "screen.transfer.finish", buildJsonObject { put("id", id) })
            transferProgress = null
        } catch (e: CancellationException) {
            withContext(NonCancellable) {
                runCatching {
                    CoreClient.remote(peer, "screen.transfer.cancel", buildJsonObject { put("id", id) })
                }
            }
            transferProgress = null
            throw e
        } catch (e: Exception) {
            transferProgress = null
            requestNotice = e.message ?: "The file could not be sent."
        }
    }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    private companion object {
        /// How long a session has to hold up before the reconnect budget is
        /// given back.
        const val STABLE_AFTER_MS = 12_000L

        /// The separator the Apple client joins a transfer's resume key with.
        /// Both ends only have to agree with themselves, but agreeing with
        /// each other means a transfer started on one device resumes on the
        /// other.
        val NUL = "\u0000"
    }
}

/// A file chosen on this device, opened as many times as the transfer needs:
/// once to hash it, once to send it.
class ScreenFileSource(val name: String, val open: () -> InputStream)

/// This device's clipboard, as much of it as the viewer needs.
interface ScreenClipboard {
    /// A number that changes when the clipboard does, or -1 when this device
    /// will not say. Read before `read`, so a session that copies nothing
    /// never asks for the contents and never trips the system paste notice.
    fun stamp(): Long
    fun read(): String?
    fun write(text: String)
}
