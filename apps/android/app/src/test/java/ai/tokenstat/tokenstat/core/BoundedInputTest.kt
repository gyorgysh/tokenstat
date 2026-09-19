package ai.tokenstat.tokenstat.core

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.*
import org.junit.Test

class BoundedInputTest {
    @Test fun `exact limit and empty streams are accepted`() {
        assertArrayEquals(byteArrayOf(1, 2, 3), ByteArrayInputStream(byteArrayOf(1, 2, 3)).readBounded(3))
        assertArrayEquals(byteArrayOf(), ByteArrayInputStream(byteArrayOf()).readBounded(0))
    }

    @Test fun `unreported oversized input is stopped at the limit plus one`() {
        var consumed = 0
        val stream = object : InputStream() {
            override fun read(): Int { consumed++; return 42 }
        }
        assertThrows(InputLimitExceeded::class.java) { stream.readBounded(12) }
        assertEquals(13, consumed)
    }

    @Test fun `short and zero length reads do not truncate or spin`() {
        val data = ByteArrayInputStream(byteArrayOf(1, 2, 3))
        var zero = true
        val stream = object : InputStream() {
            override fun read() = data.read()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (zero) { zero = false; return 0 }
                return data.read(b, off, minOf(1, len))
            }
        }
        assertArrayEquals(byteArrayOf(1, 2, 3), stream.readBounded(3))
    }
}
