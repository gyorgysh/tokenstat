// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class PullDetailTest {
    @Test
    fun `an anchor becomes a markdown link`() {
        assertEquals(
            "Sourced from [zip's releases](https://github.com/zip-rs/zip2/releases).",
            pullBodyMarkdown(
                """Sourced from <a href="https://github.com/zip-rs/zip2/releases">zip's releases</a>.""",
            ),
        )
    }

    @Test
    fun `an anchor with attributes and inner markup keeps its words`() {
        assertEquals(
            "[#70](https://redirect.github.com/zip-rs/zip2/pull/70)",
            pullBodyMarkdown(
                """<a href="https://redirect.github.com/zip-rs/zip2/pull/70" rel="nofollow"><code>#70</code></a>""",
            ),
        )
    }

    @Test
    fun `a link that is not a web address keeps the words and loses the destination`() {
        assertEquals("Click me", pullBodyMarkdown("""<a href="javascript:alert(1)">Click me</a>"""))
    }

    @Test
    fun `release notes keep their structure`() {
        val out = pullBodyMarkdown(
            "<details>\n<summary>Release notes</summary>\n<!-- raw HTML omitted -->\n" +
                "<h2>v7.2.0</h2>\n<h3>Features</h3>\n<ul>\n<li>add a thing</li>\n<li>and another</li>\n</ul>\n</details>",
        )
        assertFalse(out.contains("<"))
        // A list follows its heading on the next line, with no blank line
        // between: consecutive rows are one list, the way the Apple
        // converter writes them.
        assertEquals(
            "### Release notes\n\n## v7.2.0\n\n### Features\n- add a thing\n- and another",
            out,
        )
    }

    @Test
    fun `emphasis survives the html boundary`() {
        assertEquals("*Sourced from GitHub*", pullBodyMarkdown("<p><em>Sourced from GitHub</em></p>"))
        assertEquals("**Breaking**", pullBodyMarkdown("<strong>Breaking</strong>"))
    }

    @Test
    fun `entities unescape and prose keeps its angle brackets`() {
        assertEquals("a & b <c>", pullBodyMarkdown("a &amp; b &lt;c&gt;"))
        assertEquals("one < two and three > four", pullBodyMarkdown("one < two and three > four"))
    }

    @Test
    fun `timestamps parse, and a missing one is nothing rather than 1970`() {
        assertEquals(1_757_004_800_000L, pullEpochMillis("2025-09-04T16:53:20Z"))
        assertNull(pullEpochMillis(null))
        assertNull(pullEpochMillis(""))
        assertNull(pullEpochMillis("3 days ago"))
    }

    @Test
    fun `a check run says how long it took`() {
        assertEquals("42s", checkDurationText("2026-09-18T10:00:00Z", "2026-09-18T10:00:42Z"))
        assertEquals("3m 20s", checkDurationText("2026-09-18T10:00:00Z", "2026-09-18T10:03:20Z"))
        assertEquals("1h 5m", checkDurationText("2026-09-18T10:00:00Z", "2026-09-18T11:05:00Z"))
        assertNull(checkDurationText("2026-09-18T10:00:00Z", null))
    }

    @Test
    fun `timeline events read as sentences`() {
        assertEquals("gyorgy committed · Fix the thing", timelineSentence("committed", "gyorgy", "Fix the thing"))
        assertEquals("dependabot added a label", timelineSentence("labeled", "dependabot", null))
        assertEquals("gyorgy updated the pull request", timelineSentence("somethingNew", "gyorgy", null))
    }

    @Test
    fun `the checks headline counts what passed`() {
        assertEquals("No checks reported", checksHeadline(0, 0))
        assertEquals("29 of 31 checks passed", checksHeadline(29, 31))
    }

    @Test
    fun `the checks message names the worst state`() {
        assertEquals("The head commit does not publish a check suite.", checksMessage(emptyList()))
        assertEquals(
            "Something needs attention before this is ready.",
            checksMessage(listOf("passing", "pending", "failing")),
        )
        assertEquals("The remaining work is still running.", checksMessage(listOf("passing", "pending")))
        assertEquals("Everything reported by the head commit is green.", checksMessage(listOf("passing", "passing")))
    }
}
