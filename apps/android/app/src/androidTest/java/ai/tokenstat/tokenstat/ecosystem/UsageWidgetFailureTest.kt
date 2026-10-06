// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Bundle
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.ListenableWorker
import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.core.CoreFailure
import java.time.LocalDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Missing device capabilities and account access must not become startup requirements. */
@RunWith(AndroidJUnit4::class)
class UsageWidgetFailureTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun account() = buildJsonObject {
        put("signedIn", true); put("host", "https://example.test"); put("accountId", "review-fixture")
    }
    private fun seed(): UsageSnapshot {
        UsageWidgetStore.clear(context)
        val lease = UsageWidgetStore.verify(context, account(), UsageWidgetStore.epoch(), fromApp = true)!!
        UsageWidgetStore.publish(context, lease, buildJsonObject {
            put("scope", "account"); put("fetchedAtMs", System.currentTimeMillis() - 60_000)
            put("rows", JsonArray(listOf(JsonArray(listOf(buildJsonObject {
                put("date", LocalDate.now().toString()); put("value", 18_420_000L); put("locked", false)
            })))))
        })
        return UsageWidgetStore.read(context)!!
    }
    private fun assertRefreshFinished(snapshot: UsageSnapshot?) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val view = UsageWidgetProvider.render(context, 1, false, snapshot, false)
                .apply(context, FrameLayout(context))
            assertNotEquals(context.getString(R.string.widget_updating), view.findViewById<TextView>(R.id.widget_status).text.toString())
            assertTrue(view.findViewById<android.view.View>(R.id.widget_refresh).isEnabled)
        }
    }

    @Test fun missingOrDeniedWidgetServiceDoesNotInterruptCacheCleanupOrResize() {
        val manager = AppWidgetManager.getInstance(context)
        val provider = UsageWidgetProvider()
        for (denied in listOf(false, true)) {
            val restricted = object : ContextWrapper(context) {
                override fun getSystemService(name: String): Any? {
                    if (name == Context.APPWIDGET_SERVICE) {
                        if (denied) throw SecurityException("Fixture service denied")
                        return null
                    }
                    return super.getSystemService(name)
                }
            }
            UsageWidgetProvider.update(restricted, 1)
            UsageWidgetProvider.updateAll(restricted)
            provider.onAppWidgetOptionsChanged(restricted, manager, 1, Bundle())
            for (action in listOf("WIDGET_REFRESH", "WIDGET_PERIOD")) {
                provider.onReceive(restricted, Intent("ai.tokenstat.tokenstat.$action")
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, 1))
            }
            UsageWidgetStore.clear(restricted)
        }
        assertNull(UsageWidgetStore.read(context))
    }

    @Test fun deniedUsageAccessPreservesCachedAmountAndAge() = runBlocking {
        try {
            for (denial in listOf(CoreFailure("auth", "Fixture account access denied"), SecurityException("Fixture access denied"))) {
                val cached = seed()
                val methods = mutableListOf<String>()
                val result = UsageWidgetRefresh(context) { method, _ ->
                    methods += method
                    if (method == "account.status") account() else throw denial
                }.run()
                assertEquals(ListenableWorker.Result.failure(), result)
                assertEquals(listOf("account.status", "activity.calendar"), methods)
                val retained = UsageWidgetStore.read(context)!!
                assertEquals(cached.value(false), retained.value(false))
                assertEquals(cached.updatedAt, retained.updatedAt)
                assertTrue(retained.refreshFailed)
                assertRefreshFinished(retained)
            }
        } finally { UsageWidgetStore.clear(context) }
    }

    @Test fun foregroundSignedOutAnswerCompletesVerificationAndRejectsOldEpochs() {
        seed()
        try {
            val observed = UsageWidgetStore.epoch()
            assertTrue(UsageWidgetStore.verifyForeground(context, buildJsonObject { put("signedIn", false) }, observed))
            assertNull(UsageWidgetStore.read(context))
            assertFalse(UsageWidgetStore.verifyForeground(context, account(), observed))
            assertTrue(UsageWidgetStore.verifyForeground(context, account(), UsageWidgetStore.epoch()))
        } finally { UsageWidgetStore.clear(context) }
    }

    @Test fun signedOutReviewDeviceDoesNotRequestUsageData() = runBlocking {
        seed()
        try {
            val methods = mutableListOf<String>()
            val result = UsageWidgetRefresh(context) { method, _ ->
                methods += method
                buildJsonObject { put("signedIn", false) }
            }.run()
            assertEquals(ListenableWorker.Result.success(), result)
            assertEquals(listOf("account.status"), methods)
            assertNull(UsageWidgetStore.read(context))
            assertRefreshFinished(null)
        } finally { UsageWidgetStore.clear(context) }
    }

    @Test fun cancelledRefreshPropagatesAndClearsUpdatingState() = runBlocking {
        val cached = seed()
        try {
            val cancelled = CancellationException("Fixture cancelled")
            try {
                UsageWidgetRefresh(context) { method, _ ->
                    if (method == "account.status") account() else throw cancelled
                }.run()
                fail("Cancellation must reach WorkManager")
            } catch (actual: CancellationException) { assertSame(cancelled, actual) }
            assertEquals(cached, UsageWidgetStore.read(context))
            assertRefreshFinished(cached)
        } finally { UsageWidgetStore.clear(context) }
    }
}
