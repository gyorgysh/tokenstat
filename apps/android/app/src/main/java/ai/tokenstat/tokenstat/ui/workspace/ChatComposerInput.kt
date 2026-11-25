// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.content.MediaType
import androidx.compose.foundation.content.TransferableContent
import androidx.compose.foundation.content.consume
import androidx.compose.foundation.content.contentReceiver
import androidx.compose.foundation.content.hasMediaType
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import java.lang.ref.Reference

internal class ChatComposerInput(initialDraft: String) {
    val editor = TextFieldState(initialDraft)
    private var saved = initialDraft

    fun sync(draft: String) {
        if (draft == saved) return
        saved = draft
        if (editor.text.toString() != draft) editor.setTextAndPlaceCursorAtEnd(draft)
    }

    fun publish(read: () -> String, write: (String) -> Unit, verifyWrite: Boolean): Boolean {
        val draft = read()
        sync(draft)
        val edited = editor.text.toString()
        if (edited == draft) return true
        write(edited)
        if (!verifyWrite) return true
        saved = read()
        if (saved == edited) return true
        editor.setTextAndPlaceCursorAtEnd(saved)
        return false
    }
}

@Composable
internal fun rememberChatComposerInput(owner: String?, draft: String, readDraft: (() -> String)?, writeDraft: (String) -> Unit): ChatComposerInput {
    val input = remember(owner) { ChatComposerInput(draft) }
    val currentRead by rememberUpdatedState(readDraft ?: { draft })
    val currentWrite by rememberUpdatedState(writeDraft)
    SideEffect { input.sync(currentRead()) }
    LaunchedEffect(input) {
        snapshotFlow { input.editor.text.toString() }.collect { input.publish(currentRead, currentWrite, readDraft != null) }
    }
    return input
}

/** Clipboard and keyboard images use the same owned file import as the picker. */
@OptIn(ExperimentalFoundationApi::class)
internal fun Modifier.chatImagePaste(onImages: (List<Uri>, () -> Unit) -> Unit): Modifier =
    contentReceiver { content ->
        if (content.source == TransferableContent.Source.DragAndDrop || !content.hasMediaType(MediaType.Image)) {
            return@contentReceiver content
        }
        val images = mutableListOf<Uri>()
        val remaining = content.consume { item ->
            val uri = item.uri
            if (uri?.scheme != "content" || item.text != null) return@consume false
            images.add(uri)
            true
        }
        if (images.isNotEmpty()) {
            // The IME's grant is held by the platform data in this object.
            onImages(images) { Reference.reachabilityFence(content) }
        }
        remaining
    }
