// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatActivityDataTest {
    private fun json(value: String) = Json.parseToJsonElement(value).jsonObject
    private val running = json("""{"running":true}""")
    @Test fun missingActivityAndUnreportedFieldsStayUnknown() {
        assertNull(chatActivityData(json("{}"), running))
        val activity = chatActivityData(json("""{"currentRun":true,"activity":{"goalReported":false,"planReported":false,"agentsReported":false,"live":true,"goal":{"objective":"Unreported","tokensUsed":0},"agents":[{"id":"unreported","status":"running"}]}}"""), running)!!
        assertFalse(activity.hasContent)
        assertNull(activity.goal)
        assertTrue(activity.plan.isEmpty())
        assertTrue(activity.agents.isEmpty())
        assertNull(activity.runningAgents)
    }
    @Test fun onlyCurrentLiveOwningRunCanReportRunningAgentCount() {
        val inspection = json("""{"currentRun":true,"activity":{"agentsReported":true,"live":true,"agents":[{"id":"one","status":"running"},{"id":"two","status":"completed"}]}}""")
        assertEquals(1, chatActivityData(inspection, running)!!.runningAgents)
        assertNull(chatActivityData(inspection, json("""{"running":false}"""))!!.runningAgents)
        assertNull(chatActivityData(JsonObject(inspection + ("currentRun" to JsonPrimitive(false))), running)!!.runningAgents)
        val stale = inspection["activity"]!!.jsonObject.let { JsonObject(it + ("live" to JsonPrimitive(false))) }
        val retained = chatActivityData(JsonObject(inspection + ("activity" to stale)), running)!!
        assertNull(retained.runningAgents)
        assertEquals("running", retained.agents.first().status)
        assertEquals("unknown", retained.agents.first().displayStatus(retained.live))
        assertEquals("completed", retained.agents.last().displayStatus(retained.live))
    }
    @Test fun unknownAgentLifecycleDoesNotImplyZeroRunning() {
        val unknown = json("""{"currentRun":true,"activity":{"agentsReported":true,"live":true,"agents":[{"id":"one","status":"unknown"}]}}""")
        assertNull(chatActivityData(unknown, running)!!.runningAgents)
        val completed = json("""{"currentRun":true,"activity":{"agentsReported":true,"live":true,"agents":[{"id":"one","status":"completed"}]}}""")
        assertEquals(0, chatActivityData(completed, running)!!.runningAgents)
    }
    @Test fun budgetsAndStatusesComeOnlyFromValidReportedTelemetry() {
        val activity = chatActivityData(json("""{"activity":{"goalReported":true,"planReported":true,"agentsReported":true,"goal":{"objective":"Ship","status":"usageLimited","tokensUsed":0,"tokenBudget":-1,"timeUsedSeconds":"oops"},"plan":[{"text":"Build","status":"completed"},{"text":"Review","status":"other"}],"agents":[{"id":"worker","status":"other"},{"name":"No ID"}]}}"""), running)!!
        assertEquals("usageLimited", activity.goal!!.status)
        assertEquals(0.0, activity.goal.tokensUsed!!, 0.0)
        assertNull(activity.goal.tokenBudget)
        assertNull(activity.goal.timeUsedSeconds)
        assertEquals(1, activity.completedSteps)
        assertEquals("unknown", activity.plan.last().status)
        assertEquals(1, activity.agents.size)
        assertEquals("unknown", activity.agents.single().status)
        assertFalse(activity.live)
    }
}
