// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The real Android WebView, local data and a fixture Activity. No host/account is opened. */
@RunWith(AndroidJUnit4::class)
class ChatChartTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val source = """{"version":1,"type":"bar","title":"Quarterly revenue","categories":["Q1","Q2"],"series":[{"name":"Revenue","data":[12500,22000]}]}"""

    @Test fun offlineContainerInspectsExportsBlocksNavigationAndDisposes() {
        lateinit var surface: ChartWebSurface
        val export = AtomicReference<ChartExport>()
        val height = AtomicReference(0f)
        compose.setContent {
            AndroidView(factory = { context -> ChartWebSurface(context).also {
                surface = it
                it.onHeight = { value -> height.set(value) }
                it.onExport = { value -> export.set(value) }
                it.render(source, false)
            } }, modifier = Modifier.fillMaxWidth().height(600.dp), onRelease = { it.shutdown() })
        }
        fun js(script: String): String {
            val value = AtomicReference("")
            val done = CountDownLatch(1)
            InstrumentationRegistry.getInstrumentation().runOnMainSync { surface.evaluateJavascript(script) { value.set(it); done.countDown() } }
            assertTrue("Chart script callback", done.await(10, TimeUnit.SECONDS))
            return value.get()
        }
        compose.waitUntil(20_000) { js("!!window.TokenstatChart?.inspect().valid") == "true" }
        assertEquals("true", js("document.querySelectorAll('#plot svg path').length>0"))
        assertTrue(height.get() in 180f..2200f)
        js("document.getElementById('plot').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight'}));document.getElementById('table-toggle').click()")
        assertEquals("true", js("window.TokenstatChart.inspect().selected.includes('12,500') && document.querySelectorAll('#rows tr').length===2"))
        js("window.TokenstatChart.exportChart('json')")
        compose.waitUntil(5_000) { export.get() != null }
        assertEquals("json", export.get().format)
        assertTrue(String(export.get().data).contains("Quarterly revenue"))
        compose.runOnIdle { surface.render(source, true) }
        compose.waitUntil(5_000) { js("document.documentElement.style.colorScheme==='dark'") == "true" }
        js("location.href='https://invalid.example/blocked'")
        assertEquals("true", js("location.href==='https://charts.tokenstat.invalid/index.html'"))
        compose.runOnIdle { surface.shutdown() }
        // Late bridge messages and pending callbacks must be harmless after release.
    }
}
