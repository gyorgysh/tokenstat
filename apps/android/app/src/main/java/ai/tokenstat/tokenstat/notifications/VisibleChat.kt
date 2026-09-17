// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

/// The conversation on screen right now, if any.
///
/// A push carries a reason and a machine, never a chat id, so the service
/// cannot tell which chat finished. But it can tell whether the person is
/// already looking at that machine's conversation, and a "finished" banner
/// over the transcript it finished in is noise. The chat screen reports
/// what it shows; the service drops chat reasons for that machine.
object VisibleChat {
    @Volatile
    private var machineId: String? = null

    @Volatile
    private var chatId: String? = null

    fun showing(machineId: String?, chatId: String?) {
        this.machineId = machineId
        this.chatId = chatId
    }

    fun hidden() {
        machineId = null
        chatId = null
    }

    /// True when this delivery would announce a turn the person is already
    /// watching. Runs still notify: they are not the transcript in front of
    /// you, and a run waiting on input needs an answer, not silence.
    fun suppresses(reason: String, machine: String?): Boolean {
        if (reason != PushPayload.CHAT_FINISHED && reason != PushPayload.CHAT_FAILED) return false
        if (chatId == null) return false
        if (machine == null) return false
        return machine == machineId
    }
}
