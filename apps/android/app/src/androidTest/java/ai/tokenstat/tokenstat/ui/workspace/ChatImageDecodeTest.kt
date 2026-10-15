// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.core.content.FileProvider
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatImageDecodeTest {
    @Test fun decodingDownsamplesWithoutFlatteningAlphaOrChangingTheOriginal() {
        val file = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "alpha-preview-test.png")
        val bitmap = Bitmap.createBitmap(4096, 8, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.argb(96, 12, 200, 56))
        try {
            file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            val original = file.readBytes()
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val folder = File(context.cacheDir, "chat-downloads/alpha-qa-${java.util.UUID.randomUUID()}").apply { mkdirs() }
            try {
                val scoped = File(folder, file.name).apply { writeBytes(original) }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.chatfiles", scoped)
                assertArrayEquals(original, context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
                try {
                    FileProvider.getUriForFile(context, "${context.packageName}.chatfiles", file)
                    fail("Only the chat-downloads cache directory may be exposed")
                } catch (_: IllegalArgumentException) { }
            } finally { folder.deleteRecursively() }
            val decoded = decodeChatImage(file, 512)
            try {
                assertEquals(512, decoded.width)
                assertTrue(decoded.hasAlpha())
                assertTrue(Color.alpha(decoded.getPixel(256, 0)) in 95..97)
                assertArrayEquals(original, file.readBytes())
            } finally { decoded.recycle() }
        } finally { bitmap.recycle(); file.delete() }
    }
}
