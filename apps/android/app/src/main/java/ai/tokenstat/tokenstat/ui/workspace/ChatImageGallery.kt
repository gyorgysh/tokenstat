// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import android.content.ClipData
import android.content.Intent
import android.graphics.ImageDecoder
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A gallery owns its downloads; previews never borrow a foreground transfer. */
@Composable
internal fun ChatImageGallery(
    images: List<ChatDisplayItem.Attachment>, model: AppViewModel, peer: String, chatId: String,
    hostLabel: String, compact: Boolean = false,
) {
    if (images.isEmpty()) return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val accountFlow = remember(model) { model.state.map { it.account }.distinctUntilChanged() }
    val account by accountFlow.collectAsStateWithLifecycle(initialValue = null)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val owner = remember(account, peer, chatId) { ProjectOwner.from(account, peer, chatId) }
    val files = remember(owner, chatId) { mutableStateMapOf<String, File>() }
    val loading = remember(owner, chatId) { mutableStateMapOf<String, Boolean>() }
    val errors = remember(owner, chatId) { mutableStateMapOf<String, String>() }
    var viewer by remember(owner, chatId) { mutableStateOf<Int?>(null) }
    var loadAttempt by remember(owner, chatId) { mutableIntStateOf(0) }
    var relayItem by remember(owner, chatId) { mutableStateOf<ChatDisplayItem.Attachment?>(null) }
    var relayRemaining by remember(owner, chatId) { mutableStateOf<Long?>(null) }
    var relayAnswer by remember(owner, chatId) { mutableStateOf<CompletableDeferred<Boolean>?>(null) }
    var saveRequest by remember(owner, chatId) { mutableStateOf<Pair<ChatDisplayItem.Attachment, File>?>(null) }
    fun ownsFiles() = owner != null && ProjectOwner.from(model.state.value.account, peer, chatId) == owner
    val selected = viewer?.let { images.getOrNull(it) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(selected?.mediaType ?: "image/*")) { uri ->
        val request = saveRequest
        saveRequest = null
        if (uri != null && request != null && ownsFiles()) scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    check(ownsFiles())
                    context.contentResolver.openOutputStream(uri)?.use { output -> request.second.inputStream().use { it.copyTo(output) } }
                        ?: error(L10n.text("common.chat.images.save_failed"))
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (ownsFiles()) errors[request.first.attachmentId] = L10n.text("common.chat.images.save_failed") }
        }
    }
    DisposableEffect(owner, chatId) { onDispose { relayAnswer?.complete(false) } }
    suspend fun load(image: ChatDisplayItem.Attachment, automatic: Boolean): File? {
        files[image.attachmentId]?.takeIf { it.isFile }?.let { return it }
        if (loading[image.attachmentId] == true || !ownsFiles()) return null
        if (automatic && (image.size == null || image.size !in 1..CHAT_IMAGE_PREVIEW_BYTES)) return null
        loading[image.attachmentId] = true
        try {
            // Route changes are checked again by the transfer's consent gate.
            // Automatic previews never grant allowance to a relay fallback.
            if (automatic && !chatImageAutomaticPreviewAllowed(image.size, model.peerRoute(peer))) return null
            val file = downloadChatFile(File(context.cacheDir, "chat-downloads"), chatId, image.attachmentId, owner!!.key,
                call = { method, params -> check(ownsFiles()); model.workspaceSection(peer, method, params) },
                confirm = { remaining ->
                    if (automatic) false else {
                        val answer = CompletableDeferred<Boolean>()
                        relayItem = image; relayRemaining = remaining; relayAnswer = answer
                        try { answer.await() } finally { relayAnswer = null; relayItem = null }
                    }
                },
                progress = {}, byteLimit = if (automatic) CHAT_IMAGE_PREVIEW_BYTES else FILE_MAX.toLong())
            check(ownsFiles())
            files[image.attachmentId] = file
            errors.remove(image.attachmentId)
            return file
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            if (!automatic && ownsFiles()) errors[image.attachmentId] = TunnelCopy.display(failure.message.orEmpty(), hostLabel)
            return null
        } finally { loading.remove(image.attachmentId) }
    }
    LaunchedEffect(owner, images.take(4).map { it.attachmentId }, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            images.take(4).forEach { load(it, automatic = true) }
        }
    }
    val index = viewer
    LaunchedEffect(owner, index, images.map { it.attachmentId }, loadAttempt) {
        val image = index?.let(images::getOrNull) ?: return@LaunchedEffect
        snapshotFlow { loading[image.attachmentId] == true }.first { !it }
        load(image, automatic = false)
    }
    relayAnswer?.let { answer ->
        AlertDialog(onDismissRequest = { answer.complete(false) }, title = { Text(L10n.text("common.chat_files_relay_title")) },
            text = { Column { Text(L10n.text("common.chat_files_relay_message", relayItem?.name.orEmpty(), "${(relayItem?.size ?: 0) / 1048576} MB")); relayRemaining?.let { Text(L10n.text("common.chat_files_remaining", "${it / 1048576} MB")) } } },
            confirmButton = { TextButton(onClick = { answer.complete(true) }) { Text(L10n.text("common.continue")) } },
            dismissButton = { TextButton(onClick = { answer.complete(false) }) { Text(L10n.text("common.cancel")) } })
    }
    ChatImageTiles(images, files, loading.keys, compact) { viewer = it }
    if (selected != null && index != null) {
        ChatImageViewer(selected, index, images.size, files[selected.attachmentId], loading[selected.attachmentId] == true, errors[selected.attachmentId],
            onPrevious = { viewer = (index - 1).coerceAtLeast(0) }, onNext = { viewer = (index + 1).coerceAtMost(images.lastIndex) },
            onDismiss = { viewer = null }, onLoad = { loadAttempt++ },
            onSave = { files[selected.attachmentId]?.let { file -> if (ownsFiles()) { saveRequest = selected to file; save.launch(selected.name) } } },
            onOpen = {
                files[selected.attachmentId]?.let { file -> if (ownsFiles()) runCatching {
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.chatfiles", file)
                    context.startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, selected.mediaType ?: "image/*")
                        clipData = ClipData.newUri(context.contentResolver, selected.name, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    })
                }.onFailure { errors[selected.attachmentId] = it.message ?: L10n.text("common.chat.images.unavailable") } }
            })
    }
}

@Composable internal fun ChatImageTiles(images: List<ChatDisplayItem.Attachment>, files: Map<String, File>,
    busyIds: Set<String> = emptySet(), compact: Boolean = false, onView: (Int) -> Unit) {
    val visible = images.take(chatImageVisibleCount(images.size))
    if (compact) {
        Column(Modifier.width(68.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            visible.take(1).forEachIndexed { i, image ->
                ImageTile(image, imageBitmap(files[image.attachmentId], 512), image.attachmentId in busyIds,
                    Modifier.size(64.dp), extra = images.size - 1) { onView(i) }
            }
        }
    } else {
        // Each bounded thumbnail is decoded once off the UI thread. Its
        // dimensions can refine the default aspect once, without a measure /
        // decode feedback loop or synchronous metadata reads during layout.
        val bitmaps = visible.map { image -> key(image.attachmentId) { imageBitmap(files[image.attachmentId], CHAT_IMAGE_GALLERY_EDGE) } }
        val aspects = bitmaps.map { bitmap -> bitmap?.let { it.width.toDouble() / it.height } }
        BoxWithConstraints(Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
            val rows = chatImageGalleryGeometry(aspects, maxWidth.value)
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                rows.forEach { row ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(row.gap.dp)) {
                        row.indexes.forEachIndexed { column, i ->
                            val image = visible[i]
                            ImageTile(image, bitmaps[i], image.attachmentId in busyIds,
                                Modifier.width(row.widths[column].dp).height(row.height.dp),
                                extra = if (i == 3) images.size - 4 else 0) { onView(i) }
                        }
                    }
                }
                Text(if (images.size == 1) images.first().name else L10n.text("common.chat.images.count", "${images.size}"),
                    style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable private fun ImageTile(image: ChatDisplayItem.Attachment, bitmap: ImageBitmap?, busy: Boolean, modifier: Modifier, extra: Int, onClick: () -> Unit) {
    Box(modifier.clip(RoundedCornerShape(8.dp)).background(LocalTsColors.current.panel).clickable(onClick = onClick)
        .semantics { contentDescription = L10n.text("common.chat.images.view", image.name) }, contentAlignment = Alignment.Center) {
        if (bitmap != null) Image(bitmap, image.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        else if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        else Icon(ActionIcon.Attach.vector, image.name, tint = LocalTsColors.current.textSecondary)
        if (extra > 0) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .55f)), contentAlignment = Alignment.Center) {
            Text(L10n.text("common.chat.images.more", "$extra"), color = Color.White, style = MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable private fun imageBitmap(file: File?, maxEdge: Int): ImageBitmap? {
    val cache = ChatImageCache.shared(LocalContext.current)
    return key(file, maxEdge) {
        val bitmap by produceState<ImageBitmap?>(null) {
            value = if (file == null) null else cache.image(file, maxEdge)?.asImageBitmap()
        }
        bitmap
    }
}

internal fun decodeChatImage(file: File, maxEdge: Int): android.graphics.Bitmap =
    ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
        val (width, height) = chatImageDecodeSize(info.size.width, info.size.height, maxEdge)
        decoder.setTargetSize(width, height)
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    }

@Composable internal fun ChatImageViewer(
    image: ChatDisplayItem.Attachment, index: Int, count: Int, file: File?, busy: Boolean, failure: String?,
    onPrevious: () -> Unit, onNext: () -> Unit, onDismiss: () -> Unit, onLoad: () -> Unit,
    onOpen: () -> Unit, onSave: () -> Unit,
) {
    var scale by remember(image.attachmentId) { mutableStateOf(1f) }
    var offset by remember(image.attachmentId) { mutableStateOf(Offset.Zero) }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    fun zoom(next: Float, pan: Offset = Offset.Zero) {
        scale = next.coerceIn(1f, 5f)
        val limitX = viewport.width * (scale - 1) / 2
        val limitY = viewport.height * (scale - 1) / 2
        offset = Offset((offset.x + pan.x).coerceIn(-limitX, limitX), (offset.y + pan.y).coerceIn(-limitY, limitY))
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = LocalTsColors.current.background) {
            Column(Modifier.fillMaxSize().safeDrawingPadding().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(image.name, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
                        Text(L10n.text("common.chat.images.position", "${index + 1}", "$count"), style = MaterialTheme.typography.labelSmall, color = LocalTsColors.current.textSecondary)
                    }
                    IconButton(onClick = onDismiss) { Icon(ActionIcon.Dismiss.vector, L10n.text("common.close")) }
                }
                Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(LocalTsColors.current.panel)
                    .onSizeChanged { viewport = it }, contentAlignment = Alignment.Center) {
                    val bitmap = imageBitmap(file, 2048)
                    if (bitmap != null) Image(bitmap, image.name,
                        Modifier.fillMaxSize().graphicsLayer { scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y }
                            .transformable(rememberTransformableState { centroid, factor, pan, _ ->
                                val next = (scale * factor).coerceIn(1f, 5f)
                                val pivot = if (centroid.x.isFinite() && centroid.y.isFinite())
                                    centroid - Offset(viewport.width / 2f, viewport.height / 2f) else Offset.Zero
                                zoom(next, (offset - pivot) * (next / scale - 1f) + pan)
                            })
                            .pointerInput(image.attachmentId) { detectTapGestures(onDoubleTap = { zoom(if (scale == 1f) 2f else 1f) }) },
                        contentScale = ContentScale.Fit)
                    else if (busy) CircularProgressIndicator(Modifier.size(28.dp))
                    else Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(L10n.text("common.chat.images.unavailable"), color = LocalTsColors.current.textSecondary)
                        TextButton(onClick = onLoad) { Text(L10n.text("common.chat.images.load")) }
                    }
                }
                if (failure != null) Text(failure, style = MaterialTheme.typography.bodySmall, color = LocalTsColors.current.danger)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onPrevious, enabled = index > 0) { Icon(ActionIcon.Back.vector, L10n.text("common.chat.images.previous")) }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { zoom(scale / 1.5f) }, modifier = Modifier.semantics { contentDescription = L10n.text("common.chat.images.zoom_out") }) { Text("−") }
                        TextButton(onClick = { zoom(1f) }, modifier = Modifier.semantics { contentDescription = L10n.text("common.chat.images.reset_zoom") }) { Text("${(scale * 100).toInt()}%") }
                        TextButton(onClick = { zoom(scale * 1.5f) }, modifier = Modifier.semantics { contentDescription = L10n.text("common.chat.images.zoom_in") }) { Text("+") }
                    }
                    IconButton(onClick = onNext, enabled = index + 1 < count) { Icon(ActionIcon.Next.vector, L10n.text("common.chat.images.next")) }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                    TextButton(onClick = onOpen, enabled = file != null && !busy) { Text(L10n.text("common.open")) }
                    TextButton(onClick = onSave, enabled = file != null && !busy) { Text(L10n.text("common.save")) }
                }
            }
        }
    }
}
