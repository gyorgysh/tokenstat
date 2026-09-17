// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SshHostPlatformTest {
    private fun host(
        hostname: String = "example.com",
        port: Int = 22,
        keys: List<String> = listOf("SHA256:abc"),
    ): JsonObject = buildJsonObject {
        put("id", "host_1")
        put("hostname", hostname)
        put("port", port)
        put("hostKeys", buildJsonArray { keys.forEach { add(JsonPrimitive(it)) } })
    }

    private fun entry(
        label: String = "Ubuntu 24.04",
        hostname: String = "example.com",
        port: Int = 22,
        keys: List<String> = listOf("SHA256:abc"),
        savedMs: Long = 1_000L,
    ) = SshHostPlatform.Entry(label, hostname, port, keys.sorted(), savedMs)

    @Test
    fun validatedLabelAcceptsMatchingEntry() {
        assertEquals(
            "Ubuntu 24.04",
            SshHostPlatform.validatedLabel(entry(), host(), nowMs = 2_000L),
        )
    }

    @Test
    fun validatedLabelExpiresAfterNinetyDays() {
        val ninetyDays = 90L * 24 * 60 * 60 * 1000
        assertNull(SshHostPlatform.validatedLabel(entry(savedMs = 0L), host(), nowMs = ninetyDays))
        assertEquals(
            "Ubuntu 24.04",
            SshHostPlatform.validatedLabel(entry(savedMs = 0L), host(), nowMs = ninetyDays - 1),
        )
    }

    @Test
    fun validatedLabelRejectsEditedEndpoint() {
        assertNull(SshHostPlatform.validatedLabel(entry(), host(hostname = "other.com"), nowMs = 2_000L))
        assertNull(SshHostPlatform.validatedLabel(entry(), host(port = 2222), nowMs = 2_000L))
        // Hostnames compare case-insensitively: DNS is not case-sensitive.
        assertEquals(
            "Ubuntu 24.04",
            SshHostPlatform.validatedLabel(entry(), host(hostname = "EXAMPLE.com"), nowMs = 2_000L),
        )
    }

    @Test
    fun validatedLabelRejectsChangedIdentity() {
        assertNull(
            SshHostPlatform.validatedLabel(entry(), host(keys = listOf("SHA256:other")), nowMs = 2_000L),
        )
    }

    @Test
    fun validatedLabelSurvivesFirstTrust() {
        // Confirmed before the fingerprint was trusted: the setup check
        // probes first, so a later trust must not orphan the label.
        assertEquals(
            "Ubuntu 24.04",
            SshHostPlatform.validatedLabel(entry(keys = emptyList()), host(), nowMs = 2_000L),
        )
    }

    @Test
    fun entryRoundTrips() {
        val parsed = SshHostPlatform.Entry.parse(entry().serialize())
        assertEquals(entry(), parsed)
        assertNull(SshHostPlatform.Entry.parse(null))
        assertNull(SshHostPlatform.Entry.parse("garbage"))
        assertNull(SshHostPlatform.Entry.parse(entry().serialize().replace("Ubuntu 24.04", "")))
    }

    @Test
    fun cleanLabelPrefersDistro() {
        assertEquals(
            "Ubuntu 24.04 LTS",
            SshHostPlatform.cleanLabel(buildJsonObject {
                put("os", "linux")
                put("distro", "Ubuntu  24.04\tLTS")
            }),
        )
        assertEquals("linux", SshHostPlatform.cleanLabel(buildJsonObject { put("os", "linux") }))
        assertNull(SshHostPlatform.cleanLabel(buildJsonObject { put("os", "  ") }))
        assertNull(SshHostPlatform.cleanLabel(buildJsonObject {}))
        assertEquals(80, SshHostPlatform.cleanLabel(buildJsonObject { put("os", "x".repeat(200)) })!!.length)
    }
}
