// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatChartUpdateTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var surface: ChartWebSurface
    private val heights = CopyOnWriteArrayList<Float>()
    private val source = """{"version":1,"type":"bar","title":"Quarterly revenue","categories":["Q1","Q2"],"series":[{"name":"Revenue","data":[12500,22000]}]}"""

    private fun mount() {
        compose.setContent {
            AndroidView(factory = { context -> ChartWebSurface(context).also {
                surface = it
                it.onHeight = { height -> heights.add(height) }
                it.render(source, false)
            } }, modifier = Modifier.fillMaxWidth().height(500.dp), onRelease = { it.shutdown() })
        }
        compose.waitUntil(20_000) { js("!!window.TokenstatChart?.inspect().valid") == "true" }
        js("""window.chartRuntime=TokenstatChart; window.renderCalls=0; window.lastChartSettings=null;
            window.TokenstatChart={...chartRuntime, render(input,settings){renderCalls++;lastChartSettings=settings;return chartRuntime.render(input,settings)}};""")
    }

    private fun js(script: String): String {
        val result = AtomicReference("")
        val done = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            surface.evaluateJavascript(script) { result.set(it); done.countDown() }
        }
        assertTrue("Chart script returned", done.await(10, TimeUnit.SECONDS))
        return result.get()
    }

    @Test fun unchangedMaximumSizeChartPreservesSelectionWithoutRedrawing() {
        mount()
        val large = source + " ".repeat(256 * 1024 - source.toByteArray().size)
        compose.runOnIdle { surface.render(large, false) }
        compose.waitUntil(10_000) { js("renderCalls") == "1" }
        js("document.getElementById('plot').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight'}));document.getElementById('table-toggle').click()")
        val selected = js("chartRuntime.inspect().selected")
        assertNotEquals("null", selected)
        val samples = mutableListOf<Double>()
        repeat(7) {
            compose.runOnIdle {
                val start = System.nanoTime()
                repeat(100) { surface.render(large, false) }
                samples.add((System.nanoTime() - start) / 1_000_000.0)
            }
        }
        android.util.Log.i("ChartUpdateBenchmark", "100 unchanged 256 KiB updates; median=${samples.sorted()[3]} ms; samples=$samples")
        assertEquals("1", js("renderCalls"))
        assertEquals(selected, js("chartRuntime.inspect().selected"))
        assertEquals("false", js("document.getElementById('data-panel').hidden"))
    }

    @Test fun themeLocaleMotionAndSourceChangesStillReachTheRenderer() {
        val instrument = InstrumentationRegistry.getInstrumentation()
        val resolver = instrument.targetContext.contentResolver
        val key = Settings.Global.ANIMATOR_DURATION_SCALE
        val oldMotion = Settings.Global.getString(resolver, key)
        val oldLocale = Locale.getDefault()
        instrument.uiAutomation.adoptShellPermissionIdentity("android.permission.WRITE_SECURE_SETTINGS")
        try {
            Settings.Global.putFloat(resolver, key, 1f)
            mount()
            compose.runOnIdle { surface.render(source, true) }
            compose.waitUntil(5_000) { js("lastChartSettings?.dark") == "true" }
            assertEquals("true", js("document.documentElement.style.colorScheme==='dark'"))
            Locale.setDefault(Locale.GERMANY)
            compose.runOnIdle { surface.render(source, true) }
            compose.waitUntil(5_000) { js("document.documentElement.lang==='de-DE'") == "true" }
            assertEquals("true", js("!!lastChartSettings.strings.category"))
            Settings.Global.putFloat(resolver, key, 0f)
            compose.runOnIdle { surface.render(source, true) }
            compose.waitUntil(5_000) { js("lastChartSettings?.reducedMotion") == "true" }
            assertEquals("false", js("TokenstatChartEngine.echarts.getInstanceByDom(document.getElementById('plot')).getOption().animation"))
            val changed = source.replace("Quarterly revenue", "New revenue")
            compose.runOnIdle { surface.render(changed, true) }
            compose.waitUntil(5_000) { js("document.title==='New revenue'") == "true" }
            val calls = js("renderCalls")
            compose.runOnIdle {
                surface.render("é".repeat(140_000), true)
                surface.render(" ".repeat(256 * 1024 + 1), true)
            }
            assertEquals("Oversized UTF-8 sources never reach JavaScript", calls, js("renderCalls"))
            assertEquals("true", js("document.title==='New revenue'"))
        } finally {
            Locale.setDefault(oldLocale)
            Settings.Global.putString(resolver, key, oldMotion)
            instrument.uiAutomation.dropShellPermissionIdentity()
        }
    }

    @Test fun aChangedSourceAtTheSameHeightPublishesAFreshMeasurement() {
        mount()
        js("window.chartSettled=false;requestAnimationFrame(()=>requestAnimationFrame(()=>chartSettled=true))")
        compose.waitUntil(5_000) { js("chartSettled") == "true" }
        compose.runOnIdle { heights.clear(); surface.render(source + " ", false) }
        compose.waitUntil(5_000) { heights.isNotEmpty() }
        assertTrue(heights.all { it in 180f..2200f })
    }

    @Test fun anObsoleteHeightMessageCannotResizeTheCurrentChart() {
        mount()
        compose.runOnIdle { surface.render(source, true) }
        compose.waitUntil(5_000) { js("lastChartSettings?.dark") == "true" }
        heights.clear()
        js("""TokenstatChartHost.postMessage(JSON.stringify({type:'height',height:999,paintToken:-1}));
            TokenstatChartHost.postMessage(JSON.stringify({type:'height',height:444,paintToken:lastChartSettings.paintToken}));""")
        compose.waitUntil(5_000) { heights.contains(444f) }
        assertFalse("An old render must not resize the current chart", heights.contains(999f))
    }
}
