// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf

/// Local display names, scoped to the account, host, project, and session.
class TerminalNames(context: Context) {
    private val prefs = context.getSharedPreferences("tokenstat.terminalNames.v1", Context.MODE_PRIVATE)
    private companion object {
        // Project rows, the global list and the live header have separate
        // store instances. A rename must invalidate all of their readers.
        val revision = mutableIntStateOf(0)
    }
    fun name(owner: ProjectOwner?, session: String): String? {
        revision.intValue
        return owner?.terminal(session)?.let { prefs.getString(it, null) }
    }
    fun rename(owner: ProjectOwner?, session: String, name: String) {
        val key = owner?.terminal(session) ?: return
        prefs.edit().putString(key, name).apply()
        revision.intValue += 1
    }
}
