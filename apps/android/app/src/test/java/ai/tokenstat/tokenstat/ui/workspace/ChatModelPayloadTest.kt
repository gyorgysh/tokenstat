// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.io.File
import java.io.RandomAccessFile
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ChatModelPayloadTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun preservesAValidModelAndAcceptsTheExactLimit() {
        val file = temporary.newFile()
        val model = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".toByteArray()
        file.writeBytes(model)
        assertArrayEquals(model, readModelPreviewBytes(file))
        RandomAccessFile(file, "rw").use { it.setLength(MODEL_PREVIEW_BYTES.toLong()) }
        val bounded = readModelPreviewBytes(file)!!
        assertEquals(MODEL_PREVIEW_BYTES, bounded.size)
        assertArrayEquals(model, bounded.copyOf(model.size))
    }

    @Test fun rejectsEmptyAndOversizedModels() {
        val file = temporary.newFile()
        assertNull(readModelPreviewBytes(file))
        RandomAccessFile(file, "rw").use { it.setLength(MODEL_PREVIEW_BYTES.toLong() + 1) }
        assertNull(readModelPreviewBytes(file))
    }

    @Test fun aStaleSizeCannotAllowAnOversizedRead() {
        val file = temporary.newFile()
        RandomAccessFile(file, "rw").use { it.setLength(MODEL_PREVIEW_BYTES.toLong() + 1) }
        // Reproduce the size check seeing old metadata before the file grows.
        val stale = object : File(file.path) { override fun length(): Long = 16 }
        assertNull("The opened file must still obey the preview limit", readModelPreviewBytes(stale))
    }

    @Test fun usesTheOpenedSizeForAValidModel() {
        val file = temporary.newFile()
        val model = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".toByteArray()
        file.writeBytes(model)
        val stale = object : File(file.path) { override fun length(): Long = 1 }
        assertArrayEquals(model, readModelPreviewBytes(stale))
        assertNull(readModelPreviewBytes(temporary.newFolder()))
        assertNull(readModelPreviewBytes(File(temporary.root, "missing.obj")))
    }

    @Test fun aStaleSizeCannotPublishAnEmptyModel() {
        val file = temporary.newFile()
        val stale = object : File(file.path) { override fun length(): Long = 16 }
        assertNull(readModelPreviewBytes(stale))
    }
}
