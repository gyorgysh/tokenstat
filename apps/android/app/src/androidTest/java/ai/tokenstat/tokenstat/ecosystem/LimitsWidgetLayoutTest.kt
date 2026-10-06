// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.tokenstat.tokenstat.R
import java.io.File
import java.util.Locale
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LimitsWidgetLayoutTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val account get() = buildJsonObject { put("signedIn", true); put("host", "https://example.test"); put("accountId", "quota-review") }
    private val wire get() = Json.parseToJsonElement("""[{"source":"future_vendor","observedAtMs":${System.currentTimeMillis() - 60_000},"windows":[{"label":"weekly","percent":95,"resetsAtMs":${System.currentTimeMillis() + 3_600_000}}]}]""")

    @Test fun quotaCacheSurvivesCalendarDenialAndCannotSurviveSignOut() = runBlocking {
        UsageWidgetStore.clear(context)
        try {
            val lease = UsageWidgetStore.verify(context, account, UsageWidgetStore.epoch(), fromApp = true)!!
            val result = UsageWidgetRefresh(context) { method, _ ->
                when (method) { "account.status" -> account; "usage.limits" -> wire; else -> throw SecurityException("Calendar unavailable") }
            }.run()
            assertEquals(androidx.work.ListenableWorker.Result.failure(), result)
            assertEquals("future_vendor", UsageWidgetStore.read(context)!!.limits.single().source)
            val original = UsageWidgetStore.read(context)!!.limits.single()
            UsageWidgetStore.publishLimits(context, lease, Json.parseToJsonElement("""[{"source":"future_vendor","observedAtMs":1,"windows":[]}]"""))
            assertEquals(original, UsageWidgetStore.read(context)!!.limits.single())
            UsageWidgetStore.clear(context, block = true)
            UsageWidgetStore.publishLimits(context, lease, wire)
            assertNull(UsageWidgetStore.read(context))
            assertFalse(context.noBackupFilesDir.resolve("widget-usage.json").exists())
        } finally { UsageWidgetStore.clear(context) }
    }
    @Test fun providerSelectionIsBoundToAccountAndSupportsSeveralSources() {
        val prefs = LimitsWidgetProvider.preferences(context)
        val provider = QuotaProvider("future_vendor", System.currentTimeMillis(), listOf(QuotaWindow("weekly", 58.0)))
        val snapshot = UsageSnapshot("a".repeat(64), limits = listOf(provider, provider.copy(source = "another_vendor")))
        try {
            prefs.edit().putStringSet("provider.77", snapshot.limits.map { "${snapshot.owner}\n${it.source}" }.toSet()).commit()
            assertEquals(2, LimitsWidgetProvider.readings(context, snapshot, 77).size)
            assertTrue(LimitsWidgetProvider.readings(context, snapshot.copy(owner = "b".repeat(64)), 77).isEmpty())
        } finally { prefs.edit().remove("provider.77").commit() }
    }
    @Test fun rendersQuotaAndLauncherSizesWithResetAndLongNameStates() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val now = System.currentTimeMillis()
        val providers = (0..<9).map { index -> QuotaProvider(if (index < 3) listOf("claude_code", "codex", "cursor")[index] else "long_provider_name_$index", now - 180_000,
            listOf(QuotaWindow("weekly", 58.0 + index * 8, now + 86_400_000))) }
        val output = File(context.filesDir, "widget-layouts").apply { mkdirs() }
        instrumentation.runOnMainSync {
            for (dark in listOf(false, true)) for (rtl in listOf(false, true)) for (fontScale in listOf(1f, 1.3f)) {
                val config = Configuration(context.resources.configuration).apply {
                    this.fontScale = fontScale
                    setLayoutDirection(if (rtl) Locale("ar") else Locale.ENGLISH)
                    uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                }
                val target = context.createConfigurationContext(config)
                for ((width, height) in listOf(110 to 130, 160 to 160, 300 to 160, 180 to 280, 300 to 280)) {
                    for (rings in listOf(true, false)) for (count in listOf(0, 1, 3, 9)) {
                        val readings = providers.take(count)
                        val snapshot = UsageSnapshot("a".repeat(64), limits = readings)
                        val remote = LimitsWidgetProvider.renderSize(target, snapshot, readings, 1, rings, width, height)
                        val view = remote.apply(target, FrameLayout(target))
                        save(target, view, width, height, File(output, "limits-$width-$height-$dark-$rtl-$fontScale-$rings-$count.png"))
                        val status = view.findViewById<TextView>(R.id.limits_status)
                        assertTrue(status.bottom <= view.height - view.paddingBottom)
                    }
                }
                for ((size, width, height) in listOf(Triple(0, 48, 48), Triple(1, 160, 64), Triple(2, 300, 160))) {
                    val view = LauncherWidgetProvider.render(target, size).apply(target, FrameLayout(target))
                    save(target, view, width, height, File(output, "launcher-$size-$dark-$rtl-$fontScale.png"))
                    if (size == 2) assertTrue(view.findViewById<View>(R.id.launcher_devices).height > 20 * target.resources.displayMetrics.density)
                }
                val reset = providers.first().copy(source = "provider_with_a_long_name", stale = true, windows = listOf(QuotaWindow("Weekly quota with long label", 104.0, now - 60_000)))
                val view = LimitsWidgetProvider.renderSize(target, UsageSnapshot("a".repeat(64), limits = listOf(reset)), listOf(reset), 1, true, 160, 160).apply(target, FrameLayout(target))
                assertTrue(view.findViewById<View>(R.id.limits_gauges).contentDescription.toString().contains(target.getString(R.string.widget_reset_passed)))
                save(target, view, 160, 160, File(output, "limits-reset-$dark-$rtl-$fontScale.png"))
            }
        }
    }
    @Test fun selectedWindowsFitOneRowAndTwoByTwoWithNativeRefreshFeedback() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val base = context
        val prefs = LimitsWidgetProvider.preferences(base)
        val now = System.currentTimeMillis()
        val readings = listOf("claude_code", "codex").map { source -> QuotaProvider(source, now - 45 * 60_000,
            listOf(QuotaWindow("5-hour", 15.0, now + 3_600_000), QuotaWindow("weekly", 48.0, now + 86_400_000, "general"))) }
        val snapshot = UsageSnapshot("a".repeat(64), limits = readings)
        val output = File(base.filesDir, "widget-layouts").apply { mkdirs() }
        try {
            prefs.edit().putString("window.77", "both").commit()
            instrumentation.runOnMainSync {
                for (fontScale in listOf(1f, 1.3f)) for (rtl in listOf(false, true)) {
                    val target = base.createConfigurationContext(Configuration(base.resources.configuration).apply {
                        this.fontScale = fontScale
                        setLayoutDirection(if (rtl) Locale("ar") else Locale.ENGLISH)
                    })
                    for ((width, height) in listOf(110 to 64, 160 to 64, 280 to 64, 160 to 130, 160 to 160, 280 to 130)) for (rings in listOf(true, false)) {
                        val view = LimitsWidgetProvider.renderSize(target, snapshot, readings, 77, rings, width, height, refreshing = true).apply(target, FrameLayout(target))
                        save(target, view, width, height, File(output, "limits-both-$width-$height-$rings-$fontScale-$rtl.png"))
                        val gauges = view.findViewById<View>(R.id.limits_gauges)
                        assertTrue(gauges.width > 0 && gauges.height > 0)
                        assertTrue(gauges.left >= view.paddingLeft && gauges.right <= view.width - view.paddingRight)
                        assertEquals(View.VISIBLE, view.findViewById<View>(R.id.limits_progress).visibility)
                        assertEquals(View.INVISIBLE, view.findViewById<View>(R.id.limits_refresh).visibility)
                        val description = gauges.contentDescription.toString()
                        assertTrue(description.contains("5-hour"))
                        if (width == 160 && height >= 130 || width == 280) {
                            assertEquals(2, Regex("Codex").findAll(description).count())
                            assertTrue(description.contains("weekly"))
                        }
                        if (width == 110 && height == 64) assertEquals("+3", view.findViewById<TextView>(R.id.limits_overflow).text.toString())
                    }
                }
            }
        } finally { prefs.edit().remove("window.77").commit() }
    }
    private fun save(context: Context, view: View, width: Int, height: Int, file: File) {
        val density = context.resources.displayMetrics.density
        val w = (width * density).toInt(); val h = (height * density).toInt()
        view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, w, h)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
