// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/** In-memory turn clocks, scoped to the account, host and conversation. */
class ChatTurnTimes {
    private val starts = linkedMapOf<String, Long>()
    fun observe(owner: String?, running: Boolean, now: Long): Long? {
        owner ?: return null
        if (!running) { starts.remove(owner); return null }
        return starts[owner] ?: begin(owner, now)
    }
    fun begin(owner: String, now: Long): Long {
        val start = minOf(starts[owner] ?: now, now)
        if (owner !in starts && starts.size >= 256) starts.remove(starts.keys.first())
        starts[owner] = start
        return start
    }
    fun clear() { starts.clear() }
}
