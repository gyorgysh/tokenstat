// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runners.model.Statement
import org.junit.Test
import org.junit.runner.RunWith

/** Render production components with local fixtures; no account or host is used. */
@RunWith(AndroidJUnit4::class)
class ChatImageLayoutTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()
    private val screenRequirement = TestRule { base, description ->
        object : Statement() {
            override fun evaluate() {
                description.getAnnotation(MinimumScreenWidth::class.java)?.let { required ->
                    val metrics = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics
                    assumeTrue("Requires at least ${required.dp}dp of screen width", metrics.widthPixels / metrics.density >= required.dp)
                }
                base.evaluate()
            }
        }
    }
    // Compose v2 executes tests inside a coroutine. Keep environment assumptions
    // outside that rule so JUnit reports an incompatible device as skipped.
    @get:Rule val rules: RuleChain = RuleChain.outerRule(screenRequirement).around(compose)
    private val images = (0..5).map { ChatDisplayItem.Attachment("image-$it", "$it", "preview-$it.png", "image/png", 100) }

    private fun fixtures(): Map<String, File> {
        val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "gallery-layout-qa").apply { mkdirs() }
        return images.associate { image ->
            image.attachmentId to File(folder, image.name).also { file ->
                val (width, height) = when (image.attachmentId) {
                    "1" -> 320 to 480
                    "2", "3" -> 960 to 360
                    else -> 480 to 320
                }
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.argb(160, 45, 155, 125) }
                canvas.drawRoundRect(30f, 30f, width - 30f, height - 30f, 24f, 24f, paint)
                paint.color = android.graphics.Color.WHITE; paint.textSize = 44f
                canvas.drawText(if (width > height) "Landscape" else "Portrait", 44f, height / 2f, paint)
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
        }
    }

    private fun show(width: Dp = 352.dp, content: @Composable () -> Unit) {
        compose.setContent { TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
            Surface(Modifier.fillMaxSize()) { Column(Modifier.width(width).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { content() } }
        } } }
    }

    @Test fun galleriesRemainBoundedAndOverflowOpensTheSelectedImage() {
        val files = fixtures()
        var selected = -1
        show {
            Box(Modifier.testTag("single")) { ChatImageTiles(images.take(1), files) { selected = it } }
            Box(Modifier.testTag("pair")) { ChatImageTiles(images.take(2), files) { selected = it } }
            Box(Modifier.width(280.dp).testTag("three")) { ChatImageTiles(images.drop(1).take(3), files) { selected = it } }
            Box(Modifier.testTag("overflow")) { ChatImageTiles(images, files) { selected = it } }
        }
        compose.onNodeWithTag("single").assertIsDisplayed()
        assertTrue(height("single") <= 325.dp)
        assertTrue(height("pair") <= 265.dp)
        assertTrue(height("overflow") <= 510.dp)
        fun threeBounds() = images.drop(1).take(3).map { image ->
            compose.onNode(hasContentDescription(L10n.text("common.chat.images.view", image.name)) and hasAnyAncestor(hasTestTag("three")),
                useUnmergedTree = true).getUnclippedBoundsInRoot()
        }
        compose.waitUntil(10_000) {
            val bounds = threeBounds()
            (bounds[0].right - bounds[0].left).value <= 49f && bounds.drop(1).all { (it.right - it.left).value >= 111f }
        }
        val three = threeBounds()
        assertTrue(three.all { it.right - it.left >= 48.dp && it.bottom - it.top >= 48.dp })
        assertEquals(three[0].top.value, three[1].top.value, .5f)
        assertEquals(three[0].top.value, three[2].top.value, .5f)
        assertTrue(three[0].right <= three[1].left && three[1].right <= three[2].left)
        assertTrue(three.last().right <= compose.onNodeWithTag("three").getUnclippedBoundsInRoot().right)
        compose.onAllNodesWithText(L10n.text("common.chat.images.count", "3")).assertCountEquals(1)
        compose.onNodeWithText(L10n.text("common.chat.images.more", "2")).performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(3, selected) }
        screenshot("android-chat-galleries")
    }

    @MinimumScreenWidth(672)
    @Test fun tabletGalleryUses640DpWithoutAnEmptyCellForThreeImages() {
        val files = fixtures()
        show(width = 704.dp) {
            Box(Modifier.testTag("wide-three")) { ChatImageTiles(images.take(3), files) {} }
            Box(Modifier.testTag("wide-overflow")) { ChatImageTiles(images, files) {} }
        }
        val bounds = compose.onNodeWithTag("wide-three").getUnclippedBoundsInRoot()
        assertEquals(640f, (bounds.right - bounds.left).value, .5f)
        fun lastBounds() = compose.onNode(hasContentDescription(L10n.text("common.chat.images.view", images[2].name)) and hasAnyAncestor(hasTestTag("wide-three")),
            useUnmergedTree = true).getUnclippedBoundsInRoot()
        compose.waitUntil(10_000) { lastBounds().let { (it.right - it.left).value >= 315f } }
        val last = lastBounds()
        assertEquals(bounds.right.value, last.right.value, .5f)
        assertTrue(height("wide-three") <= 265.dp)
        screenshot("android-chat-galleries-tablet")
    }

    @Test fun viewerNavigatesZoomsAndClosesWithOriginalFileActions() {
        val files = fixtures()
        var opens = 0
        var saves = 0
        show {
            var index by remember { mutableIntStateOf(0) }
            var open by remember { mutableStateOf(true) }
            if (open) ChatImageViewer(images[index], index, images.size, files[images[index].attachmentId], false, null,
                onPrevious = { index-- }, onNext = { index++ }, onDismiss = { open = false }, onLoad = {}, onOpen = { opens++ }, onSave = { saves++ })
            else Text("Closed")
        }
        compose.onNodeWithContentDescription(L10n.text("common.chat.images.zoom_in")).performClick()
        compose.onNodeWithText("150%").assertIsDisplayed()
        compose.onNodeWithContentDescription(L10n.text("common.chat.images.next")).performClick()
        compose.onNodeWithText(images[1].name).assertIsDisplayed()
        compose.onNodeWithText("100%").assertIsDisplayed()
        compose.onNodeWithText(L10n.text("common.open")).performClick()
        compose.onNodeWithText(L10n.text("common.save")).performClick()
        compose.runOnIdle { assertEquals(1, opens); assertEquals(1, saves) }
        screenshot("android-chat-image-viewer")
        compose.onNodeWithContentDescription(L10n.text("common.close")).performClick()
        compose.onNodeWithText("Closed").assertIsDisplayed()
    }

    @Test fun contextAndMcpSummariesStayCompactAndDetailsKeepReportedSources() {
        val data = Json.parseToJsonElement("""{"model":"gpt-6.1-sol","contextUsed":24500,"contextWindow":1000000,"windowSource":"previousAgent","contextBreakdown":{"input":3500,"cacheRead":21000,"cacheWrite":0},"usage":{"input":999999,"output":24000},"currentRun":true,"mcpServers":[{"name":"images","source":"agent","status":"connected"},{"name":"files","source":"agent","status":"connected"},{"name":"archive","source":"config","status":"disabled"}]}""").jsonObject
        val chat = Json.parseToJsonElement("""{"id":"preview","backend":"codex","model":"gpt-6.1-sol","running":true}""").jsonObject
        show { Column(Modifier.testTag("inspector"), verticalArrangement = Arrangement.spacedBy(8.dp)) { ChatInspectionCards(data, chat) } }
        val cards = compose.onNodeWithTag("inspector").fetchSemanticsNode().children
        assertEquals("Activity, context and MCP each keep their own compact card", 3, cards.size)
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val heights = cards.map { (it.boundsInRoot.height / density).dp }
        assertTrue("Collapsed activity is one row: ${heights[0]}", heights[0] <= 56.dp)
        assertTrue("Context summary keeps its token/capacity rows: ${heights[1]}", heights[1] <= 112.dp)
        assertTrue("Collapsed MCP summary is one row: ${heights[2]}", heights[2] <= 56.dp)
        // The original 190dp budget covered Context + MCP. Activity adds one
        // independently bounded row, rather than relaxing either old card.
        assertTrue(heights[1] + heights[2] + 8.dp < 190.dp)
        compose.onNodeWithText(L10n.text("common.chat.stats.connection_summary", "2", "1")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("common.chat.stats.last_window")).assertDoesNotExist()
        screenshot("android-chat-context-collapsed")
        compose.onNodeWithText(L10n.text("common.chat.stats.context"), useUnmergedTree = true).performClick()
        compose.onNodeWithText(L10n.text("common.chat.stats.last_window")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("common.chat.stats.mcp_servers"), useUnmergedTree = true).performClick()
        compose.onNodeWithText(L10n.text("common.chat.stats.other_count", "1")).performClick()
        compose.onNodeWithText(L10n.text("common.chat.stats.disabled")).assertIsDisplayed()
        screenshot("android-chat-context-expanded")
    }

    private fun height(tag: String) = compose.onNodeWithTag(tag).getUnclippedBoundsInRoot().let { it.bottom - it.top }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = if (name == "android-chat-image-viewer") instrumentation.uiAutomation.takeScreenshot()
            ?: error("No image viewer screenshot")
            else compose.onAllNodes(isRoot()).onLast().captureToImage().asAndroidBitmap()
        val resolver = instrumentation.targetContext.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-chat-qa")
        }) ?: error("Cannot save chat QA screenshot")
        resolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}

@Target(AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.RUNTIME)
private annotation class MinimumScreenWidth(val dp: Int)
