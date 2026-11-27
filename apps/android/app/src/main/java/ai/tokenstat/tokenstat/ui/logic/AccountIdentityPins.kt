// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

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

    @Synchronized
    fun identity(handle: String?, id: String?): String? {
        val name = handle?.trim()?.takeIf { it.isNotEmpty() }
        val account = id?.trim()?.takeIf { it.isNotEmpty() } ?: return name
        val store = store ?: return name ?: account
        pins[account]?.let { return it }
        val identity = name?.takeIf { it !in pins.values } ?: account
        pins = pins + (account to identity)
        store.write(pins)
        return identity
    }
}
