// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TeamInboxModelTest {
    private fun account() = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "self"); put("accountId", "self"); put("accountSession", "fixture-session") }
    private fun preview(id: String, eligible: Boolean = true, available: Boolean = true) = buildJsonObject {
        put("invitation", buildJsonObject { put("id", id); put("organizationId", "org-fixture"); put("organizationName", "Fictional team"); put("role", "member"); put("state", "pending") })
        put("eligible", eligible); put("available", available)
        put("repositoryAccess", JsonArray(listOf(buildJsonObject { put("repositoryId", "repo-fixture"); put("name", "Reviewed project"); put("role", "contributor") })))
    }
    @Test fun acceptanceIsExplicitAndCannotNavigateToAnotherTeamReply() = runTest {
        val seen = mutableListOf<JsonObject>(); var eligible = false; var wrong = true
        val calls = TeamCalls(account()) { _, body ->
            seen += body
            when (body.teamString("operation")) {
                "inbox.get" -> preview("invitation-fixture", eligible)
                "inbox.accept" -> buildJsonObject { put("joined", true); put("organizationId", if (wrong) "wrong-team" else "org-fixture") }
                "organizations.get" -> buildJsonObject { put("organization", buildJsonObject { put("id", "org-fixture") }) }
                else -> error("Unexpected fixture request")
            }
        }
        val model = TeamInboxModel(calls)
        model.review("invitation-fixture"); assertFalse(model.canJoin); assertNull(model.accept())
        assertEquals(1, seen.size)
        eligible = true; model.review("invitation-fixture"); assertTrue(model.canJoin)
        assertNull(model.accept()); assertFalse(seen.any { it.teamString("operation") == "organizations.get" })
        wrong = false
        assertEquals("org-fixture", model.accept()!!.teamString("id"))
        val join = seen.first { it.teamString("operation") == "inbox.accept" }
        assertEquals("invitation-fixture", join.teamString("invitation")); assertFalse(join.containsKey("page"))
        assertEquals("fixture-session", join.teamString("_accountSession"))
    }
    @Test fun staleOrWithdrawnPreviewsCannotEnableJoin() = runTest {
        var answer = preview("wrong-invitation")
        val calls = TeamCalls(account()) { _, _ -> answer }
        val model = TeamInboxModel(calls)
        model.review("invitation-fixture"); assertNull(model.preview); assertFalse(model.canJoin)
        answer = preview("invitation-fixture", available = false)
        model.review("invitation-fixture"); assertFalse(model.canJoin)
        model.close(); assertNull(model.selected); assertNull(model.preview)
    }
    @Test fun latePreviewCannotReplaceALaterSelection() = runTest {
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val calls = TeamCalls(account()) { _, body ->
            val id = body.teamString("invitation")!!
            if (id == "first") withContext(NonCancellable) { started.complete(Unit); release.await(); preview(id) } else preview(id)
        }
        val model = TeamInboxModel(calls)
        val old = launch { model.review("first") }; started.await()
        model.review("second"); release.complete(Unit); old.join()
        assertEquals("second", model.selected); assertEquals("second", model.preview!!["invitation"]!!.jsonObject.teamString("id"))
    }
}
