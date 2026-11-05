// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import ai.tokenstat.tokenstat.ui.localization.L10n
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4

/** The production terminal view and bridge, without a PTY or SSH connection. */
@RunWith(AndroidJUnit4::class)
class TerminalRendererCrashTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun failureBeforeThePageIsReadyInvalidatesItsBridge() {
        val instrument = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val bridge = TerminalBridge()
        var copied = 0
        var failed = 0
        instrument.runOnMainSync {
            val view = TerminalWebView(instrument.targetContext, bridge)
            val old = bridge.jsApi
            bridge.onCopy = { copied++ }
            view.onRendererGone = { failed++ }
            assertTrue(view.rendererGone())
            assertTrue(view.rendererGone())
            view.shutdown()
            old.onCopy("late")
            assertNull(bridge.webView)
            assertFalse(bridge.alive)
            assertFalse(bridge.killed)
        }
        instrument.waitForIdleSync()
        assertEquals(1, failed)
        assertEquals(0, copied)
    }

    @Test fun aRendererCrashReleasesBothTerminalsAndTheyCanReopen() {
        val generation = mutableStateOf(0)
        val failed = List(2) { mutableStateOf(false) }
        val bridges = mutableListOf<TerminalBridge>()
        val views = mutableListOf<TerminalWebView>()
        val loaded = java.util.concurrent.atomic.AtomicInteger()
        compose.setContent {
            Column {
                Text("Sessions remain available")
                androidx.compose.runtime.key(generation.value) {
                    repeat(2) { index ->
                        if (failed[index].value) Text(L10n.text("android.terminalscreen.display_stopped"))
                        else AndroidView(factory = { context ->
                            val bridge = TerminalBridge().also { bridges.add(it) }
                            TerminalWebView(context, bridge).apply {
                                views.add(this)
                                settings.javaScriptEnabled = true
                                settings.blockNetworkLoads = true
                                onRendererGone = { failed[index].value = true }
                                addJavascriptInterface(bridge.jsApi, "TermBridge")
                                webViewClient = object : WebViewClient() {
                                    override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean =
                                        (view as TerminalWebView).rendererGone()
                                    override fun onPageFinished(view: WebView, url: String) {
                                        if (bridge.acceptPage(view, url)) loaded.incrementAndGet()
                                    }
                                }
                                loadUrl(bridge.pageUrl())
                            }
                        }, modifier = Modifier.fillMaxWidth().height(180.dp), onRelease = { it.shutdown() })
                    }
                }
            }
        }
        compose.waitUntil(20_000) { loaded.get() == 2 }
        val old = views.toList()
        compose.runOnIdle { old.first().loadUrl("chrome://crash") }
        compose.waitUntil(10_000) { failed.first().value }
        // A second terminal may share the renderer or own another process.
        compose.runOnIdle { if (!failed[1].value) old[1].loadUrl("chrome://crash") }
        compose.waitUntil(10_000) { failed.all { it.value } }
        compose.onNodeWithText("Sessions remain available").assertIsDisplayed()
        compose.onAllNodesWithText(L10n.text("android.terminalscreen.display_stopped")).assertCountEquals(2)
        compose.runOnIdle {
            assertTrue(old.none { it.isAttachedToWindow })
            assertTrue(bridges.all { it.webView == null && !it.alive && !it.killed })
            old.forEach { it.shutdown() } // Release after renderer death is idempotent.
            failed.forEach { it.value = false }
            generation.value++
        }
        compose.waitUntil(20_000) { loaded.get() == 4 }
        compose.runOnIdle {
            assertTrue(views.takeLast(2).none { it in old })
            assertTrue(bridges.takeLast(2).all { it.alive })
        }
    }
}
