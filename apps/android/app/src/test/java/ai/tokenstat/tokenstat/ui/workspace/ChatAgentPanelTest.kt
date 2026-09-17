// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The agent, model and effort rows share one panel, one mark per section,
/// and one line of summary. The rules below are what keeps the three from
/// being one long list of names.
class ChatAgentPanelTest {
    private fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    private val backends = listOf(
        obj("""{"id":"muse","label":"Muse","models":["muse-spark-1.3","opus"],"efforts":["max"]}"""),
        obj("""{"id":"codex","label":"Codex","installed":false,"models":["gpt-5.4"],"efforts":[]}"""),
        obj("""{"id":"sh","label":"Shell","gateTier":"bypassOnly","models":[],"efforts":[]}"""),
    )

    private fun chat(backend: String, model: String? = null, effort: String? = null): JsonObject =
        obj(
            """{"backend":"$backend","model":${model?.let { """"$it"""" } ?: "null"},"effort":${effort?.let { """"$it"""" } ?: "null"}}""",
        )

    @Test
    fun `only an explicit false means not installed`() {
        assertTrue(backendNotInstalled(obj("""{"installed":false}""")))
        assertFalse(backendNotInstalled(obj("""{"installed":true}""")))
        assertFalse(backendNotInstalled(obj("""{}""")))
        assertFalse(backendNotInstalled(obj("""{"installed":{"odd":true}}""")))
        assertFalse(backendNotInstalled(null))
    }

    @Test
    fun `agent rows skip uninstalled backends and flag sign-in`() {
        val rows = chatAgentChoices(backends, chat("muse"))
        val agents = rows.filter { it.section == "Agent" }
        assertEquals(listOf("Muse", "Shell"), agents.map { it.label })
        assertEquals(ChatAgentChoice.Agent("muse"), agents[0].value)
    }

    @Test
    fun `model rows lead with the default and pin favourites first`() {
        val rows = chatAgentChoices(backends, chat("muse", model = "opus"), favorites = listOf("opus"))
        val models = rows.filter { it.section == "Model" }
        assertEquals(ChatAgentChoice.Model(""), models[0].value)
        assertEquals("Default", models[0].label)
        assertEquals(listOf("opus", "muse-spark-1.3"), models.drop(1).map { (it.value as ChatAgentChoice.Model).id })
    }

    @Test
    fun `a saved model the host no longer lists stays, marked unverified`() {
        val rows = chatAgentChoices(backends, chat("muse", model = "old-1"))
        val models = rows.filter { it.section == "Model" }
        val saved = models.first { (it.value as? ChatAgentChoice.Model)?.id == "old-1" }
        assertEquals("Saved choice · availability unverified", saved.detail)
    }

    @Test
    fun `effort rows appear only when the agent offers effort`() {
        val withEffort = chatAgentChoices(backends, chat("muse", effort = "max"))
            .filter { it.section == "Effort" }
        assertEquals(listOf("", "max"), withEffort.map { (it.value as ChatAgentChoice.Effort).id })
        val withoutEffort = chatAgentChoices(
            listOf(obj("""{"id":"plain","label":"Plain","models":[],"efforts":[]}""")),
            chat("plain"),
        ).filter { it.section == "Effort" }
        assertTrue(withoutEffort.isEmpty())
    }

    @Test
    fun `an uninstalled current backend offers no model or effort rows`() {
        val rows = chatAgentChoices(backends, chat("codex"))
        assertTrue(rows.none { it.section == "Model" })
        assertTrue(rows.none { it.section == "Effort" })
    }

    @Test
    fun `sections list what the panel holds, in panel order`() {
        val choices = chatAgentChoices(backends, chat("muse"))
        assertEquals(listOf("Agent", "Model", "Effort"), chatAgentSections(choices))
        assertTrue(chatAgentSections(emptyList()).isEmpty())
    }

    @Test
    fun `each heading says what its section is set to`() {
        val current = chat("muse", model = "opus", effort = "max")
        assertEquals("Muse", chatAgentSectionValue("Agent", backends, current))
        assertEquals("opus", chatAgentSectionValue("Model", backends, current))
        assertEquals("max", chatAgentSectionValue("Effort", backends, current))
        assertEquals("Default", chatAgentSectionValue("Model", backends, chat("muse")))
        assertNull(chatAgentSectionValue("Other", backends, current))
    }

    @Test
    fun `each section marks exactly its own setting`() {
        val current = chat("muse", model = "opus")
        assertTrue(chatAgentIsSelected(ChatAgentChoice.Agent("muse"), current))
        assertFalse(chatAgentIsSelected(ChatAgentChoice.Agent("codex"), current))
        assertTrue(chatAgentIsSelected(ChatAgentChoice.Model("opus"), current))
        assertTrue(chatAgentIsSelected(ChatAgentChoice.Model(""), chat("muse")))
        assertTrue(chatAgentIsSelected(ChatAgentChoice.Effort(""), current))
    }

    @Test
    fun `each row writes its own field`() {
        assertEquals("backend" to "muse", chatAgentField(ChatAgentChoice.Agent("muse")))
        assertEquals("model" to "opus", chatAgentField(ChatAgentChoice.Model("opus")))
        assertEquals("effort" to "max", chatAgentField(ChatAgentChoice.Effort("max")))
    }

    @Test
    fun `only a bypass-only agent forces bypass`() {
        assertTrue(chatAgentForcesBypass(backends, "sh"))
        assertFalse(chatAgentForcesBypass(backends, "muse"))
        assertFalse(chatAgentForcesBypass(backends, "gone"))
    }

    @Test
    fun `the summary names the agent and model, and effort only when offered`() {
        assertEquals(
            "Muse · opus · Effort: max",
            chatAgentSummary(backends, chat("muse", model = "opus", effort = "max")),
        )
        assertEquals("Muse · Default · Effort: Default", chatAgentSummary(backends, chat("muse")))
        assertEquals("Agent · Default", chatAgentSummary(backends, null))
    }
}
