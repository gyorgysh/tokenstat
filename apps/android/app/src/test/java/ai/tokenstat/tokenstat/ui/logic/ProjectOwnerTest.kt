// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProjectOwnerTest {
    private fun account(host: String = "https://example.test", handle: String? = "ada", id: String? = "account-1", signedIn: Boolean = true) =
        buildJsonObject {
            put("signedIn", signedIn)
            put("host", host)
            put("handle", handle?.let(::JsonPrimitive) ?: JsonNull)
            put("accountId", id?.let(::JsonPrimitive) ?: JsonNull)
        }

    @Test
    fun `owner requires an authenticated account and stable complete context`() {
        assertNull(ProjectOwner.from(null, "peer", "folder"))
        assertNull(ProjectOwner.from(account(signedIn = false), "peer", "folder"))
        assertNull(ProjectOwner.from(account(host = ""), "peer", "folder"))
        assertNull(ProjectOwner.from(account(handle = null, id = null), "peer", "folder"))
        assertNull(ProjectOwner.from(account(), "", "folder"))
        assertNull(ProjectOwner.from(account(), "peer", ""))
        assertNull(ProjectOwner.from(account(), "peer", "folder\nother"))
    }

    @Test
    fun `each account origin identity host and project gets its own owner`() {
        val owner = ProjectOwner.from(account(), "peer", "folder")
        assertNotEquals(owner, ProjectOwner.from(account(host = "https://other.test"), "peer", "folder"))
        assertNotEquals(owner, ProjectOwner.from(account(handle = "grace"), "peer", "folder"))
        assertNotEquals(owner, ProjectOwner.from(account(), "other-peer", "folder"))
        assertNotEquals(owner, ProjectOwner.from(account(), "peer", "other-folder"))
        assertEquals(owner, ProjectOwner.from(account(id = "updated-id"), "PEER", "folder"))
        assertEquals(ProjectOwner.from(account(handle = " "), "peer", "folder"), ProjectOwner.from(account(handle = null), "peer", "folder"))
    }

    @Test
    fun `segments and item namespaces cannot collide`() {
        val first = ProjectOwner.from(account(handle = "a|1:b"), "c", "folder")!!
        val second = ProjectOwner.from(account(handle = "a"), "b|1:c", "folder")!!
        assertNotEquals(first, second)
        assertNotEquals(first.conversation("item"), first.terminal("item"))
        assertNotEquals(first.conversation("a|1:b"), first.conversation("a|1:b|"))
        assertNull(first.conversation(""))
        assertNull(first.terminal("bad\nname"))
    }

    @Test
    fun `account origins are canonical while distinct service paths stay separate`() {
        val owner = ProjectOwner.from(account(host = "HTTPS://EXAMPLE.TEST:443/service///?x=1#here"), "peer", "folder")
        assertEquals(owner, ProjectOwner.from(account(host = "https://example.test/service"), "peer", "folder"))
        assertNotEquals(owner, ProjectOwner.from(account(host = "https://example.test/other"), "peer", "folder"))
        assertNull(ProjectOwner.from(account(host = "https://user@example.test/"), "peer", "folder"))
        assertNull(ProjectOwner.from(account(host = "example.test"), "peer", "folder"))
    }

    @Test
    fun `listener account scope is shared across projects but separate across accounts and services`() {
        val owner = ProjectOwner.from(account(), "peer", "folder")!!
        val anotherProject = ProjectOwner.from(account(), "other-peer", "other-folder")!!
        assertEquals(owner.accountScope, anotherProject.accountScope)
        assertNotEquals(owner.key, anotherProject.key)
        assertNotEquals(owner.accountScope, ProjectOwner.from(account(handle = "grace"), "peer", "folder")!!.accountScope)
        assertNotEquals(owner.accountScope, ProjectOwner.from(account(host = "https://other.test"), "peer", "folder")!!.accountScope)
    }
}
