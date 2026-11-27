// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.account

import ai.tokenstat.tokenstat.ui.logic.AccountIdentityPins
import ai.tokenstat.tokenstat.ui.logic.WatchingOwner
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HandleRulesTest {
    private class Memory(var pins: Map<String, String> = emptyMap()) : AccountIdentityPins.Store {
        override fun read() = pins
        override fun write(pins: Map<String, String>) { this.pins = pins }
    }

    @After fun plainRule() = AccountIdentityPins.activate(null)

    @Test
    fun readsTheHandleSomebodyMeant() {
        mapOf(
            "Gyorgy" to "gyorgy", "  @Gyorgy " to "gyorgy", "my name" to "my-name",
            "https://tokenstat.ai/gyorgy?ref=1" to "gyorgy", "tokenstat.ai/gyorgy/models" to "gyorgy",
            "/gyorgy" to "gyorgy", "   " to "", "a".repeat(40) to "a".repeat(32),
        ).forEach { (typed, meant) -> assertEquals(meant, HandleRules.normalized(typed)) }
    }

    @Test
    fun refusesOnSightWhatTheServerWould() {
        mapOf(
            "abc" to "too_short", "a".repeat(33) to "too_long", "na_me" to "invalid_characters",
            "-name" to "invalid_characters", "name-" to "invalid_characters", "névjegy" to "invalid_characters",
            "na--me" to "double_dash", "123456" to "numeric_only",
        ).forEach { (handle, reason) -> assertEquals(handle, reason, HandleRules.localReason(handle)) }
        listOf("gyorgy", "name", "na-me", "4you", "a".repeat(32)).forEach { assertNull(HandleRules.localReason(it)) }
        assertEquals("In 3 days.", HandleRules.message("cooloff", "In 3 days."))
        assertEquals("tokenstat.ai/gyorgy", HandleRules.address("https://tokenstat.ai/", "gyorgy"))
    }

    @Test
    fun profileComesFromTheAccountOrNotAtAll() {
        fun profile(raw: String) = AccountProfile.from(Json.parseToJsonElement(raw).jsonObject)
        assertNull(profile("""{"signedIn":false,"profile":{"public":true}}"""))
        val old = profile("""{"signedIn":true,"host":"https://h","handle":"name","profilePublic":true}""")!!
        assertTrue(old.isPublic && old.visible)
        assertNull(old.settings)
        assertFalse(profile("""{"signedIn":true,"host":"https://h"}""")!!.visible)
        val fresh = profile("""{"signedIn":true,"host":"https://h","handle":null,"profile":{"public":false,"indexable":false,"handleChangeDays":3,"handlePrompted":false}}""")!!
        assertEquals(AccountProfile.Settings(indexable = false, changeDays = 3, prompted = false), fresh.settings)
        assertNull(fresh.handle)
        assertTrue(profile("""{"signedIn":true,"profile":{"public":true}}""")!!.settings!!.prompted)
    }

    @Test
    fun localWorkStaysPutThroughClaimsAndRenames() {
        assertEquals("alice", AccountIdentityPins.identity(" alice ", "acc_a"))
        assertEquals("acc_a", AccountIdentityPins.identity(null, "acc_a"))

        val store = Memory()
        AccountIdentityPins.activate(store)
        assertEquals("acc_new", AccountIdentityPins.identity(null, "acc_new"))
        assertEquals("acc_new", AccountIdentityPins.identity("newname", "acc_new"))
        assertEquals("alice", AccountIdentityPins.identity("alice", "acc_a"))
        AccountIdentityPins.activate(Memory(store.pins))
        assertEquals("alice", AccountIdentityPins.identity("alicia", "acc_a"))
        assertEquals("acc_b", AccountIdentityPins.identity("alice", "acc_b"))
        assertEquals("bob", AccountIdentityPins.identity("bob", null))
        assertNull(AccountIdentityPins.identity(" ", ""))

        val account = Json.parseToJsonElement("""{"signedIn":true,"host":"https://h","handle":"alicia","accountId":"acc_a"}""").jsonObject
        assertEquals("acc_a", WatchingOwner.from(account)!!.scope["identity"]!!.jsonPrimitive.content)
    }
}
