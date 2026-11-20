// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Test

class GeneralFolderTest {
    private fun folder(id: String, general: Boolean = false) = JsonObject(buildMap {
        put("id", JsonPrimitive(id))
        put("name", JsonPrimitive(id))
        if (general) put("general", JsonPrimitive(true))
    })

    private fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull

    @Test
    fun `the general folder is named and listed first`() {
        val listed = JsonArray(listOf(folder("a"), folder("g", general = true), folder("b")))
        val rows = GeneralFolder.present(listed, "No repository").map { it as JsonObject }
        assertEquals(listOf("g", "a", "b"), rows.map { it.text("id") })
        assertEquals("No repository", rows.first().text("name"))
        assertEquals("b", rows.last().text("name"))
    }

    @Test
    fun `an older host's list is unchanged and project lists leave it out`() {
        val listed = JsonArray(listOf(folder("a"), folder("b")))
        assertEquals(listed, GeneralFolder.present(listed, "No repository"))
        val projects = GeneralFolder.projects(listOf(folder("g", general = true), folder("a")))
        assertEquals(listOf("a"), projects.map { it.text("id") })
    }
}
