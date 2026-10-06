// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.ShortcutManager
import androidx.appsearch.app.SearchSpec
import androidx.appsearch.platformstorage.PlatformStorage
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class SystemIntegrationTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun account(id: String = "system-fixture", revoked: Boolean = false) = buildJsonObject {
        put("signedIn", true); put("host", "https://example.test"); put("accountId", id)
        put("machines", JsonArray(listOf(buildJsonObject {
            put("id", "computer-fixture"); put("publicIdentity", "e".repeat(64)); put("label", "Studio")
            put("trustState", if (revoked) "revoked" else "approved")
        })))
    }
    private fun seed(): SystemProject {
        SystemProjects.clear(context)
        SystemProjects.verify(context, account())
        SystemProjects.replace(context, "e".repeat(64), JsonArray(listOf(buildJsonObject {
            put("id", "project-fixture"); put("name", "Searchable Project"); put("exists", true)
        })), SystemProjects.owner)
        return SystemProjects.search("").single()
    }
    @After fun cleanup() = runBlocking { SystemProjects.clear(context); SystemProjects.flush() }

    @Test fun projectLinksAreBoundToTheirAccountAndRevocable() {
        val project = seed()
        QuickAccess.offer(SystemProjects.openIntent(context, project))
        val request = QuickAccess.request.value!!
        assertEquals(project, SystemProjects.find(request.projectId!!, request.owner))
        QuickAccess.take(request)
        SystemProjects.verify(context, account(revoked = true))
        assertNull(SystemProjects.find(project.id, project.owner))
        SystemProjects.verify(context, account("other-fixture"))
        assertTrue(SystemProjects.search("").isEmpty())
    }
    @Test fun catalogBoundsAndMachineRenamesAreAppliedBeforePublication() {
        val project = seed()
        SystemProjects.replace(context, project.peer, JsonArray(listOf(buildJsonObject {
            put("id", "x".repeat(257)); put("name", "Oversized id")
        })), project.owner)
        assertTrue(SystemProjects.search("").isEmpty())
        SystemProjects.replace(context, project.peer, JsonArray(listOf(buildJsonObject {
            put("id", project.workspaceId); put("name", project.name)
        })), project.owner)
        val renamed = account().toMutableMap()
        renamed["machines"] = JsonArray(listOf(buildJsonObject {
            put("id", project.hostId); put("publicIdentity", project.peer); put("label", "Renamed computer")
        }))
        SystemProjects.verify(context, JsonObject(renamed))
        assertEquals("Renamed computer", SystemProjects.find(project.id)!!.hostName)
    }
    @Test fun genericSharesDoNotCrossAccountSwitches() {
        val project = seed()
        SystemShare.offer(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "A private draft") })
        assertEquals(project.owner, SystemShare.draft.value!!.owner)
        SystemProjects.verify(context, account("other-fixture"))
        assertNull(SystemShare.draft.value)
    }
    @Test fun delayedCatalogResponsesCannotRepopulateAnotherAccount() {
        val project = seed()
        SystemProjects.verify(context, account("other-fixture"))
        SystemProjects.replace(context, "e".repeat(64), JsonArray(listOf(buildJsonObject {
            put("id", "old-project"); put("name", "Old account content")
        })), project.owner)
        assertTrue(SystemProjects.search("").isEmpty())
    }
    @Test fun directShareRemainsDraftAndCanOnlyBeConsumedOnce() {
        val project = seed()
        QuickAccess.offer(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "A shared response")
            putExtra(Intent.EXTRA_SHORTCUT_ID, "project.${project.id}")
        })
        val request = QuickAccess.request.value!!
        assertEquals(project.id, request.projectId)
        QuickAccess.take(request)
        val draft = SystemShare.draft.value!!
        assertEquals(project.owner, draft.owner)
        assertTrue(SystemShare.take(draft)); assertFalse(SystemShare.take(draft))
        assertNull(SystemShare.draft.value)
    }
    @Test fun coldDirectShareResolvesAfterAccountVerification() {
        val project = seed()
        SystemProjects.clear(context)
        assertEquals("project.${project.id}", SystemShare.offer(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "Cold draft")
            putExtra(Intent.EXTRA_SHORTCUT_ID, "project.${project.id}")
        }))
        assertNull(SystemShare.draft.value!!.owner)
        SystemProjects.verify(context, account())
        SystemProjects.replace(context, "e".repeat(64), JsonArray(listOf(buildJsonObject {
            put("id", project.workspaceId); put("name", project.name)
        })), SystemProjects.owner)
        assertNotNull(SystemProjects.find(SystemShare.draft.value!!.projectId!!))
        SystemProjects.clear(context)
        assertNull(SystemShare.draft.value)
    }
    @Test fun aFullComposerKeepsSharedTextUntilItCanBeStored() {
        seed()
        val composers = ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions<String>(attachmentCost = { 0L })
        assertTrue(composers.update("conversation", composers.snapshot("conversation").copy(text = "x".repeat(128 * 1024))))
        SystemShare.offer(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "Keep this shared text") })
        val shared = SystemShare.draft.value!!
        fun store(text: String): Boolean {
            val current = composers.snapshot("conversation")
            return composers.update("conversation", current.copy(text = current.text + text))
        }
        assertFalse(SystemShare.consume(shared, ::store))
        assertEquals(shared, SystemShare.draft.value)
        assertEquals(128 * 1024, composers.snapshot("conversation").text.length)
        assertNotNull(composers.failure.value)
        assertTrue(composers.update("conversation", composers.snapshot("conversation").copy(text = "")))
        assertTrue(SystemShare.consume(shared, ::store))
        assertEquals(shared.text, composers.snapshot("conversation").text)
        assertNull(SystemShare.draft.value)
        assertFalse(SystemShare.consume(shared, ::store))
    }
    @Test fun unsupportedOrOversizedSharesAreIgnored() {
        seed()
        assertNull(SystemShare.offer(Intent(Intent.ACTION_SEND).apply { type = "image/png"; putExtra(Intent.EXTRA_TEXT, "text") }))
        assertNull(SystemShare.offer(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "x".repeat(100_001)) }))
        assertNull(SystemShare.offer(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "text"); putExtra(Intent.EXTRA_SHORTCUT_ID, "foreign.shortcut")
        }))
        assertNull(SystemShare.draft.value)
    }
    @Test fun deniedShortcutServiceDoesNotPreventProjectAccess() {
        val project = seed()
        val restricted = object : ContextWrapper(context) {
            override fun getSystemService(name: String): Any? = if (name == Context.SHORTCUT_SERVICE) throw SecurityException("Restricted device") else super.getSystemService(name)
        }
        assertFalse(SystemProjects.pin(restricted, project.id))
        assertEquals(project, SystemProjects.find(project.id))
    }
    @Test fun appSearchAndShortcutMetadataAreRemovedOnSignOut() = runBlocking {
        val project = seed(); SystemProjects.flush()
        val session = PlatformStorage.createSearchSessionAsync(PlatformStorage.SearchContext.Builder(context, "tokenstat-projects").build()).get(10, TimeUnit.SECONDS)
        try {
            fun results(): List<androidx.appsearch.app.SearchResult> {
                val search = session.search("Searchable", SearchSpec.Builder().setTermMatch(SearchSpec.TERM_MATCH_PREFIX).build())
                return try { search.getNextPageAsync().get(10, TimeUnit.SECONDS) } finally { search.close() }
            }
            assertEquals(project.id, results().single().genericDocument.id)
            SystemProjects.clear(context); SystemProjects.flush()
            assertTrue(results().isEmpty())
            val manager = context.getSystemService(ShortcutManager::class.java)
            assertTrue(manager.dynamicShortcuts.none { it.id.startsWith("project.") })
            assertTrue(manager.pinnedShortcuts.filter { it.id.startsWith("project.") }.all { !it.isEnabled })
        } finally { session.close() }
    }
}
