// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/// The shared host-JSON readers must be total: the host answers with
/// arrays and objects where older answers carried strings (pull detail
/// `checks` arrived as an array and crashed the pulls page), and a reader
/// that throws on those is a crash on any screen that uses it.
class JsonReadersTest {
    private val obj = buildJsonObject {
        put("name", "tokenstat")
        put("count", 42L)
        put("open", true)
        put("nothing", JsonNull)
        putJsonArray("checks") { add(JsonPrimitive("ci")) }
        putJsonObject("owner") { put("login", "octo") }
    }

    @Test
    fun strReadsPrimitivesAndIgnoresStructure() {
        assertEquals("tokenstat", obj.str("name"))
        assertEquals("42", obj.str("count"))
        assertEquals("true", obj.str("open"))
        assertNull(obj.str("missing"))
        assertNull(obj.str("nothing"))
        assertNull(obj.str("checks"))
        assertNull(obj.str("owner"))
    }

    @Test
    fun bolReadsBooleansAndIgnoresStructure() {
        assertEquals(true, obj.bol("open"))
        assertFalse(obj.bol("name"))
        assertFalse(obj.bol("missing"))
        assertFalse(obj.bol("checks"))
        assertFalse(obj.bol("owner"))
    }

    @Test
    fun longReadsNumbersAndIgnoresStructure() {
        assertEquals(42L, obj.long("count"))
        assertNull(obj.long("name"))
        assertNull(obj.long("missing"))
        assertNull(obj.long("checks"))
        assertNull(obj.long("owner"))
    }

    @Test
    fun arraysOfObjectsFilterCleanly() {
        val arr = buildJsonArray {
            add(buildJsonObject { put("a", 1) })
            add(JsonPrimitive("nope"))
        }
        assertEquals(1, asObjects(arr).size)
        assertEquals(0, asObjects(null).size)
    }
}
