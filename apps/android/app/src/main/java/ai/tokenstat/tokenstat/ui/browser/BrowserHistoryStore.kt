// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import android.content.Context
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class BrowserHistoryStore(context: Context) {
    private val preferences = context.getSharedPreferences("tokenstat.browser.v1", Context.MODE_PRIVATE)
    private val legacy = context.getSharedPreferences("browser", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    fun read(owner: ProjectOwner?): BrowserHistory.State {
        val raw = owner?.let { preferences.getString(it.key, null) } ?: return BrowserHistory.State()
        val stored = runCatching { json.decodeFromString<BrowserHistory.State>(raw) }.getOrNull()
            ?: return BrowserHistory.State()
        return BrowserHistory.clean(stored)
    }

    fun initial(owner: ProjectOwner?): BrowserTarget =
        BrowserHistory.initial(read(owner), legacy.getString("lastPort", null)?.toIntOrNull())

    fun record(owner: ProjectOwner?, target: BrowserTarget): BrowserHistory.State {
        val state = BrowserHistory.record(read(owner), target)
        if (owner != null) preferences.edit().putString(owner.key, json.encodeToString(state)).apply()
        return state
    }
}
