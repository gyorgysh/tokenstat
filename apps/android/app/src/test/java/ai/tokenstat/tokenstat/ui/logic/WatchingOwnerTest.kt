package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class WatchingOwnerTest {
    @Test fun renewedLoginHasDistinctOwnerAndReleaseKeepsOldReceipt() {
        fun account(receipt: String) = buildJsonObject {
            put("signedIn", true); put("host", "https://EXAMPLE.COM:443/service/")
            put("handle", "alice"); put("accountSession", receipt)
        }
        val old = WatchingOwner.from(account("old"))!!
        val next = WatchingOwner.from(account("next"))!!
        assertNotEquals(old, next)
        assertEquals("old", old.parameters("chat", "watcher")["_accountSession"].toString().trim('"'))
        assertEquals("https://example.com/service", old.scope["origin"].toString().trim('"'))
        assertNull(WatchingOwner.from(buildJsonObject { put("signedIn", false) }))
    }
}
