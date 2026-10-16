// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.localization.L10n
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class ChatAttachmentInputs(
    val reading: Boolean,
    val targeted: Boolean,
    val drops: Modifier,
    val pick: () -> Unit,
)

/** Keep picker, drop permissions and imports in one bounded composition. Besides
 * owning each file selection, this avoids exceeding ART's register verifier in
 * the conversation's much larger UI method. */
@Composable
internal fun rememberChatAttachmentInputs(
    model: AppViewModel,
    owner: String?,
    ownsOwner: () -> Boolean,
    enabled: Boolean,
    onError: (String?) -> Unit,
): ChatAttachmentInputs {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val lease = remember(owner) { ChatAttachmentInputLease(owner) }
    val currentLease by rememberUpdatedState(lease)
    val ownsCurrentOwner by rememberUpdatedState(ownsOwner)
    val reportError by rememberUpdatedState(onError)
    DisposableEffect(lease) { onDispose { lease.retire() } }
    // A picker returning after A → B → A still belongs to the first visit.
    var pickerLease by remember { mutableStateOf<ChatAttachmentInputLease?>(null) }
    var reading by remember(lease) { mutableStateOf(false) }
    var targeted by remember(lease) { mutableStateOf(false) }
    fun importFiles(input: ChatAttachmentInputLease, uris: List<Uri>, release: () -> Unit = {}) {
        if (uris.isEmpty() || !input.accepts(currentLease) || !ownsCurrentOwner() || reading) { release(); return }
        // Enter immediately so cancellation always releases native drop access.
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            reading = true; reportError(null)
            try {
                for (uri in uris) {
                    if (!input.accepts(currentLease) || !ownsCurrentOwner()) return@launch
                    val before = model.chatComposers.snapshot(input.owner)
                    val remaining = FILE_MAX.toLong() - before.attachments.sumOf { it.bytes.toLong() }
                    if (before.attachments.size >= 20 || remaining <= 0) {
                        reportError(L10n.text("android.chatpullssections.send_or_remove_the_staged_files_before_add.40e8ba5e")); break
                    }
                    var read: AttachmentRead? = null
                    try {
                        withContext(Dispatchers.IO) { read = readAttachment(context, uri, remaining.toInt()) }
                    } catch (cancelled: CancellationException) {
                        (read as? AttachmentRead.Ok)?.attachment?.filePath?.let { File(it).delete() }; throw cancelled
                    }
                    val attachment = (read as? AttachmentRead.Ok)?.attachment
                    if (!input.accepts(currentLease) || !ownsCurrentOwner()) {
                        attachment?.filePath?.let { File(it).delete() }; return@launch
                    }
                    if (attachment == null) { reportError((read as? AttachmentRead.Failed)?.reason); continue }
                    val now = model.chatComposers.snapshot(input.owner)
                    if (now.attachments.size >= 20 || now.attachments.sumOf { it.bytes.toLong() } + attachment.bytes > FILE_MAX ||
                        !model.chatComposers.update(input.owner, now.copy(attachments = now.attachments + attachment))) {
                        attachment.filePath?.let { File(it).delete() }
                        reportError(model.chatComposers.failure.value?.takeIf { it.owner == input.owner }?.message
                            ?: L10n.text("android.chatpullssections.send_or_remove_the_staged_files_before_add.40e8ba5e"))
                        break
                    }
                }
            } finally { release(); if (input.accepts(currentLease)) reading = false }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val input = pickerLease
        pickerLease = null
        if (input != null) importFiles(input, uris.orEmpty())
    }
    val drops = chatAttachmentDrops(lease, owner != null && ownsOwner() && enabled && !reading,
        ::importFiles, { targeted = it })
    return ChatAttachmentInputs(reading, targeted, drops) {
        reportError(null); pickerLease = lease; picker.launch(arrayOf("*/*"))
    }
}
