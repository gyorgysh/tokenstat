// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletAndroid
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/// The distro matcher must agree with `distroBrandID`: the same platform
/// string wears the same mark on both clients, and short names match on
/// token boundaries so `arch` inside another word claims nothing.
class DeviceMarksTest {
    @Test
    fun distroNamesMapToBrands() {
        assertEquals("ubuntu", distroBrandId(null, "Ubuntu 24.04 · x86_64"))
        assertEquals("debian", distroBrandId(null, "Debian GNU/Linux 12"))
        assertEquals("fedora", distroBrandId(null, "Fedora Linux 42"))
        assertEquals("alpinelinux", distroBrandId(null, "Alpine Linux v3.21"))
        assertEquals("archlinux", distroBrandId(null, "Arch Linux"))
        assertEquals("nixos", distroBrandId(null, "NixOS 25.05"))
        assertEquals("linuxmint", distroBrandId(null, "Linux Mint 22"))
        assertEquals("gentoo", distroBrandId(null, "Gentoo Linux"))
        assertEquals("rockylinux", distroBrandId(null, "Rocky Linux 9"))
        assertEquals("almalinux", distroBrandId(null, "AlmaLinux 9"))
        assertEquals("centos", distroBrandId(null, "CentOS Stream 9"))
        assertEquals("redhat", distroBrandId(null, "Red Hat Enterprise Linux 9"))
        assertEquals("redhat", distroBrandId(null, "RHEL 9.4"))
        assertEquals("opensuse", distroBrandId(null, "openSUSE Tumbleweed"))
        assertEquals("suse", distroBrandId(null, "SLES 15"))
        assertEquals("linux", distroBrandId(null, "Linux 6.8.0"))
    }

    @Test
    fun shortNamesNeedTokenBoundaries() {
        // "search" and "research" contain "arch" but name no distribution.
        assertNull(distroBrandId(null, "Research box"))
        assertNull(distroBrandId(null, "Darwin 25.1.0"))
        assertNull(distroBrandId(null, ""))
        assertNull(distroBrandId(null, null))
    }

    @Test
    fun labelBacksUpABlankPlatform() {
        assertEquals("ubuntu", distroBrandId("ubuntu-server", null))
        assertEquals("ubuntu", distroBrandId("anything", "Ubuntu 24.04"))
    }

    @Test
    fun serverDatesParse() {
        assertEquals(true, parseServerDate("2026-09-16T12:00:00Z") != null)
        assertEquals(true, parseServerDate("2026-09-16T12:00:00.123Z") != null)
        assertNull(parseServerDate("not a date"))
        assertNull(parseServerDate(null))
        assertNull(formatRelativeDate("not a date"))
        assertEquals("not a date", formatServerDate("not a date"))
    }

    @Test
    fun glyphsMatchClientDeviceIcon() {
        // The same ladder `ClientDeviceIcon.symbol` climbs: tablets and
        // phones by name, then laptop, desktop, and rack by name or platform.
        assertSame(Icons.Default.TabletAndroid, deviceGlyphVector("iPad", null, false))
        assertSame(Icons.Default.PhoneAndroid, deviceGlyphVector("iPhone 17", null, false))
        assertSame(Icons.Default.Laptop, deviceGlyphVector("Gyorgy's MacBook Pro", null, true))
        assertSame(Icons.Default.Computer, deviceGlyphVector("Mac mini", null, true))
        assertSame(Icons.Default.Dns, deviceGlyphVector("Linux", null, true))
        assertSame(Icons.Default.Dns, deviceGlyphVector("web-01", "Ubuntu 24.04 · x86_64", true))
        assertSame(Icons.Default.Dns, deviceGlyphVector("build", "Windows 11", true))
        // A bare "pro" is not a desktop: only the full Mac names claim one.
        assertSame(Icons.Default.Laptop, deviceGlyphVector("MacBook Pro", null, true))
        assertSame(Icons.Default.Computer, deviceGlyphVector("AirPods pro", null, true))
        assertSame(Icons.Default.Computer, deviceGlyphVector("mystery", null, true))
        assertSame(Icons.Default.PhoneAndroid, deviceGlyphVector("pixel", null, false))
        assertSame(Icons.Default.TabletAndroid, deviceGlyphVector("android tablet", null, false))
    }

    @Test
    fun machinesSortLikeClientDevicesView() {
        fun machine(
            id: String,
            label: String,
            kind: String? = "host",
            online: Boolean? = null,
            lastSeenAt: String? = null,
        ) = buildJsonObject {
            put("id", id)
            put("label", label)
            if (kind != null) put("kind", kind)
            if (online != null) put("online", online)
            if (lastSeenAt != null) put("lastSeenAt", lastSeenAt)
        }
        val spend = mapOf("busy" to 900L, "quiet" to 100L)
        val machines = listOf(
            machine("quiet", "Quiet host", online = true),
            machine("phone", "Phone", kind = "client", online = true),
            machine("old", "Old host", online = false, lastSeenAt = "2026-01-01T00:00:00Z"),
            machine("mine", "This phone", kind = "client", online = false),
            machine("busy", "Busy host", online = true),
            machine("newer", "Newer host", online = false, lastSeenAt = "2026-09-01T00:00:00Z"),
        )
        val sorted = sortMachines(machines, "mine") { spend[it.getValue("id").jsonPrimitive.content] }
        assertEquals(
            listOf("mine", "busy", "quiet", "phone", "newer", "old"),
            sorted.map { it.getValue("id").jsonPrimitive.content },
        )
    }
}
