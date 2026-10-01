// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/// Unsent writing survives leaving a screen, for the life of the ViewModel.
/// Capacity refuses a new edit visibly; it never evicts somebody's writing.
class ChatComposerSessions<A>(
    private val attachmentCost: (A) -> Long,
    private val capacity: Int = 64,
    private val byteLimit: Long = 64L * 1024 * 1024,
) {
    data class Snapshot<A>(val text: String = "", val attachments: List<A> = emptyList()) {
        val empty: Boolean get() = text.isEmpty() && attachments.isEmpty()
    }
    data class Failure(val owner: String?, val message: String)
    data class Capture<A>(val owner: String?, val snapshot: Snapshot<A>, val revision: Long)
    private val sessions = mutableMapOf<String, Snapshot<A>>()
    private val versions = mutableMapOf<String, Long>()
    private val mutableRevision = MutableStateFlow(0L)
    val revision = mutableRevision.asStateFlow()
    private val mutableFailure = MutableStateFlow<Failure?>(null)
    val failure = mutableFailure.asStateFlow()

    fun snapshot(owner: String?): Snapshot<A> = owner?.let { sessions[it] } ?: Snapshot()
    fun capture(owner: String?) = Capture(owner, snapshot(owner), versions[owner] ?: 0)
    fun hasWriting(owner: String?): Boolean = !snapshot(owner).empty
    fun dismissFailure() { mutableFailure.value = null }

    fun update(owner: String?, next: Snapshot<A>): Boolean {
        val reason = when {
            owner.isNullOrBlank() -> L10n.text("android.chatcomposersessions.open_a_conversation_before_writing.fb3b835a")
            !next.empty && owner !in sessions && sessions.size >= capacity ->
                L10n.text("android.chatcomposersessions.too_many_conversations_have_unsent_drafts.cd12b8ec")
            next.text.length > 128 * 1024 || cost(next) > byteLimit ||
                sessions.filterKeys { it != owner }.values.sumOf(::cost) > byteLimit - cost(next) ->
                L10n.text("android.chatcomposersessions.unsent_drafts_are_full_send_or_remove_stag.3e749631")
            else -> null
        }
        if (reason != null) {
            mutableFailure.value = Failure(owner, reason)
            return false
        }
        if (next.empty) {
            sessions.remove(owner)
            versions.remove(owner)
        } else {
            sessions[owner!!] = next.copy(attachments = next.attachments.toList())
            versions[owner] = mutableRevision.value + 1
        }
        mutableFailure.value = null
        mutableRevision.value += 1
        return true
    }

    /// A delayed acknowledgement only clears the exact payload it accepted.
    fun clearIfUnchanged(owner: String?, sent: Capture<A>): Boolean =
        if (sent.owner == owner && (versions[owner] ?: 0) == sent.revision && snapshot(owner) == sent.snapshot) update(owner, Snapshot()) else false

    private fun cost(snapshot: Snapshot<A>): Long =
        snapshot.text.length.toLong() * 2 + snapshot.attachments.sumOf { attachmentCost(it).coerceAtLeast(0) }

    fun text(owner: String?): ReadWriteProperty<Any?, String> = object : ReadWriteProperty<Any?, String> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): String = snapshot(owner).text
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: String) {
            update(owner, snapshot(owner).copy(text = value))
        }
    }
    fun attachments(owner: String?): ReadWriteProperty<Any?, List<A>> = object : ReadWriteProperty<Any?, List<A>> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): List<A> = snapshot(owner).attachments
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: List<A>) {
            update(owner, snapshot(owner).copy(attachments = value))
        }
    }
}
