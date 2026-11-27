// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

internal class ChatAttachmentInputLease(val owner: String?) {
    private var active = true
    fun retire() { active = false }
    fun accepts(current: ChatAttachmentInputLease) = active && this === current && owner != null
}
