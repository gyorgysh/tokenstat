// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n
import android.webkit.WebView
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatPreviewCrashTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun browsers(): List<WebView> {
        fun collect(view: android.view.View): List<WebView> = when (view) {
            is WebView -> listOf(view)
            is android.view.ViewGroup -> (0 until view.childCount).flatMap { collect(view.getChildAt(it)) }
            else -> emptyList()
        }
        var result = emptyList<WebView>()
        compose.runOnIdle { result = collect(compose.activity.window.decorView) }
        return result
    }

    private fun js(view: WebView, script: String): String {
        val result = AtomicReference("")
        val done = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            view.evaluateJavascript(script) { result.set(it); done.countDown() }
        }
        assertTrue(done.await(10, TimeUnit.SECONDS))
        return result.get()
    }

    @Test fun rendererCrashKeepsChatAliveAndPreviewsCanReopen() {
        val file = File.createTempFile("crash-preview", ".obj", compose.activity.cacheDir)
        file.writeText("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
        val show = mutableStateOf(true)
        try {
            compose.setContent {
                Column {
                    Text("Chat is still available")
                    if (show.value) {
                        ChatModelView("model.obj", file)
                        ChatChartView("""{"version":1,"type":"bar","title":"Revenue","categories":["Q1"],"series":[{"name":"Revenue","data":[25]}]}""")
                    }
                }
            }
            fun ready() = browsers().let { views ->
                views.size == 2 && views.all { view ->
                    js(view, if (view is ModelWebSurface) "!!document.getElementById('status')?.hidden" else "!!window.TokenstatChart?.inspect().valid") == "true"
                }
            }
            compose.waitUntil(20_000) { ready() }
            val old = browsers()
            compose.runOnIdle { old.first { it is ModelWebSurface }.loadUrl("chrome://crash") }
            compose.waitUntil(10_000) { browsers().none { it is ModelWebSurface } }
            // WebViews may share a renderer or use separate processes.
            val remaining = browsers()
            compose.runOnIdle { remaining.forEach { it.loadUrl("chrome://crash") } }
            compose.waitUntil(10_000) { browsers().isEmpty() }
            compose.onNodeWithText("Chat is still available").assertIsDisplayed()
            compose.onNodeWithText(L10n.text("android.chatmodel.preview_unavailable")).assertIsDisplayed()
            compose.onNodeWithText(L10n.text("common.chart.unavailable")).assertIsDisplayed()
            compose.runOnIdle { show.value = false }
            compose.waitForIdle()
            compose.runOnIdle { show.value = true }
            compose.waitUntil(20_000) { ready() }
            assertTrue(browsers().none { it in old })
        } finally { file.delete() }
    }
}
