// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
