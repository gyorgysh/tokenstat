// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// What a new conversation opens with. Twin of the `createChat` call in
/// `ChatModel.startChat`.
class LaunchChoiceTest {
    private fun backend(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    private val backends = listOf(
        backend("""{"id":"sh","label":"Shell","models":[],"efforts":[]}"""),
        backend("""{"id":"claude","label":"Claude Code","models":["opus"],"efforts":["high"]}"""),
        backend("""{"id":"codex","label":"Codex","models":["gpt-5.4"],"efforts":["low"]}"""),
        backend("""{"id":"muse","label":"Muse","models":["muse-spark-1.3"],"efforts":["max"]}"""),
    )

    private fun choice(
        backend: String = "muse",
        model: String? = null,
        effort: String? = null,
        mode: String = "execute",
        autonomy: String = "bypass",
    ) = LaunchChoice(backend, model, effort, mode, autonomy, personaId = null)

    /// The one the correction was about. The host falls back to plan for a
    /// record that does not say, which is the safe reading of an unknown
    /// conversation. A chat somebody just asked for is not unknown.
    @Test
    fun `a first chat opens in execute, never plan`() {
        assertEquals("execute", LaunchDefaults.mode(null))
        assertEquals("execute", LaunchDefaults.MODE)
    }

    @Test
    fun `the last mode is what the next chat opens in`() {
        assertEquals("plan", LaunchDefaults.mode(choice(mode = "plan")))
        assertEquals("execute", LaunchDefaults.mode(choice(mode = "execute")))
        assertEquals("execute", LaunchDefaults.mode(choice(mode = "")))
    }

    @Test
    fun `the last autonomy is what the next chat opens in`() {
        assertEquals("standard", LaunchDefaults.autonomy(null, bypassOnly = false))
        assertEquals("bypass", LaunchDefaults.autonomy(choice(autonomy = "bypass"), false))
        assertEquals("standard", LaunchDefaults.autonomy(choice(autonomy = "standard"), false))
    }

    /// An agent with no approval protocol of its own runs on Bypass or not at
    /// all, whatever was last used.
    @Test
    fun `a bypass-only agent is put on bypass`() {
        assertEquals("bypass", LaunchDefaults.autonomy(choice(autonomy = "standard"), true))
        assertEquals("bypass", LaunchDefaults.autonomy(null, bypassOnly = true))
    }

    @Test
    fun `the agent last used wins, then codex, and never the shell`() {
        assertEquals("muse", LaunchDefaults.backend(choice(backend = "muse"), backends))
        assertEquals("codex", LaunchDefaults.backend(null, backends))
        assertEquals("codex", LaunchDefaults.backend(choice(backend = "gone"), backends))
        assertEquals(
            "claude",
            LaunchDefaults.backend(null, backends.filter { it["id"].toString().contains("claude") }),
        )
        // A list of nothing but the shell still does not answer the shell.
        assertEquals("claude", LaunchDefaults.backend(null, listOf(backends[0])))
    }

    @Test
    fun `an agent that is not installed is not offered`() {
        val list = listOf(
            backend("""{"id":"codex","installed":false,"models":[],"efforts":[]}"""),
            backend("""{"id":"claude","models":[],"efforts":[]}"""),
        )
        assertEquals("claude", LaunchDefaults.backend(null, list))
    }

    /// The last resort skips uninstalled agents too: answering one the
    /// catalog says is not there is worse than the hardcoded fallback.
    @Test
    fun `the fallback never answers an uninstalled agent`() {
        val list = listOf(
            backend("""{"id":"sh","installed":true}"""),
            backend("""{"id":"codex","installed":false}"""),
        )
        assertEquals("claude", LaunchDefaults.backend(null, list))
    }

    @Test
    fun `a misshapen installed flag does not throw`() {
        val list = listOf(
            backend("""{"id":"codex","installed":{"odd":true}}"""),
        )
        assertEquals("codex", LaunchDefaults.backend(null, list))
    }

    /// A model and an effort belong to the agent that offers them. Carrying
    /// one across is stale setup, not a preference.
    @Test
    fun `a saved model only travels to an agent that offers it`() {
        val muse = backends.first { it["id"].toString().contains("muse") }
        assertEquals(
            "muse-spark-1.3",
            LaunchDefaults.model(choice(model = "muse-spark-1.3"), muse),
        )
        assertNull(LaunchDefaults.model(choice(model = "gpt-5.4"), muse))
        assertNull(LaunchDefaults.model(choice(model = ""), muse))
        assertEquals("max", LaunchDefaults.effort(choice(effort = "max"), muse))
        assertNull(LaunchDefaults.effort(choice(effort = "low"), muse))
    }

    @Test
    fun `a stored choice comes back as it went in`() {
        val store = InMemoryLaunchChoice()
        assertNull(store.read())
        val saved = LaunchChoice("muse", "muse-spark-1.3", "max", "execute", "bypass", "")
        store.write(saved)
        assertEquals(saved, store.read())
    }
}
