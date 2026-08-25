// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.screen

import android.view.TextureView
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import android.app.Activity
import android.util.Base64
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/// Legend screen viewer: open a capability, pull H.264, keep the display on.
/// Control and file transfer stay on the Mac; this is the watch surface.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenViewerScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    onClose: () -> Unit,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var status by remember { mutableStateOf("Opening…") }
    var sessionId by remember { mutableStateOf<String?>(null) }
    var transport by remember { mutableStateOf<String?>(null) }
    var texture by remember { mutableStateOf<TextureView?>(null) }

    val scope = rememberCoroutineScope()
    DisposableEffect(Unit) {
        val window = (context as? Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            val id = sessionId
            if (id != null) {
                scope.launch {
                    runCatching { model.core("screen.viewer.close", buildJsonObject { put("id", id) }) }
                }
            }
        }
    }

    LaunchedEffect(peer) {
        runCatching {
            val identity = model.core("machine.identity") as JsonObject
            val peerId = identity["publicIdentity"]?.jsonPrimitive?.contentOrNull
                ?: throw IllegalStateException("This phone has no identity yet.")
            val cap = model.workspaceSection(
                peer,
                "screen.capability.issue",
                buildJsonObject {
                    put("peerId", peerId)
                    put("control", false)
                    put("tier", "legend")
                },
            ) as JsonObject
            val token = cap["token"]?.jsonPrimitive?.contentOrNull
                ?: throw IllegalStateException("The host did not issue a capability.")
            val opened = model.core(
                "screen.viewer.open",
                buildJsonObject {
                    put("peer", peer)
                    put("capability", token)
                    put("control", false)
                },
            ) as JsonObject
            val id = opened["id"]?.jsonPrimitive?.contentOrNull
                ?: throw IllegalStateException("The viewer opened without an id.")
            sessionId = id
            transport = opened["transport"]?.jsonPrimitive?.contentOrNull
            status = (transport ?: "relay")
            while (true) {
                val chunk = model.core(
                    "screen.viewer.read",
                    buildJsonObject {
                        put("id", id)
                        put("waitMs", 250)
                    },
                ) as JsonObject
                val err = chunk["error"]?.jsonPrimitive?.contentOrNull
                if (!err.isNullOrBlank()) {
                    status = err
                    break
                }
                val frame = chunk["frame"]?.jsonPrimitive?.contentOrNull
                if (!frame.isNullOrBlank()) {
                    decodeFrame(texture, frame)
                    status = transport ?: "live"
                }
                if (chunk["active"]?.jsonPrimitive?.content == "false") {
                    status = "The host stopped sharing."
                    break
                }
            }
        }.onFailure { status = it.message ?: "Screen share failed." }
    }

    Column(Modifier.fillMaxSize().background(colors.background)) {
        TopAppBar(
            title = { Text("$hostLabel · $status") },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
        )
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx -> TextureView(ctx).also { texture = it } },
            )
            if (status != "live" && status != "direct" && status != "relay") {
                Text(status, color = colors.textSecondary, modifier = Modifier.padding(Space.l))
            }
        }
    }
}

private fun decodeFrame(view: TextureView?, b64: String) {
    if (view == null || !view.isAvailable) return
    val bytes = runCatching { Base64.decode(b64, Base64.DEFAULT) }.getOrNull() ?: return
    // A JPEG still from some hosts; H.264 needs MediaCodec and is tried next.
    if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) {
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
        val canvas = view.lockCanvas() ?: return
        canvas.drawBitmap(bitmap, null, android.graphics.Rect(0, 0, canvas.width, canvas.height), null)
        view.unlockCanvasAndPost(canvas)
    }
}
