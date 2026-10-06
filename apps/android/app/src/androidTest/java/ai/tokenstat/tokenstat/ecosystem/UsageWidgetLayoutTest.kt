// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.res.Configuration
import android.content.Intent
import android.content.ComponentName
import android.content.pm.ShortcutManager
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.core.graphics.ColorUtils
import androidx.compose.ui.graphics.toArgb
import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.theme.LightColors
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import java.io.File
import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlinx.serialization.json.*

/** Inflate real RemoteViews at widget sizes, with privacy and overflow cases. */
@RunWith(AndroidJUnit4::class)
class UsageWidgetLayoutTest {
    @Test fun launcherMetadataKeepsUsageConfigurationAndCompactLimitResizing() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val providers = AppWidgetManager.getInstance(context).installedProviders
        val usage = providers.single { it.provider == ComponentName(context, UsageWidgetProvider::class.java) }
        assertEquals(ComponentName(context, UsageWidgetConfigurationActivity::class.java), usage.configure)
        assertTrue(usage.widgetFeatures and AppWidgetProviderInfo.WIDGET_FEATURE_RECONFIGURABLE != 0)
        val limits = providers.single { it.provider == ComponentName(context, LimitsWidgetProvider::class.java) }
        assertTrue(limits.minResizeHeight <= 64 * context.resources.displayMetrics.density + 1)
    }

    @Test fun persistedLogoutBlockRejectsBackgroundVerification() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val privacy = context.getSharedPreferences("widget-account-privacy", android.content.Context.MODE_PRIVATE)
        val account = buildJsonObject { put("signedIn", true); put("host", "https://example.test"); put("accountId", "first") }
        UsageWidgetStore.clear(context)
        try {
            UsageWidgetStore.verify(context, account, UsageWidgetStore.epoch(), fromApp = true)!!
            assertNotNull(UsageWidgetStore.read(context))
            // Model a prior process's sign-out marker with an otherwise
            // unblocked in-memory session and an old cache still on disk.
            assertTrue(privacy.edit().putBoolean("blocked", true).commit())
            assertNull(UsageWidgetStore.read(context))
            assertNull(UsageWidgetStore.verify(context, account, UsageWidgetStore.epoch()))
            assertNotNull(UsageWidgetStore.verify(context, account, UsageWidgetStore.epoch(), fromApp = true))
            assertFalse(privacy.getBoolean("blocked", true))
            UsageWidgetStore.clear(context, block = true)
            assertTrue(privacy.getBoolean("blocked", false))
        } finally { UsageWidgetStore.clear(context) }
    }
    @Test fun accountSwitchCannotRestoreOldUsageWhenStorageWriteFails() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cache = context.noBackupFilesDir.resolve("widget-usage.json")
        val obstruction = File(cache.path + ".new")
        fun account(id: String) = buildJsonObject { put("signedIn", true); put("host", "https://example.test"); put("accountId", id) }
        val calendar = buildJsonObject {
            put("scope", "account"); put("fetchedAtMs", System.currentTimeMillis())
            put("rows", JsonArray(listOf(JsonArray(listOf(buildJsonObject {
                put("date", LocalDate.now().toString()); put("value", 18_420_000L); put("locked", false)
            })))))
        }
        UsageWidgetStore.clear(context)
        try {
            val first = UsageWidgetStore.verify(context, account("first"), UsageWidgetStore.epoch(), fromApp = true)!!
            UsageWidgetStore.publish(context, first, calendar)
            assertEquals(18_420_000L, UsageWidgetStore.read(context)!!.value(false))
            // A nonempty directory blocks AtomicFile's replacement write,
            // exercising a real filesystem failure rather than a mock.
            assertTrue(obstruction.mkdir())
            obstruction.resolve("unavailable").writeText("fixture")
            val second = UsageWidgetStore.verify(context, account("second"), UsageWidgetStore.epoch(), fromApp = true)!!
            assertNull(UsageWidgetStore.read(context)?.value(false))
            assertFalse(cache.isFile)
            assertTrue(obstruction.deleteRecursively())
            UsageWidgetStore.publish(context, second, calendar)
            assertEquals(second.owner, UsageWidgetStore.read(context)!!.owner)
        } finally {
            obstruction.deleteRecursively()
            UsageWidgetStore.clear(context)
        }
    }
    @Test fun widgetPaletteMatchesAppAndSecondaryTextIsReadable() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        for (dark in listOf(false, true)) {
            val context = base.createConfigurationContext(Configuration(base.resources.configuration).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            })
            val palette = if (dark) DarkColors else LightColors
            assertEquals(palette.accent.toArgb(), context.getColor(R.color.ts_widget_accent))
            assertEquals(palette.secondary.toArgb(), context.getColor(R.color.ts_widget_secondary))
            assertEquals(palette.textPrimary.toArgb(), context.getColor(R.color.ts_widget_text))
            assertEquals(palette.textSecondary.toArgb(), context.getColor(R.color.ts_widget_muted))
            assertTrue(ColorUtils.calculateContrast(context.getColor(R.color.ts_widget_muted), context.getColor(R.color.ts_widget_surface)) >= 4.5)
        }
    }
    @Test fun cachedUsageCannotReturnAfterLogoutOrAccountSwitch() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        fun account(id: String) = buildJsonObject { put("signedIn", true); put("host", "https://example.test"); put("accountId", id) }
        fun calendar(scope: String = "account") = buildJsonObject {
            put("scope", scope); put("fetchedAtMs", System.currentTimeMillis())
            put("rows", JsonArray(listOf(JsonArray(listOf(buildJsonObject {
                put("date", LocalDate.now().toString()); put("value", 18_420_000L); put("locked", false)
            })))))
        }
        UsageWidgetStore.clear(context)
        try {
            val first = UsageWidgetStore.verify(context, account("first"), UsageWidgetStore.epoch(), fromApp = true)!!
            UsageWidgetStore.publish(context, first, calendar())
            assertEquals(18_420_000L, UsageWidgetStore.read(context)!!.value(false))
            UsageWidgetStore.publish(context, first, calendar("local"))
            assertTrue(UsageWidgetStore.read(context)!!.refreshFailed)
            val previousEpoch = UsageWidgetStore.epoch()
            UsageWidgetStore.clear(context, block = true)
            UsageWidgetStore.publish(context, first, calendar())
            UsageWidgetStore.failed(context, first, previousEpoch)
            assertNull(UsageWidgetStore.read(context))
            assertFalse(context.noBackupFilesDir.resolve("widget-usage.json").exists())
            assertNull(UsageWidgetStore.verify(context, account("first"), UsageWidgetStore.epoch()))
            val second = UsageWidgetStore.verify(context, account("second"), UsageWidgetStore.epoch(), fromApp = true)!!
            assertNotEquals(first.owner, second.owner)
            UsageWidgetStore.publish(context, first, calendar())
            assertNull(UsageWidgetStore.read(context)!!.value(false))
            UsageWidgetStore.publish(context, second, calendar())
            assertEquals(second.owner, UsageWidgetStore.read(context)!!.owner)
        } finally { UsageWidgetStore.clear(context) }
    }
    @Test fun shortcutsAndTileAreRegistered() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val shortcuts = context.getSystemService(ShortcutManager::class.java).manifestShortcuts
        assertEquals(setOf("workspaces", "insights", "ssh"), shortcuts.map { it.id }.toSet())
        assertTrue(shortcuts.all { it.isEnabled && it.intent?.action == QuickAccess.ACTION })
        val tile = context.packageManager.getServiceInfo(ComponentName(context, WorkspacesTileService::class.java), 0)
        assertTrue(tile.exported)
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", tile.permission)
    }
    @Test fun navigationDropsInvalidRoutesAndPreservesNewerRequests() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        QuickAccess.offer(QuickAccess.intent(context, "ssh"))
        val old = QuickAccess.request.value!!
        assertEquals("ssh", old.screen)
        QuickAccess.offer(Intent(QuickAccess.ACTION).putExtra("screen", "execute"))
        assertEquals(old, QuickAccess.request.value)
        QuickAccess.offer(QuickAccess.intent(context, "insights"))
        val latest = QuickAccess.request.value!!
        QuickAccess.take(old)
        assertEquals(latest, QuickAccess.request.value)
        QuickAccess.take(latest)
        assertNull(QuickAccess.request.value)
    }
    @Test fun rendersAllSizesAndThemes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val base = instrumentation.targetContext
        val today = LocalDate.now()
        val typical = UsageSnapshot("a".repeat(64), System.currentTimeMillis(), (6 downTo 0).map {
            UsageDay(today.minusDays(it.toLong()).toString(), (it + 1) * 18_420_000L, false)
        })
        val states = mapOf("activity" to typical, "empty" to null,
            "offline" to typical.copy(refreshFailed = true),
            "stress" to typical.copy(days = typical.days.map { it.copy(value = 1_234_567_890_000L) }))
        val output = File(base.filesDir, "widget-layouts").apply { mkdirs() }
        instrumentation.runOnMainSync {
            for (week in listOf(false, true)) for (fontScale in listOf(1f, 1.3f)) for (dark in listOf(false, true)) for ((name, snapshot) in states) for ((width, height) in listOf(110 to 64, 160 to 64, 160 to 170, 280 to 170, 360 to 170, 160 to 320, 360 to 360)) {
                val config = Configuration(base.resources.configuration).apply {
                    this.fontScale = fontScale
                    uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                        if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                }
                val context = base.createConfigurationContext(config)
                val parent = FrameLayout(context)
                val view = UsageWidgetProvider.render(context, 1, week, snapshot, width >= 280, height >= 280, compact = height < 130).apply(context, parent)
                val density = context.resources.displayMetrics.density
                val w = (width * density).toInt(); val h = (height * density).toInt()
                view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
                view.layout(0, 0, w, h)
                val value = view.findViewById<TextView>(R.id.widget_value)
                assertEquals(1, value.lineCount)
                assertTrue("Amount must fit $name $width $dark", value.layout.getEllipsisCount(0) == 0 && value.layout.getLineWidth(0) <= value.width + 1)
                assertEquals(context.getColor(R.color.ts_widget_text), value.currentTextColor)
                val brand = view.findViewById<TextView>(R.id.widget_brand_label)
                if (brand.visibility == View.VISIBLE) assertTrue("Brand must fit", brand.layout.getLineWidth(0) <= brand.width - brand.paddingStart - brand.paddingEnd + 1)
                val period = view.findViewById<TextView>(R.id.widget_period)
                assertTrue("Period must fit $width $fontScale $week", period.layout.getLineWidth(0) <= period.width - period.paddingStart - period.paddingEnd + 1)
                val status = view.findViewById<TextView>(R.id.widget_status)
                assertTrue("Footer must fit $name $width $dark $fontScale", status.bottom <= h - view.paddingBottom)
                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap))
                File(output, "usage-$width-$height-${if (dark) "dark" else "light"}-$name-$fontScale-${if (week) "week" else "today"}.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
        }
    }
    @Test fun disablingChartsPreservesBothTotalsAndRefreshShowsProgress() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val prefs = LimitsWidgetProvider.preferences(context)
        val today = LocalDate.now()
        val snapshot = UsageSnapshot("a".repeat(64), System.currentTimeMillis(), (6 downTo 0).map {
            UsageDay(today.minusDays(it.toLong()).toString(), (it + 1) * 1_000_000L, false)
        })
        try {
            prefs.edit().putBoolean("charts.77", false).commit()
            UsageWidgetProvider.setRefreshing(context, true)
            instrumentation.runOnMainSync {
                for (week in listOf(false, true)) {
                    val view = UsageWidgetProvider.render(context, 77, week, snapshot, wide = true).apply(context, FrameLayout(context))
                    assertEquals(View.VISIBLE, view.findViewById<View>(R.id.widget_chart).visibility)
                    assertEquals(View.GONE, view.findViewById<View>(R.id.widget_bars).visibility)
                    assertEquals(context.getString(if (week) R.string.widget_today else R.string.widget_week_short), view.findViewById<TextView>(R.id.widget_secondary_period).text)
                    assertTrue(view.findViewById<TextView>(R.id.widget_week_total).text.isNotEmpty())
                    assertEquals(View.VISIBLE, view.findViewById<View>(R.id.widget_progress).visibility)
                    assertEquals(View.INVISIBLE, view.findViewById<View>(R.id.widget_refresh).visibility)
                    assertFalse(view.findViewById<View>(R.id.widget_refresh).isEnabled)
                    val density = context.resources.displayMetrics.density
                    val w = (300 * density).toInt(); val h = (170 * density).toInt()
                    view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
                    view.layout(0, 0, w, h)
                    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    view.draw(Canvas(bitmap))
                    File(context.filesDir, "widget-layouts/usage-no-charts-$week.png").apply { parentFile?.mkdirs() }.outputStream().use {
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                    }
                }
            }
        } finally { UsageWidgetProvider.setRefreshing(context, false); prefs.edit().remove("charts.77").commit() }
    }
}
