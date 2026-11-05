// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.util.Base64
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.LightColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real offline WebView; delay model parsing to exercise replaced loads. */
@RunWith(AndroidJUnit4::class)
class ChatModelTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var surface: ModelWebSurface
    private val results = CopyOnWriteArrayList<String?>()
    private val model = Base64.encodeToString(
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".toByteArray(), Base64.NO_WRAP)

    private fun mount() {
        compose.setContent {
            AndroidView(factory = { context -> ModelWebSurface(context).also {
                surface = it
                it.onResult = { message -> results.add(message) }
                it.render(model, "obj", "#08070d")
            } }, modifier = Modifier.fillMaxWidth().height(320.dp), onRelease = { it.shutdown() })
        }
        compose.waitUntil(20_000) { results.isNotEmpty() }
        assertEquals(listOf<String?>(null), results.toList())
        assertEquals("true", js("document.getElementById('model').tagName==='CANVAS' && document.getElementById('model').width>0 && document.getElementById('status').hidden"))
        results.clear()
    }

    private fun js(script: String): String {
        val value = AtomicReference("")
        val done = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            surface.evaluateJavascript(script) { value.set(it); done.countDown() }
        }
        assertTrue("Model script callback", done.await(10, TimeUnit.SECONDS))
        return value.get()
    }

    private fun holdTwoLoads() {
        js("window.pending=[]; window.TokenstatModel={load:()=>new Promise((resolve,reject)=>pending.push({resolve,reject}))};")
        compose.runOnIdle { surface.render(model, "obj", "#ffffff") }
        compose.runOnIdle { surface.render(model, "obj", "#08070d") }
        compose.waitUntil(5_000) { js("pending.length") == "2" }
    }

    @Test fun replacedFailureCannotFailTheCurrentPreview() {
        mount()
        holdTwoLoads()
        js("pending[0].resolve(false); setTimeout(()=>pending[1].resolve(true),100)")
        compose.waitUntil(5_000) { results.contains(null) }
        assertEquals("Only the current load may report", listOf<String?>(null), results.toList())
    }

    @Test fun replacedSuccessCannotHideTheCurrentFailure() {
        mount()
        holdTwoLoads()
        js("pending[0].resolve(true); setTimeout(()=>pending[1].reject(new Error('Current load failed')),100)")
        compose.waitUntil(5_000) { results.any { it?.contains("Current load failed") == true } }
        assertEquals(1, results.size)
        assertTrue(results.single()!!.contains("Current load failed"))
    }

    @Test fun unchangedLargePayloadDoesNotReload() {
        mount()
        js("window.loads=0; window.TokenstatModel={load:()=>{loads++;return Promise.resolve(true)}};")
        val large = "A".repeat(16 * 1024 * 1024)
        compose.runOnIdle { surface.render(large, "gltf", "#08070d") }
        compose.waitUntil(5_000) { js("loads") == "1" }
        compose.runOnIdle {
            val started = System.nanoTime()
            repeat(50) { surface.render(large, "gltf", "#08070d") }
            android.util.Log.i("ModelPreviewTest", "50 unchanged 16 MiB renders: ${(System.nanoTime() - started) / 1_000_000.0} ms")
        }
        assertEquals("1", js("loads"))
    }

    @Test fun failureAfterAThemeChangeIsVisibleAndCanRecover() {
        val file = File.createTempFile("model-preview", ".obj", compose.activity.cacheDir)
        file.writeBytes(Base64.decode(model, Base64.NO_WRAP))
        val colors = mutableStateOf(DarkColors)
        try {
            compose.setContent { TsTheme(colors.value) { ChatModelView("model.obj", file) } }
            fun find(view: android.view.View): ModelWebSurface? = when (view) {
                is ModelWebSurface -> view
                is android.view.ViewGroup -> (0 until view.childCount).firstNotNullOfOrNull { find(view.getChildAt(it)) }
                else -> null
            }
            compose.waitUntil(10_000) {
                var found: ModelWebSurface? = null
                compose.runOnIdle { found = find(compose.activity.window.decorView) }
                found?.also { surface = it } != null
            }
            compose.waitUntil(20_000) { js("document.getElementById('status')?.hidden") == "true" }
            compose.waitUntil(5_000) {
                compose.onAllNodes(hasText(L10n.text("android.chatmodel.loading"))).fetchSemanticsNodes().isEmpty()
            }
            js("window.TokenstatModel={load:()=>Promise.reject(new Error('Theme load failed'))};")
            compose.runOnIdle { colors.value = LightColors }
            compose.waitUntil(5_000) {
                compose.onAllNodes(hasText("Error: Theme load failed")).fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithText("Error: Theme load failed").assertIsDisplayed()
            js("window.TokenstatModel={load:()=>Promise.resolve(true)};")
            compose.runOnIdle { colors.value = DarkColors }
            compose.waitUntil(5_000) {
                compose.onAllNodes(hasText("Error: Theme load failed")).fetchSemanticsNodes().isEmpty()
            }
        } finally { file.delete() }
    }
}
