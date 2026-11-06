// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NotificationPermissionLifecycleTest {
    @Test fun deniedNotificationsDoNotPromptOnLaunchRecreationOrResume() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val instrument = InstrumentationRegistry.getInstrumentation()
        val context = instrument.targetContext
        assumeFalse(ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
        fun check() {
            instrument.waitForIdleSync()
            val deadline = SystemClock.elapsedRealtime() + 5_000
            var window = instrument.uiAutomation.rootInActiveWindow
            // RESUMED can precede the first accessible frame, particularly
            // after recreation. Still fail if a permission window appears.
            while (window?.packageName != context.packageName &&
                window?.packageName?.toString()?.contains("permissioncontroller") != true &&
                SystemClock.elapsedRealtime() < deadline
            ) {
                SystemClock.sleep(50)
                window = instrument.uiAutomation.rootInActiveWindow
            }
            assertNotNull("The app has a visible window", window)
            assertEquals("No system permission dialog covers the app", context.packageName, window!!.packageName.toString())
            assertEquals(PackageManager.PERMISSION_DENIED,
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS))
        }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            check()
            scenario.recreate()
            check()
            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            check()
        }
    }
}
