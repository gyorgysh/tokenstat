// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CoroutineScope

/** Restart read-only screen polling on resume; stop it when the screen is hidden. */
@Composable
fun ForegroundEffect(vararg keys: Any?, block: suspend CoroutineScope.() -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val currentBlock = rememberUpdatedState(block)
    LaunchedEffect(lifecycle, *keys) {
        lifecycle.runWhileStarted { currentBlock.value(this) }
    }
}

internal suspend fun Lifecycle.runWhileStarted(block: suspend CoroutineScope.() -> Unit) {
    repeatOnLifecycle(Lifecycle.State.STARTED, block)
}
