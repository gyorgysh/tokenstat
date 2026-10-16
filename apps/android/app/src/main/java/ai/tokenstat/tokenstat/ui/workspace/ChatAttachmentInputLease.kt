// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

/** A returning picker must belong to this visit, including after an A → B → A switch. */
internal class ChatAttachmentInputLease(val owner: String?) {
    private var active = true
    fun retire() { active = false }
    fun accepts(current: ChatAttachmentInputLease) = active && this === current && owner != null
}
