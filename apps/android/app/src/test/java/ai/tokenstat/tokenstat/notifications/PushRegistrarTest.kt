// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import android.content.SharedPreferences
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import ai.tokenstat.tokenstat.core.CoreClient
import kotlinx.serialization.json.buildJsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushRegistrarTest {
    /// A SharedPreferences over a map. The core and FCM are absent in unit
    /// tests, so every account call here fails: that is the offline path,
    /// which is exactly what these tests are about.
    private class FakePrefs : SharedPreferences {
        val map = mutableMapOf<String, Any?>()

        private inner class FakeEditor : SharedPreferences.Editor {
            private val writes = mutableMapOf<String, Any?>()
            private val removals = mutableSetOf<String>()
            private var cleared = false

            override fun putString(key: String?, value: String?) = apply { writes[key!!] = value }
            override fun putStringSet(key: String?, values: MutableSet<String>?) = apply { writes[key!!] = values }
            override fun putInt(key: String?, value: Int) = apply { writes[key!!] = value }
            override fun putLong(key: String?, value: Long) = apply { writes[key!!] = value }
            override fun putFloat(key: String?, value: Float) = apply { writes[key!!] = value }
            override fun putBoolean(key: String?, value: Boolean) = apply { writes[key!!] = value }
            override fun remove(key: String?) = apply { removals.add(key!!) }
            override fun clear() = apply { cleared = true }
            override fun commit(): Boolean {
                apply()
                return true
            }

            override fun apply() {
                if (cleared) {
                    map.clear()
                    cleared = false
                }
                removals.forEach { map.remove(it) }
                removals.clear()
                map.putAll(writes)
                writes.clear()
            }
        }

        override fun getAll(): MutableMap<String, *> = map
        override fun getString(key: String?, defValue: String?) = map[key] as? String ?: defValue
        override fun getStringSet(key: String?, defValues: MutableSet<String>?) =
            @Suppress("UNCHECKED_CAST") (map[key] as? MutableSet<String> ?: defValues)
        override fun getInt(key: String?, defValue: Int) = map[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long) = map[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float) = map[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean) = map[key] as? Boolean ?: defValue
        override fun contains(key: String?) = map.containsKey(key)
        override fun edit(): SharedPreferences.Editor = FakeEditor()
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    }

    private val prefs = FakePrefs()

    @After
    fun tearDown() {
        PushRegistrar.prefsOverride = null
        PushRegistrar.call = { method, params -> CoreClient.call(method, params) }
    }

    @Test
    fun `sign-out keeps the switch so signing back in re-registers`() = runTest {
        PushRegistrar.prefsOverride = prefs
        PushRegistrar.enable()
        PushRegistrar.persist("fcm-token")
        assertTrue(PushRegistrar.isOn())

        PushRegistrar.unregister()

        assertTrue("the switch must survive sign-out, like the Apple client's", PushRegistrar.isOn())
        assertTrue(PushRegistrar.registered())
    }

    @Test
    fun `the toggle still turns the switch off`() = runTest {
        PushRegistrar.prefsOverride = prefs
        PushRegistrar.enable()
        PushRegistrar.persist("fcm-token")

        PushRegistrar.disable()

        assertFalse(PushRegistrar.isOn())
    }

    @Test
    fun `a removal that never lands is remembered for the next launch`() = runTest {
        PushRegistrar.prefsOverride = prefs
        PushRegistrar.enable()
        PushRegistrar.persist("fcm-token")

        // The core is absent here, so the removal cannot land.
        PushRegistrar.unregister()

        assertEquals("fcm-token", prefs.map["pendingRemoval"])
        assertTrue(PushRegistrar.isOn())
    }
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun `disable waits for in flight registration then removes it`() = runTest {
        PushRegistrar.prefsOverride = prefs
        prefs.map["enabled"] = true
        prefs.map["token"] = "fcm-token"
        val registered = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val calls = mutableListOf<String>()
        PushRegistrar.call = { method, _ ->
            calls += method
            if (method == "push.register") { registered.complete(Unit); finish.await() }
            buildJsonObject {}
        }
        val refresh = launch { PushRegistrar.refresh() }
        registered.await()
        val disable = launch { PushRegistrar.disable() }
        runCurrent()
        assertEquals(listOf("push.register"), calls)
        finish.complete(Unit)
        refresh.join()
        disable.join()
        assertEquals(listOf("push.register", "push.unregister"), calls)
        assertFalse(PushRegistrar.isOn())
        assertFalse(prefs.map.containsKey("pendingRemoval"))
    }

}
