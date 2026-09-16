// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakePrefs(
    var order: List<String>? = null,
    var hidden: Set<String> = emptySet(),
) : TabPrefs {
    override fun loadOrder(): List<String>? = order
    override fun loadHidden(): Set<String> = hidden
    override fun save(order: List<String>, hidden: Set<String>) {
        this.order = order
        this.hidden = hidden
    }
}

/// The tab policy, ported with the regression suite iOS keeps beside it: a
/// hidden tab appears while selected, the last visible tab refuses to hide,
/// and tabs from later builds join at the end.
class TabCustomizationTest {
    private val all = listOf("home", "workspaces", "insights", "machines", "ssh")

    @Test
    fun freshPhoneHidesSsh() {
        val customization = TabCustomization(FakePrefs(), all, setOf("ssh"))
        assertEquals(listOf("home", "workspaces", "insights", "machines"), customization.visibleTabs)
    }

    @Test
    fun freshTabletShowsSsh() {
        val customization = TabCustomization(FakePrefs(), all, emptySet())
        assertEquals(all, customization.visibleTabs)
    }

    @Test
    fun hiddenSelectedTabJoinsTemporarilyInOrder() {
        val customization = TabCustomization(FakePrefs(), all, setOf("ssh"))
        assertEquals(all, customization.displayed("ssh"))
        // Without touching the preference: it is still hidden afterwards.
        assertEquals(setOf("ssh"), customization.hidden)
        assertEquals(
            listOf("home", "workspaces", "insights", "machines"),
            customization.displayed("home"),
        )
    }

    @Test
    fun lastVisibleTabRefusesToHide() {
        val prefs = FakePrefs()
        val customization = TabCustomization(prefs, all, emptySet())
        assertTrue(customization.setVisible(false, "ssh"))
        assertTrue(customization.setVisible(false, "insights"))
        assertTrue(customization.setVisible(false, "machines"))
        assertTrue(customization.setVisible(false, "workspaces"))
        assertFalse(customization.setVisible(false, "home"))
        assertEquals(listOf("home"), customization.visibleTabs)
    }

    @Test
    fun moveReordersAndPersists() {
        val prefs = FakePrefs()
        val customization = TabCustomization(prefs, all, setOf("ssh"))
        customization.move(0, 2)
        assertEquals(listOf("workspaces", "insights", "home", "machines", "ssh"), customization.order)
        assertEquals(customization.order, prefs.order)
    }

    @Test
    fun laterTabsJoinAtTheEndAndUnknownStoredOnesDrop() {
        val prefs = FakePrefs(order = listOf("insights", "home", "teleport"))
        val customization = TabCustomization(prefs, all, emptySet())
        assertEquals(
            listOf("insights", "home", "workspaces", "machines", "ssh"),
            customization.order,
        )
    }

    @Test
    fun resetRestoresDefaults() {
        val prefs = FakePrefs()
        val customization = TabCustomization(prefs, all, setOf("ssh"))
        customization.move(0, 4)
        customization.setVisible(true, "ssh")
        customization.reset()
        assertEquals(all, customization.order)
        assertEquals(setOf("ssh"), customization.hidden)
    }

    @Test
    fun summaryReadsLikeIos() {
        assertEquals("Home", tabSummary(emptyList()))
        assertEquals("Home, SSH", tabSummary(listOf("Home", "SSH")))
        assertEquals("Home, Workspaces and 3 more", tabSummary(listOf("Home", "Workspaces", "Insights", "Devices", "SSH")))
    }
}
