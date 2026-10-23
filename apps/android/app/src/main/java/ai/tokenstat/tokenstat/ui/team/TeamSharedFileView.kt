// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject

@Composable internal fun SharedFile(file: JsonObject, fetch: suspend (String) -> JsonObject, saveOverride: ((TeamSharedFileData) -> Unit)? = null) {
    val id = file.teamString("id") ?: return
    val name = TeamSharedFileData.safeName(file.teamString("name").orEmpty())
    val colors = LocalTsColors.current; val context = LocalContext.current; val scope = rememberCoroutineScope()
    var image by remember(id) { mutableStateOf<ImageBitmap?>(null) }
    var note by remember(id) { mutableStateOf<String?>(null) }
    var busy by remember(id) { mutableStateOf(false) }
    var pending by remember(id) { mutableStateOf<TeamSharedFileData?>(null) }
    var active by remember(id) { mutableStateOf(true) }
    DisposableEffect(id) { onDispose { active = false; pending = null } }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val data = pending; pending = null
        if (uri != null && data != null && active) scope.launch {
            busy = true
            try {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(data.bytes) } ?: error("file_save_failed")
                }
                if (active) note = L10n.text("common.teams.file_saved")
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (active) note = L10n.text("common.teams.file_save_failed") }
            finally { busy = false }
        }
    }
    suspend fun read(): TeamSharedFileData {
        val reply = fetch(id)
        return withContext(Dispatchers.Default) { TeamSharedFileData.read(reply, id) }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(name, color = colors.textPrimary)
        image?.let { Image(it, contentDescription = name, modifier = Modifier.fillMaxWidth()) }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            TsSecondaryButton(L10n.text("common.teams.save_file"), enabled = !busy && pending == null, icon = ActionIcon.Save.vector, onClick = {
                scope.launch {
                    busy = true; note = null
                    try {
                        val data = read()
                        if (active) {
                            if (saveOverride != null) { saveOverride(data); note = L10n.text("common.teams.file_saved") }
                            else { pending = data; save.launch(data.name) }
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) { pending = null; if (active) note = if (failure is CoreFailure) failure.message else L10n.text("common.teams.file_save_failed") }
                    finally { busy = false }
                }
            })
            val hint = file.teamString("mediaType").orEmpty().lowercase(java.util.Locale.ROOT)
            if (image == null && hint.startsWith("image/") && hint != "image/svg+xml") TsSecondaryButton(L10n.text("common.teams.open_file_action"), enabled = !busy && pending == null, icon = ActionIcon.Preview.vector, onClick = {
                scope.launch {
                    busy = true; note = null
                    try {
                        val data = read(); require(data.raster)
                        image = withContext(Dispatchers.Default) { decodeTeamImage(data.bytes) }
                        if (image == null) note = L10n.text("common.teams.file_unavailable")
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) { if (active) note = if (failure is CoreFailure) failure.message else L10n.text("common.teams.file_unavailable") }
                    finally { busy = false }
                }
            })
        }
        note?.let { Text(it, color = colors.textSecondary) }
    }
}
private fun decodeTeamImage(bytes: ByteArray): ImageBitmap? {
    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val (w, h) = bounds.outWidth.toLong() to bounds.outHeight.toLong()
    if (w <= 0 || h <= 0 || w * h > 100_000_000L || maxOf(w, h) / minOf(w, h) > 50) return null
    var sample = 1; while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) sample *= 2
    return android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}
