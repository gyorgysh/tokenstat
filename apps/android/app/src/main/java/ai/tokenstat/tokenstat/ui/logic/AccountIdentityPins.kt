// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/// What this device files each account's work under, kept from the first time
/// it saw the account. Port of `AccountIdentityPins` in `WorkReference.swift`.
///
/// Drafts, pins, reading places and setup progress are keyed by an identity
/// that used to be recomputed from the handle. Claiming a handle moved it from
/// the server's id to the name, changing one moved it again, and each time
/// everything filed under the old one was left behind. The account's id does
/// not move, so it is what finds the identity, and the identity stays put.
///
/// Off until `activate`, which the application does before anything asks.
object AccountIdentityPins {
    interface Store {
        fun read(): Map<String, String>
        fun write(pins: Map<String, String>)
    }

    private var store: Store? = null
    private var pins: Map<String, String> = emptyMap()

    @Synchronized
    fun activate(store: Store?) {
        this.store = store
        pins = store?.read().orEmpty()
    }

    /// Null only when neither answers, which is the unknown-account state.
    @Synchronized
    fun identity(handle: String?, id: String?): String? {
        val name = handle?.trim()?.takeIf { it.isNotEmpty() }
        val account = id?.trim()?.takeIf { it.isNotEmpty() } ?: return name
        val store = store ?: return name ?: account
        pins[account]?.let { return it }
        // A handle can be released and claimed by somebody else. Whoever was
        // filed under it here first keeps it, and the newcomer gets their id,
        // so one person's work never opens for another.
        val identity = name?.takeIf { it !in pins.values } ?: account
        pins = pins + (account to identity)
        store.write(pins)
        return identity
    }
}
