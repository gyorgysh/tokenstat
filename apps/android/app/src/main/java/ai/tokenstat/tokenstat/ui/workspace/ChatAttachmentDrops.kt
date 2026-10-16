// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.app.Activity
import android.content.ContextWrapper
import android.net.Uri
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.platform.LocalContext

/** One native target covers the transcript and composer. A drop only stages
 * files; the receiving visit owns both the imported bytes and URI permission. */
@Composable
internal fun chatAttachmentDrops(
    lease: ChatAttachmentInputLease,
    enabled: Boolean,
    receive: (ChatAttachmentInputLease, List<Uri>, () -> Unit) -> Unit,
    onTargeted: (Boolean) -> Unit = {},
): Modifier {
    val context = LocalContext.current
    val currentLease by rememberUpdatedState(lease)
    val canDrop by rememberUpdatedState(enabled)
    val receiveFiles by rememberUpdatedState(receive)
    val targeted by rememberUpdatedState(onTargeted)
    val target = remember(context, lease) {
        object : DragAndDropTarget {
            override fun onEntered(event: DragAndDropEvent) { targeted(canDrop) }
            override fun onExited(event: DragAndDropEvent) { targeted(false) }
            override fun onEnded(event: DragAndDropEvent) { targeted(false) }
            override fun onDrop(event: DragAndDropEvent): Boolean {
                targeted(false)
                if (!canDrop || !lease.accepts(currentLease)) return false
                val native = event.toAndroidDragEvent()
                val clip = native.clipData ?: return false
                val uris = (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
                    .filter { it.scheme == "content" || it.scheme == "file" }
                if (uris.isEmpty()) return false
                val activity = generateSequence(context) { (it as? ContextWrapper)?.baseContext }
                    .filterIsInstance<Activity>().firstOrNull()
                val permission = activity?.requestDragAndDropPermissions(native)
                try { receiveFiles(lease, uris) { permission?.release() } }
                catch (_: Exception) { permission?.release(); return false }
                return true
            }
        }
    }
    return Modifier.dragAndDropTarget(
        shouldStartDragAndDrop = { canDrop && lease.accepts(currentLease) }, target = target,
    )
}
