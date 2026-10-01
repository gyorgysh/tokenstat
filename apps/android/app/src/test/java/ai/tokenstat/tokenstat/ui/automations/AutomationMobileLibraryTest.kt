// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations
import org.junit.Assert.*
import org.junit.Test

class AutomationMobileLibraryTest {
    @Test fun templatesKeepExactScheduleBudgetAndProject() {
        val jobs = AutomationTemplates.suggested
        assertEquals(5, jobs.size)
        assertEquals(jobs.size, jobs.map { it.id }.toSet().size)
        jobs.forEach { template ->
            val draft = template.draft("chosen-project")
            assertEquals("chosen-project", draft.workspaceID)
            assertEquals(template.title, draft.name)
            assertEquals(template.prompt, draft.prompt)
            assertEquals(template.schedule, draft.schedule.builtSchedule)
            assertEquals(template.budgetSeconds, draft.budget.budgetSeconds)
        }
    }
    @Test fun dateSortPutsMissingDatesLastAndTiesUseStableIdentity() {
        val rows = listOf(
            AutomationJob(id = "z", name = "same", nextRunAtMs = null, lastRunAtMs = null),
            AutomationJob(id = "b", name = "same", nextRunAtMs = Long.MAX_VALUE, lastRunAtMs = Long.MIN_VALUE),
            AutomationJob(id = "a", name = "same", nextRunAtMs = Long.MAX_VALUE, lastRunAtMs = Long.MAX_VALUE),
        )
        assertEquals(listOf("a", "b", "z"), AutomationMobileOrder.NEXT_RUN.sorted(rows).map { it.id })
        assertEquals(listOf("a", "b", "z"), AutomationMobileOrder.LAST_RUN.sorted(rows).map { it.id })
    }
}
