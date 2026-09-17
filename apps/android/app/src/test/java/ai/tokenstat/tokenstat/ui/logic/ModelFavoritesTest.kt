// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// The four models somebody actually uses belong above the forty they do
/// not. Pin order is use order, and the rest stay as the host listed them.
class ModelFavoritesTest {
    @Test
    fun `pinned models come first in pin order`() {
        assertEquals(
            listOf("b", "a", "c"),
            favoriteOrderedModels(listOf("a", "b", "c"), listOf("b")),
        )
        assertEquals(
            listOf("c", "a", "b"),
            favoriteOrderedModels(listOf("a", "b", "c"), listOf("c", "a")),
        )
    }

    @Test
    fun `pins the host no longer lists are ignored, not shown`() {
        assertEquals(
            listOf("a", "b"),
            favoriteOrderedModels(listOf("a", "b"), listOf("gone", "a")),
        )
        assertEquals(
            listOf("a", "b"),
            favoriteOrderedModels(listOf("a", "b"), emptyList()),
        )
    }

    @Test
    fun `toggling pins to the front and unpins on the second tap`() {
        val store = InMemoryModelFavorites()
        store.toggle("muse", "b")
        store.toggle("muse", "a")
        assertEquals(listOf("a", "b"), store.ids("muse"))
        assertTrue(store.contains("muse", "a"))
        store.toggle("muse", "a")
        assertEquals(listOf("b"), store.ids("muse"))
        assertFalse(store.contains("muse", "a"))
    }

    @Test
    fun `blank models and backends are never stored`() {
        val store = InMemoryModelFavorites()
        store.toggle("muse", "  ")
        store.toggle("", "a")
        assertTrue(store.ids("muse").isEmpty())
        assertTrue(store.ids("").isEmpty())
        assertFalse(store.contains("muse", ""))
    }

    @Test
    fun `one backend cannot disturb another's list`() {
        val store = InMemoryModelFavorites()
        store.toggle("muse", "a")
        store.toggle("codex", "b")
        assertEquals(listOf("a"), store.ids("muse"))
        assertEquals(listOf("b"), store.ids("codex"))
        store.toggle("muse", "a")
        assertTrue(store.ids("muse").isEmpty())
        assertEquals(listOf("b"), store.ids("codex"))
    }
}
