// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

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

    fun suppresses(reason: String, machine: String?): Boolean {
        if (reason != PushPayload.CHAT_FINISHED && reason != PushPayload.CHAT_FAILED) return false
        if (chatId == null) return false
        if (machine == null) return false
        return machine == machineId
    }
}
