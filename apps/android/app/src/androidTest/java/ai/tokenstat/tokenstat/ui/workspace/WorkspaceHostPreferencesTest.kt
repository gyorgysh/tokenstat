// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WorkspaceHostPreferencesTest {
    @Test fun reconnectChoiceBelongsToTheAccountAndSurvivesRecreation() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val testName = "workspace-host-test-" + UUID.randomUUID()
        val context = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                base.getSharedPreferences(testName, Context.MODE_PRIVATE)
        }
        try {
            val legacy = context.getSharedPreferences("tokenstat.workspaces.v1", Context.MODE_PRIVATE)
            legacy.edit().putString("lastConnectedHost", "peer-one")
                .putBoolean("autoConnect.peer-one", false).commit()

            val first = WorkspaceLayoutStore(context, "account-one")
            first.migrateLegacyHost(setOf("peer-one"))
            assertEquals("peer-one", first.lastConnectedHost())
            assertFalse(first.isAutoConnectEnabled("peer-one"))
            assertFalse(legacy.contains("lastConnectedHost"))

            val second = WorkspaceLayoutStore(context, "account-two")
            second.migrateLegacyHost(setOf("peer-one"))
            assertNull(second.lastConnectedHost())
            assertTrue(second.isAutoConnectEnabled("peer-one"))
            second.setLastConnectedHost("peer-two")
            second.setAutoConnectEnabled("peer-two", false)
            first.setAutoConnectEnabled("peer-one", true)
            first.setLastConnectedHost("peer-three")

            assertEquals("peer-three", WorkspaceLayoutStore(context, "account-one").lastConnectedHost())
            assertTrue(WorkspaceLayoutStore(context, "account-one").isAutoConnectEnabled("peer-one"))
            assertEquals(listOf("peer-three", "peer-one"),
                WorkspaceLayoutStore(context, "account-one").rememberedHosts(setOf("peer-one", "peer-three")))
            assertEquals(listOf("peer-one"),
                WorkspaceLayoutStore(context, "account-one").rememberedHosts(setOf("peer-one")))
            assertEquals("peer-two", WorkspaceLayoutStore(context, "account-two").lastConnectedHost())
            assertFalse(WorkspaceLayoutStore(context, "account-two").isAutoConnectEnabled("peer-two"))
            assertEquals(listOf("peer-two"),
                WorkspaceLayoutStore(context, "account-two").rememberedHosts(setOf("peer-one", "peer-two", "peer-three")))
            assertNull(WorkspaceLayoutStore(context, "").lastConnectedHost())
            assertFalse(WorkspaceLayoutStore(context, "").isAutoConnectEnabled("peer-one"))
            assertTrue(WorkspaceLayoutStore(context, "").rememberedHosts(setOf("peer-one")).isEmpty())
        } finally {
            base.deleteSharedPreferences(testName)
        }
    }
}
