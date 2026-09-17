// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ChatPullsSectionsTest {
    @Test
    fun `links keep text and url`() {
        assertEquals(
            "Sourced from zip's releases (https://github.com/zip-rs/zip2/releases).",
            stripPullHtml(
                """Sourced from <a href="https://github.com/zip-rs/zip2/releases">zip's releases</a>.""",
            ),
        )
    }

    @Test
    fun `details and comments go away`() {
        val out = stripPullHtml("<details>\n<summary>Release notes</summary>\n<!-- raw HTML omitted -->\nBody here.\n</details>")
        assertFalse(out.contains("<"))
        assertEquals("Release notes\n\nBody here.", out)
    }

    @Test
    fun `entities unescape`() {
        assertEquals("a & b <c>", stripPullHtml("a &amp; b &lt;c&gt;"))
    }
}
