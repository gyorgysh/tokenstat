// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
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

class ScreenViewerModel(
    private val app: AppViewModel,
    private val scope: CoroutineScope,
    private val clipboard: ScreenClipboard? = null,
    private val closeScope: CoroutineScope = scope,
) {
    enum class State { Idle, Connecting, Streaming, Failed }

    var state by mutableStateOf(State.Idle)
        private set
    var message by mutableStateOf(L10n.text("android.screenviewermodel.connecting.72021eb7"))
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

    var cursorX by mutableFloatStateOf(0.5f)
        private set
    var cursorY by mutableFloatStateOf(0.5f)
        private set

    val decoder = ScreenDecoder()
    val audio = ScreenAudio()

    var isControlling by mutableStateOf(false)
        private set

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
    private val mediaLock = Any()
    private var stopped = false
    private var generation = 0
    private var attempts = 0
    private var connectedSince = 0L
    private var streamingSince = 0L
    private var lastAutoRequest = 0L
    private var clipboardStamp = -1L
    private var clipboardWritten: String? = null

    val needsPermission: Boolean
        get() = message.lowercase().let {
            it.contains("permission") || it.contains("screen access") || it.contains("allowed")
        }

    val needsLegend: Boolean
        get() = message.contains("legend plan", ignoreCase = true)

    fun start(peer: String, hostLabel: String, tier: String?, control: Boolean) {
        stop()
        stopped = false
        generation += 1
        val current = generation
        this.peer = peer
        this.label = hostLabel
        this.tier = tier
        isControlling = control
        requestNotice = null
        attempts = 0
        state = State.Connecting
        message = L10n.text("android.screenviewermodel.connecting.72021eb7")
        startInputPump()
        startHeartbeat()
        sessionJob = scope.launch { runSession(current) }
    }

    private var label = ""

    fun stop() {
        stopped = true
        heartbeatJob?.cancel()
        heartbeatJob = null
        inputJob?.cancel()
        inputJob = null
        transferJob?.cancel()
        sessionJob?.cancel()
        sessionJob = null
        synchronized(inputLock) { inputQueue.clear() }
        val id = viewerId
        viewerId = null
        hostSessionId = null
        if (id != null) {
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

    private suspend fun retry(current: Int, reason: String, autoRequest: Boolean): Boolean {
        if (current != generation || stopped) return false
        if (actionable(reason)) {
            closeSession()
            state = State.Failed
            message = reason
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
            message = L10n.text("android.screenviewermodel.connection_could_not_recover_0.7c8ca1d2", "${reason}")
            return false
        }
        state = State.Connecting
        message = L10n.text("android.screenviewermodel.reconnecting_attempt_0_of_3_1.8f4f26ac", "${attempts}", "${reason}")
        delay(attempts * 1_000L)
        return current == generation && !stopped
    }

    private suspend fun openSession(): String? {
        if (!tier.equals("legend", ignoreCase = true)) {
            return L10n.text("android.screenviewermodel.screen_access_requires_the_legend_plan.66173f1c")
        }
        return try {
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
                ?: return L10n.text("android.screenviewermodel.the_viewer_opened_without_an_id.9cdf904c")
            hostSessionId = opened["sessionId"]?.jsonPrimitive?.contentOrNull
            transport = opened["transport"]?.jsonPrimitive?.contentOrNull
            connectedSince = System.currentTimeMillis()
            streamingSince = 0
            synchronized(mediaLock) { decoder.reset() }
            state = State.Connecting
            message = L10n.text("android.screenviewermodel.waiting_for_the_first_picture.be8d50cf")
            null
        } catch (e: Exception) {
            e.message ?: L10n.text("android.screenviewermodel.the_screen_session_failed.92e22825")
        }
    }

    private suspend fun issueCapability(control: Boolean): String {
        val identity = app.core("machine.identity") as JsonObject
        val peerId = identity["key"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalStateException(L10n.text("android.screenviewermodel.this_device_has_no_identity_yet.40d835eb"))
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
            ?: throw IllegalStateException(L10n.text("android.screenviewermodel.the_host_did_not_issue_a_capability.b8faa6a5"))
    }

    private suspend fun closeSession() {
        val id = viewerId ?: return
        withContext(NonCancellable) {
            runCatching { app.core("screen.viewer.close", buildJsonObject { put("id", id) }) }
        }
        if (viewerId == id) {
            viewerId = null
            hostSessionId = null
        }
    }

    private suspend fun readLoop(current: Int): String? {
        val id = viewerId ?: return L10n.text("android.screenviewermodel.the_viewer_never_opened.e0afb76d")
        while (current == generation && !stopped) {
            val chunk = try {
                app.core(
                    "screen.viewer.read",
                    buildJsonObject { put("id", id); put("waitMs", 250) },
                ) as JsonObject
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return e.message ?: L10n.text("android.screenviewermodel.the_screen_session_broke.487e4664")
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
                closeSession()
                connectedSince = 0
                state = State.Failed
                message = L10n.text("android.screenviewermodel.connected_but_no_picture_has_arrived_yet_t.7af64031")
                return null
            }
            if (chunk["active"]?.jsonPrimitive?.contentOrNull == "false") {
                return chunk["error"]?.jsonPrimitive?.contentOrNull ?: L10n.text("android.screenviewermodel.the_screen_session_ended.c37a27b0")
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
                    clipboardWritten = it
                }
            }
        }
    }

    private suspend fun applyFrame(encoded: String) {
        val bytes = decode(encoded) ?: return
        val frame = withContext(Dispatchers.Default) { ScreenFrames.parse(bytes) } ?: return
        val ratio = frame.width.toFloat() / frame.height.coerceAtLeast(1).toFloat()
        if (ratio.isFinite() && ratio > 0f) aspectRatio = ratio
        val rendered = withContext(Dispatchers.Default) {
            synchronized(mediaLock) { decoder.decode(frame) }
        }
        if (!rendered) return
        if (streamingSince == 0L) {
            streamingSince = System.currentTimeMillis()
        } else if (System.currentTimeMillis() - streamingSince > STABLE_AFTER_MS) {
            attempts = 0
        }
        if (state != State.Streaming) {
            state = State.Streaming
            message = ScreenFrames.transportLabel(transport)
        }
    }

    private fun decode(encoded: String): ByteArray? =
        runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull()

    private fun actionable(reason: String): Boolean {
        val value = reason.lowercase()
        return value.contains("screen recording") || value.contains("accessibility") ||
            value.contains("permission") || value.contains("not been allowed") ||
            value.contains("does not have screen access") || value.contains("legend plan") ||
            value.contains("no display") || value.contains("videotoolbox")
    }


    private fun startInputPump() {
        inputJob = scope.launch {
            for (ignored in inputSignal) {
                while (true) {
                    if (stopped) break
                    val next: PendingInput = synchronized(inputLock) {
                        if (inputQueue.isEmpty()) null else inputQueue.removeFirst()
                    } ?: break
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

    private fun startHeartbeat() {
        heartbeatJob = scope.launch {
            while (isActive && !stopped) {
                delay(30_000)
                if (!stopped && viewerId != null) send(ScreenFrames.heartbeat())
            }
        }
    }

    private fun send(json: String) {
        if (stopped || viewerId == null) return
        synchronized(inputLock) { inputQueue.addLast(PendingInput.Control(json)) }
        inputSignal.trySend(Unit)
    }

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

    fun move(x: Float, y: Float) {
        cursorX = x.coerceIn(0f, 1f)
        cursorY = y.coerceIn(0f, 1f)
        if (!isControlling) return
        sendMove(ScreenFrames.move(cursorX.toDouble(), cursorY.toDouble()))
    }

    fun nudge(dx: Float, dy: Float, width: Float, height: Float, sensitivity: Float) {
        move(
            cursorX + dx * sensitivity / width.coerceAtLeast(1f),
            cursorY + dy * sensitivity / height.coerceAtLeast(1f),
        )
    }

    fun click(button: Int, count: Int, flags: Long = 0) {
        if (!isControlling) return
        send(ScreenFrames.click(cursorX.toDouble(), cursorY.toDouble(), button, count, flags))
    }

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


    fun setControl(wanted: Boolean) {
        if (wanted == isControlling) return
        scope.launch {
            val hostSession = hostSessionId
            if (viewerId != null && !hostSession.isNullOrBlank()) {
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
                    isControlling = wanted
                    return@launch
                }
            }
            val keepTier = tier
            val keepPeer = peer
            val keepLabel = label
            stop()
            start(keepPeer, keepLabel, keepTier, wanted)
            message = if (wanted) L10n.text("android.screenviewermodel.asking_for_control.50c714d1") else L10n.text("android.screenviewermodel.switching_to_view_only.d67a2762")
        }
    }

    fun chooseQuality(wanted: ScreenQuality) {
        if (wanted == quality) return
        quality = wanted
        val hostSession = hostSessionId
        if (viewerId == null || hostSession.isNullOrBlank()) return
        scope.launch {
            runCatching {
                val token = issueCapability(isControlling)
                CoreClient.remote(
                    peer,
                    "screen.quality.set",
                    buildJsonObject {
                        put("sessionId", hostSession)
                        put("capability", token)
                        put("quality", wanted.wire ?: "auto")
                    },
                )
            }
        }
    }


    fun requestAccess() {
        if (isRequesting) return
        scope.launch { requestAccessNow() }
    }

    private suspend fun requestAccessNow() {
        isRequesting = true
        try {
            val asked = runCatching { ask(isControlling) }
            val answer = asked.getOrElse {
                requestNotice = it.message ?: L10n.text("android.screenviewermodel.that_computer_could_not_be_asked.d4222412")
                return
            }
            val allowed = if (answer && !isControlling) {
                runCatching { ask(true) }.getOrDefault(true)
            } else {
                answer
            }
            if (allowed) {
                requestNotice = L10n.text("android.screenviewermodel.this_device_already_has_access_press_try_a.fd1aee06")
                return
            }
            requestNotice = L10n.text("android.screenviewermodel.asked_approve_this_device_on_that_computer.f8ffae43")
            runCatching {
                val sent = app.core("screen.access.request") as JsonObject
                val devices = sent["sent"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 0
                val enabled = sent["enabled"]?.jsonPrimitive?.contentOrNull == "true"
                val signedIn = sent["signedIn"]?.jsonPrimitive?.contentOrNull == "true"
                if (signedIn && enabled && devices > 0) {
                    requestNotice = L10n.text("android.screenviewermodel.asked_a_notification_went_to_your_other_de.3be993ac")
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
        transferProgress = null
    }

    private suspend fun transfer(file: ScreenFileSource, destination: String = peer) = withContext(Dispatchers.IO) {
        var id = ""
        try {
            val hashed = hashScreenFile(file.open)
            val size = hashed.size
            val hash = hashed.sha256
            id = hex(
                MessageDigest.getInstance("SHA-256").digest(
                    listOf(file.name, size.toString(), hash)
                        .joinToString(NUL)
                        .toByteArray(Charsets.UTF_8)
                )
            )
            val opened = CoreClient.remote(
                destination,
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
                var skipped = 0L
                val discard = ByteArray(8192)
                while (skipped < offset) {
                    currentCoroutineContext().ensureActive()
                    val want = minOf(discard.size.toLong(), offset - skipped).toInt()
                    val read = stream.read(discard, 0, want)
                    if (read <= 0) throw IOException(L10n.text("android.screenviewermodel.the_file_changed_during_upload.ed47b50e"))
                    skipped += read
                }
                val buffer = ByteArray(chunkBytes)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    val payload = Base64.encodeToString(buffer.copyOf(read), Base64.NO_WRAP)
                    val sent = CoreClient.remote(
                        destination,
                        "screen.transfer.chunk",
                        buildJsonObject { put("id", id); put("offset", offset); put("data", payload) },
                    ) as JsonObject
                    offset = sent["offset"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                        ?: (offset + read)
                    transferProgress = if (size == 0L) 1f else offset.toFloat() / size.toFloat()
                }
            }
            CoreClient.remote(destination, "screen.transfer.finish", buildJsonObject { put("id", id) })
            transferProgress = null
        } catch (e: CancellationException) {
            withContext(NonCancellable) {
                runCatching {
                    CoreClient.remote(destination, "screen.transfer.cancel", buildJsonObject { put("id", id) })
                }
            }
            transferProgress = null
            throw e
        } catch (e: Exception) {
            transferProgress = null
            requestNotice = e.message ?: L10n.text("android.screenviewermodel.the_file_could_not_be_sent.47565f42")
        }
    }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    private companion object {
        const val STABLE_AFTER_MS = 12_000L

        val NUL = "\u0000"
    }
}

class ScreenFileSource(val name: String, val open: () -> InputStream)

interface ScreenClipboard {
    fun stamp(): Long
    fun read(): String?
    fun write(text: String)
}
