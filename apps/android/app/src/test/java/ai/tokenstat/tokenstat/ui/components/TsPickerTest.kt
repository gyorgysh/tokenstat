// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The panel over a forty-model list: word-wise matching, first-seen
/// sections, and a Done key that takes what was typed rather than what the
/// typing happens to substring-match.
class TsPickerTest {
    private fun choice(label: String, section: String = "", detail: String? = null) =
        PickerChoice(label, label, detail, section)

    @Test
    fun `every word of the query has to land somewhere in the row`() {
        val row = choice("meta/muse-spark-1.3")
        assertTrue(row.matches("meta 1.3"))
        assertTrue(row.matches("SPARK meta"))
        assertFalse(row.matches("meta 2.0"))
        assertTrue(choice("anything").matches(""))
        assertTrue(choice("anything").matches("   "))
    }

    @Test
    fun `detail and section lines are searchable too`() {
        val row = choice("Default", section = "Model", detail = "Muse picks the model")
        assertTrue(row.matches("picks"))
        assertTrue(row.matches("model"))
        assertFalse(row.matches("effort"))
    }

    @Test
    fun `sections keep first-seen order, never alphabetical`() {
        val choices = listOf(
            choice("max", section = "Effort"),
            choice("Muse", section = "Agent"),
            choice("opus", section = "Model"),
            choice("Codex", section = "Agent"),
        )
        val sections = pickerSections(choices)
        assertEquals(listOf("Effort", "Agent", "Model"), sections.map { it.first })
        assertEquals(listOf("Muse", "Codex"), sections[1].second.map { it.label })
    }

    @Test
    fun `the filter combines the query with the section tab`() {
        val choices = listOf(
            choice("Muse", section = "Agent"),
            choice("muse-spark-1.3", section = "Model"),
            choice("opus", section = "Model"),
        )
        assertEquals(3, pickerFiltered(choices, "", "").size)
        assertEquals(
            listOf("muse-spark-1.3"),
            pickerFiltered(choices, "muse", "Model").map { it.label },
        )
        assertEquals(
            listOf("Muse", "muse-spark-1.3"),
            pickerFiltered(choices, "muse", "").map { it.label },
        )
        assertTrue(pickerFiltered(choices, "nothing", "").isEmpty())
    }

    @Test
    fun `done takes an exact label match first`() {
        val choices = listOf(
            choice("Codex", section = "Agent"),
            choice("codex-mini", section = "Model"),
        )
        assertEquals("Codex", pickerSubmitTarget(choices, "codex", ""))
        assertEquals("codex-mini", pickerSubmitTarget(choices, "codex-mini", ""))
    }

    /// The combined panel's Agent rows shadow model ids: typing "codex" must
    /// not select the agent when a model matches too.
    @Test
    fun `done prefers a non-agent row when no section is picked`() {
        val choices = listOf(
            choice("Codex", section = "Agent"),
            choice("gpt-5.4-codex", section = "Model"),
        )
        assertEquals("gpt-5.4-codex", pickerSubmitTarget(choices, "code", ""))
    }

    @Test
    fun `done stays inside the picked section`() {
        val choices = listOf(
            choice("Codex", section = "Agent"),
            choice("gpt-5.4-codex", section = "Model"),
        )
        assertEquals("Codex", pickerSubmitTarget(choices, "codex", "Agent"))
    }

    @Test
    fun `done with no match takes nothing`() {
        assertNull(pickerSubmitTarget(listOf(choice("Muse", section = "Agent")), "nothing", ""))
        assertNull(pickerSubmitTarget(emptyList(), "", ""))
    }
}
